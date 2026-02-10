#!/bin/bash

# --- Phase 5: Register/Bootstrap ---
phase5_register() {
    log "Phase 5: Bootstrapping & Registering..."
    
    # Retry fetching IP to handle API transients
    local CONTROL_PLANE_0_IP=""
    local cp_0_name="${CLUSTER_NAME}-cp-0"
    for i in {1..10}; do
        CONTROL_PLANE_0_IP=$(gcloud compute instances describe "${cp_0_name}" --zone "${ZONE}" --format json 2>/dev/null | jq -r '.networkInterfaces[0].networkIP' || echo "")
        if [ -n "$CONTROL_PLANE_0_IP" ] && [ "$CONTROL_PLANE_0_IP" != "null" ]; then
            break
        fi
        log "Waiting for Control Plane IP to be assigned... (Attempt $i/10, usually <30s)"
        sleep 3
    done
    
    if [ -z "$CONTROL_PLANE_0_IP" ]; then
        error "Could not determine Control Plane IP."
        exit 1
    fi
    
    log "Preparing bootstrap script..."
    cat <<EOF > "${OUTPUT_DIR}/bootstrap_cluster.sh"
#!/bin/bash
talosctl --talosconfig talosconfig config endpoint ${CONTROL_PLANE_0_IP}
talosctl --talosconfig talosconfig config node ${CONTROL_PLANE_0_IP}
echo "Bootstrapping Cluster..."
# Bootstrap can race with node readiness, retry it
for i in {1..20}; do
    OUTPUT=\$(talosctl --talosconfig talosconfig bootstrap 2>&1)
    EXIT_CODE=\$?

    if [ \$EXIT_CODE -eq 0 ]; then
        echo "Bootstrap command sent successfully."
        break
    elif echo "\$OUTPUT" | grep -q "AlreadyExists"; then
        echo "Cluster is already bootstrapped (etcd data exists). Proceeding..."
        break
    fi

    echo "Talos API not yet ready for bootstrap (node booting/services starting)... (Attempt \$i/20, max 1m40s)"
    echo "Last Error: \$OUTPUT"
    sleep 5
done

echo "Waiting for kubeconfig generation (certificate signing)..."
for i in {1..30}; do
    if talosctl --talosconfig talosconfig kubeconfig .; then
        echo "Kubeconfig retrieved successfully!"
        exit 0
    fi
    echo "Waiting for API Server to provide Kubeconfig... (Attempt \$i/30, max 5m)"
    sleep 10
done
echo "Failed to retrieve kubeconfig."
exit 1
EOF
    chmod +x "${OUTPUT_DIR}/bootstrap_cluster.sh"

    log "Pushing configs to Bastion..."
    run_safe retry gcloud compute scp "${OUTPUT_DIR}/talosconfig" "${OUTPUT_DIR}/bootstrap_cluster.sh" "${BASTION_NAME}:~" --zone "${ZONE}" --tunnel-through-iap
    
    log "Executing bootstrap on Bastion..."
    run_safe retry gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "./bootstrap_cluster.sh"
    
    log "Retrieving kubeconfig..."
    run_safe gcloud compute scp "${BASTION_NAME}:~/kubeconfig" "${OUTPUT_DIR}/kubeconfig" --zone "${ZONE}" --tunnel-through-iap
    
    # Secure the kubeconfig
    chmod 600 "${OUTPUT_DIR}/kubeconfig" "${OUTPUT_DIR}/talosconfig"

    # Export KUBECONFIG for subsequent kubectl commands
    export KUBECONFIG="${OUTPUT_DIR}/kubeconfig"

    # Deploy VIP Alias (Fixes Node IP issue by adding VIP to lo via DaemonSet)
    deploy_vip_alias

    # Deploy CCM (Must be first for IPAM to work if using Cilium ipam.mode=kubernetes)
    deploy_ccm

    # Deploy CNI
    deploy_cni

    # Deploy CSI
    if [ "${INSTALL_CSI}" == "true" ]; then
        deploy_csi
    fi
}

deploy_ccm() {
    log "Deploying GCP Cloud Controller Manager..."
    
    # Generate CCM Manifest using external template
    export CP_ILB_IP  # Export for envsubst if needed
    export POD_CIDR   # Export for envsubst
    # Inline Manifest to avoid external dependency
    cat <<EOF > "${OUTPUT_DIR}/gcp-ccm.yaml"
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cloud-controller-manager
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:cloud-controller-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: cloud-controller-manager
  namespace: kube-system
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  labels:
    k8s-app: gcp-compute-persistent-disk-csi-driver
  name: gcp-cloud-controller-manager
  namespace: kube-system
spec:
  selector:
    matchLabels:
      k8s-app: gcp-cloud-controller-manager
  template:
    metadata:
      labels:
        k8s-app: gcp-cloud-controller-manager
    spec:
      serviceAccountName: cloud-controller-manager
      hostNetwork: true
      tolerations:
      - key: node.cloudprovider.kubernetes.io/uninitialized
        value: "true"
        effect: NoSchedule
      - key: node-role.kubernetes.io/control-plane
        effect: NoSchedule
      - key: node-role.kubernetes.io/master
        effect: NoSchedule
      containers:
      - name: cloud-controller-manager
        image: registry.k8s.io/cloud-provider-gcp/cloud-controller-manager:v30.0.0
        args:
        - /cloud-controller-manager
        - --cloud-provider=gce
        - --leader-elect=true
        - --use-service-account-credentials
        - --allocate-node-cidrs=true
        - --configure-cloud-routes=true
        - --cluster-cidr=${POD_CIDR}
        env:
        - name: GOOGLE_APPLICATION_CREDENTIALS
          value: /etc/gcp/key.json
        volumeMounts:
        - mountPath: /etc/gcp
          name: gcp-credentials
          readOnly: true
      volumes:
      - name: gcp-credentials
        secret:
          secretName: gcp-service-account
          items:
          - key: key.json
            path: key.json
EOF

    local GCP_SA_KEY="${OUTPUT_DIR}/service-account.json"

    # Ensure GCP SA Key exists
    if [ ! -f "${GCP_SA_KEY}" ]; then
        log "Generating Service Account Key for CCM..."
        gcloud iam service-accounts keys create "${GCP_SA_KEY}" --iam-account="${SA_EMAIL}" --project="${PROJECT_ID}" || true
    fi

    # Create Secret for CCM (On Bastion)
    log "Ensuring gcp-service-account secret for CCM..."
    # Copy key to Bastion
    run_safe gcloud compute scp "${GCP_SA_KEY}" "${BASTION_NAME}:service-account.json" --zone "${ZONE}" --tunnel-through-iap
    
    # Run kubectl on Bastion with Retry for Secret Creation
    run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "
        for i in {1..20}; do
            echo 'Attempting to create gcp-service-account secret (Attempt \$i/20)...'
            if ! kubectl --kubeconfig ./kubeconfig get secret -n kube-system gcp-service-account &>/dev/null; then
                    if kubectl --kubeconfig ./kubeconfig create secret generic gcp-service-account --from-file=key.json=service-account.json -n kube-system; then
                        echo 'Secret created successfully.'
                        break
                    fi
            else
                    echo 'Secret already exists.'
                    break
            fi
            echo 'Retrying secret creation in 5s...'
            sleep 5
        done
        rm -f service-account.json
    "
    
    log "Applying CCM..."
    
    run_safe gcloud compute scp "${OUTPUT_DIR}/gcp-ccm.yaml" "${BASTION_NAME}:~" --zone "${ZONE}" --tunnel-through-iap
    
    # Retry loop for CCM application (API server might be flaky without CNI/ILB stability)
    run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "
        for i in {1..20}; do
            echo 'Attempting to apply CCM manifest (Attempt \$i/20)...'
            if kubectl --kubeconfig ./kubeconfig apply --validate=false -f gcp-ccm.yaml; then
                rm gcp-ccm.yaml
                exit 0
            fi
            echo 'Retrying in 10s...'
            sleep 10
        done
        exit 1
    "
    rm -f "${OUTPUT_DIR}/gcp-ccm.yaml"
}

deploy_vip_alias() {
    log "Deploying VIP Alias DaemonSet (Fixing Node IP issue)..."
    
    # 1. Get Control Plane ILB IP (The VIP)
    local CP_ILB_IP=$(gcloud compute addresses describe "${ILB_CP_IP_NAME}" --region "${REGION}" --format="value(address)" --project="${PROJECT_ID}")
    
    # 2. Get CP-0 Direct IP (to bypass VIP for initial apply)
    local cp_0_name="${CLUSTER_NAME}-cp-0"
    local CP_0_IP=$(gcloud compute instances describe "${cp_0_name}" --zone "${ZONE}" --format="value(networkInterfaces[0].networkIP)" --project="${PROJECT_ID}")
    
    log "VIP: ${CP_ILB_IP}, CP-0 Direct: ${CP_0_IP}"

    # 3. Generate Manifest from Template
    export CP_ILB_IP
    # Inline Manifest
    cat <<EOF > "${OUTPUT_DIR}/vip-alias.yaml"
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: vip-alias
  namespace: kube-system
  labels:
    app: vip-alias
spec:
  selector:
    matchLabels:
      app: vip-alias
  template:
    metadata:
      labels:
        app: vip-alias
    spec:
      hostNetwork: true
      nodeSelector:
        node-role.kubernetes.io/control-plane: ""
      tolerations:
      - operator: Exists
      initContainers:
      - name: alias-vip
        image: busybox
        securityContext:
          privileged: true
        command:
        - /bin/sh
        - -c
        - |
          ip link add dummy0 type dummy || true
          ip link set dummy0 up || true
          ip addr add ${CP_ILB_IP}/32 dev dummy0 || true
      containers:
      - name: pause
        image: registry.k8s.io/pause:3.9
EOF

    # 4. Copy to Bastion
    run_safe gcloud compute scp "${OUTPUT_DIR}/vip-alias.yaml" "${BASTION_NAME}:~" --zone "${ZONE}" --tunnel-through-iap

    # Apply using Direct IP of CP-0 because VIP is not yet active on nodes
    log "Applying VIP Alias using Direct IP (${CP_0_IP})..."
    run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "
        cp kubeconfig kubeconfig.direct
        sed -i 's/${CP_ILB_IP}/${CP_0_IP}/g' kubeconfig.direct
        
        for i in {1..20}; do
            echo 'Attempting to apply VIP Alias (Attempt \$i/20)...'
            if kubectl --kubeconfig ./kubeconfig.direct apply -f vip-alias.yaml; then
                echo 'VIP Alias applied successfully.'
                rm vip-alias.yaml kubeconfig.direct
                exit 0
            fi
            echo 'Retrying in 5s...'
            sleep 5
        done
        echo 'Failed to apply VIP alias after 20 attempts.'
        exit 1
    "
    rm -f "${OUTPUT_DIR}/vip-alias.yaml"
}

deploy_csi() {
    log "Deploying GCP Compute Persistent Disk CSI Driver..."
    # Use official stable overlay via remote kustomize, pinned to a specific version used in testing
    local CSI_URL="github.com/kubernetes-sigs/gcp-compute-persistent-disk-csi-driver/deploy/kubernetes/overlays/stable-master?ref=v1.16.0"
    
    log "Applying CSI Driver with Talos Patches..."
    
    # Check if key exists locally
    if [ ! -f "${OUTPUT_DIR}/service-account.json" ]; then
        log "Generating Service Account Key..."
        gcloud iam service-accounts keys create "${OUTPUT_DIR}/service-account.json" --iam-account="${SA_EMAIL}" --project="${PROJECT_ID}" || true
    fi
    
    # 1. Generate full manifest list using kustomize locally (requires kubectl)
    log "Generating CSI manifests..."
    kubectl kustomize "${CSI_URL}" > "${OUTPUT_DIR}/csi-driver-original.yaml"
    
    # 2. Patch manifests to remove HostPath mounts incompatible with Talos (/etc/udev, /lib/udev, /run/udev)
    cat <<EOF > "${OUTPUT_DIR}/patch_csi.py"
import yaml
import sys

def patch_manifests(input_file, output_file):
    with open(input_file, 'r') as f:
        docs = list(yaml.safe_load_all(f))
    
    patched_docs = []
    for doc in docs:
        if doc and doc.get('kind') == 'DaemonSet' and doc.get('metadata', {}).get('name') == 'csi-gce-pd-node':
            # Patch Container VolumeMounts
            containers = doc['spec']['template']['spec']['containers']
            for c in containers:
                if c['name'] == 'gce-pd-driver':
                    if 'volumeMounts' in c:
                        c['volumeMounts'] = [vm for vm in c['volumeMounts'] if vm['name'] not in ['udev-rules-etc', 'udev-rules-lib', 'udev-socket']]
            
            # Patch Volumes
            if 'volumes' in doc['spec']['template']['spec']:
                doc['spec']['template']['spec']['volumes'] = [v for v in doc['spec']['template']['spec']['volumes'] if v['name'] not in ['udev-rules-etc', 'udev-rules-lib', 'udev-socket']]
        
        patched_docs.append(doc)

    with open(output_file, 'w') as f:
        yaml.dump_all(patched_docs, f)
    print("Patched CSI manifests.")

if __name__ == "__main__":
    patch_manifests("${OUTPUT_DIR}/csi-driver-original.yaml", "${OUTPUT_DIR}/csi-driver-patched.yaml")
EOF
    
    log "Patching CSI manifests..."
    if ! python3 "${OUTPUT_DIR}/patch_csi.py"; then
        error "Failed to patch CSI manifests."
        exit 1
    fi
    
    # 3. Create Setup Script for Bastion
    cat <<EOF > "${OUTPUT_DIR}/csi-setup.sh"
#!/bin/bash
set -e

# Fix: Explicitly Create Namespace (Idempotent)
kubectl --kubeconfig ./kubeconfig create namespace gce-pd-csi-driver --dry-run=client -o yaml | kubectl --kubeconfig ./kubeconfig apply -f -

# Apply Patched Manifests
kubectl --kubeconfig ./kubeconfig apply -f csi-driver-patched.yaml

# Fix: Label for Pod Security Admission (Privileged)
kubectl --kubeconfig ./kubeconfig label namespace gce-pd-csi-driver pod-security.kubernetes.io/enforce=privileged --overwrite

# Fix: Create Secret for GCP Auth
if [ -f "service-account.json" ]; then
    kubectl --kubeconfig ./kubeconfig create secret generic cloud-sa --from-file=cloud-sa.json=service-account.json -n gce-pd-csi-driver --dry-run=client -o yaml | kubectl --kubeconfig ./kubeconfig apply -f -
else
    echo "Warning: service-account.json not found, skipping secret creation."
fi

# Verification: Wait for CSI Controller
# Note: We SKIP waiting for the CSI Controller here.
# The Controller Pod will be Pending because it needs Worker nodes to run.
# But Worker nodes are created in the NEXT phase.
# Deadlock Prevention: We return immediately so the script can proceed to create Workers.
echo "Skipping CSI Controller wait to prevent deadlock (requires Workers)..."
EOF
    chmod +x "${OUTPUT_DIR}/csi-setup.sh"
    
    log "Pushing CSI artifacts to Bastion..."
    run_safe gcloud compute scp "${OUTPUT_DIR}/csi-driver-patched.yaml" "${OUTPUT_DIR}/csi-setup.sh" "${OUTPUT_DIR}/service-account.json" "${BASTION_NAME}:~" --zone "${ZONE}" --tunnel-through-iap
    
    log "Executing CSI setup on Bastion..."
    run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "./csi-setup.sh && rm csi-setup.sh csi-driver-patched.yaml"
    rm -f "${OUTPUT_DIR}/csi-driver.sh" "${OUTPUT_DIR}/csi-driver-original.yaml" "${OUTPUT_DIR}/csi-driver-patched.yaml" "${OUTPUT_DIR}/patch_csi.py" "${OUTPUT_DIR}/csi-setup.sh"
    
    # Init StorageClasses
    log "Creating StorageClasses..."
    cat <<EOF > "${OUTPUT_DIR}/storageclass.yaml"
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: standard-rwo
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: pd.csi.storage.gke.io
parameters:
  type: pd-balanced
  replication-type: none
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: premium-rwo
provisioner: pd.csi.storage.gke.io
parameters:
  type: pd-ssd
  replication-type: none
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF
    run_safe gcloud compute scp "${OUTPUT_DIR}/storageclass.yaml" "${BASTION_NAME}:~" --zone "${ZONE}" --tunnel-through-iap
    run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl --kubeconfig ./kubeconfig apply -f storageclass.yaml && rm storageclass.yaml"
    rm -f "${OUTPUT_DIR}/storageclass.yaml"
}
