#!/bin/bash

update_cilium() {
    set_names
    log "Updating Cilium to version ${CILIUM_VERSION}..."
    
    # 1. Redeploy Helm Chart
    deploy_cilium "true"
    
    # 2. Update Instance Labels
    local CILIUM_LABEL="${CILIUM_VERSION//./-}"
    log "Updating instance labels to cilium-version=${CILIUM_LABEL}..."
    
    # Find all cluster instances
    local INSTANCES
    INSTANCES=$(gcloud compute instances list --filter="labels.cluster=${CLUSTER_NAME} AND zone:(${ZONE})" --format="value(name)" --project="${PROJECT_ID}")
    
    if [ -n "$INSTANCES" ]; then
        for instance in $INSTANCES; do
            log "Updating label for ${instance}..."
            run_safe gcloud compute instances add-labels "${instance}" --labels="cilium-version=${CILIUM_LABEL}" --zone "${ZONE}" --project="${PROJECT_ID}"
        done
        log "Labels updated."
    else
        warn "No instances found to update labels."
    fi
    
    status
}

deploy_ccm() {
    log "Deploying GCP Cloud Controller Manager..."
    # Determine Route Configuration based on Cilium Mode
    local CONFIGURE_CLOUD_ROUTES="true"
    local ALLOCATE_NODE_CIDRS="true"

    if [ "${CILIUM_ROUTING_MODE:-}" == "native" ]; then
        # Native Routing uses Alias IPs:
        # 1. We DON'T want CCM to create legacy routes (configure-cloud-routes=false)
        # 2. We WANT CCM to allocate PodCIDRs and sync to Alias IPs (allocate-node-cidrs=true)
        # CRITICAL: IPAM must be enabled for Native Routing to work!
        CONFIGURE_CLOUD_ROUTES="false"
        ALLOCATE_NODE_CIDRS="true"
        CONTROLLERS_ARG="*"
    fi
    log "CCM: configure-cloud-routes=${CONFIGURE_CLOUD_ROUTES}, allocate-node-cidrs=${ALLOCATE_NODE_CIDRS}, controllers=${CONTROLLERS_ARG:-*} (Mode: ${CILIUM_ROUTING_MODE:-tunnel})"
    
    # Get CP-0 Direct IP for Bootstrap Access (Bypass VIP)
    local cp_0_name="${CLUSTER_NAME}-cp-0"
    local CP_0_IP=$(gcloud compute instances describe "${cp_0_name}" --zone "${ZONE}" --format="value(networkInterfaces[0].networkIP)" --project="${PROJECT_ID}")
    
    # Get Control Plane ILB IP (The VIP) - Needed for kubeconfig manipulation
    local CP_ILB_IP=$(gcloud compute addresses describe "${ILB_CP_IP_NAME}" --region "${REGION}" --format="value(address)" --project="${PROJECT_ID}")
    
    log "Using CP-0 Direct IP for CCM Bootstrap: ${CP_0_IP} (VIP: ${CP_ILB_IP})"

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
kind: Deployment
metadata:
  labels:
    k8s-app: gcp-compute-persistent-disk-csi-driver
  name: gcp-cloud-controller-manager
  namespace: kube-system
spec:
  replicas: 1
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
      nodeSelector:
        node-role.kubernetes.io/control-plane: ""
      tolerations:
      - key: node.cloudprovider.kubernetes.io/uninitialized
        value: "true"
        effect: NoSchedule
      - key: node-role.kubernetes.io/control-plane
        effect: NoSchedule
      - key: node-role.kubernetes.io/master
        effect: NoSchedule
      - key: node.cilium.io/agent-not-ready
        operator: Exists
        effect: NoSchedule
      - key: node.kubernetes.io/not-ready
        operator: Exists
        effect: NoSchedule
      # CRITICAL: Toleration for network-unavailable is required for CCM to run and assign PodCIDRs
      # matching the taint that Cilium (waiting for PodCIDR) cannot yet remove.
      - key: node.kubernetes.io/network-unavailable
        operator: Exists
        effect: NoSchedule
      containers:
      - name: cloud-controller-manager
        image: registry.k8s.io/cloud-provider-gcp/cloud-controller-manager:v30.0.0
        args:
        - /cloud-controller-manager
        - --cloud-provider=gce
        - --leader-elect=true
        - --use-service-account-credentials
        - --allocate-node-cidrs=${ALLOCATE_NODE_CIDRS}
        - --configure-cloud-routes=${CONFIGURE_CLOUD_ROUTES}
        - --cluster-cidr=${POD_CIDR}
        - --controllers=${CONTROLLERS_ARG:-*}
        env:
        - name: GOOGLE_APPLICATION_CREDENTIALS
          value: /etc/gcp/key.json
        - name: KUBERNETES_SERVICE_HOST
          value: "127.0.0.1"
        - name: KUBERNETES_SERVICE_PORT
          value: "6443"
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
    
    # Run kubectl on Bastion with Retry for Secret Creation (Direct IP)
    run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "
        # Configure Direct Access
        cp ~/.kube/config kubeconfig.ccm.direct
        sed -i 's/${CP_ILB_IP}/${CP_0_IP}/g' kubeconfig.ccm.direct
        
        for i in {1..20}; do
            echo \"Attempting to create gcp-service-account secret (Attempt \$i/20)...\"
            if ! kubectl --kubeconfig kubeconfig.ccm.direct get secret -n kube-system gcp-service-account &>/dev/null; then
                    if kubectl --kubeconfig kubeconfig.ccm.direct create secret generic gcp-service-account --from-file=key.json=service-account.json -n kube-system; then
                        echo \"Secret created successfully.\"
                        break
                    fi
            else
                    echo \"Secret already exists.\"
                    break
            fi
            echo \"Retrying secret creation in 5s...\"
            sleep 5
        done
        rm -f service-account.json
    "
    
    log "Applying CCM..."
    
    run_safe gcloud compute scp "${OUTPUT_DIR}/gcp-ccm.yaml" "${BASTION_NAME}:~" --zone "${ZONE}" --tunnel-through-iap
    
    # Retry loop for CCM application (API server might be flaky without CNI/ILB stability)
    run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "
        for i in {1..20}; do
            echo \"Attempting to apply CCM manifest (Attempt \$i/20)...\"
            if kubectl --kubeconfig kubeconfig.ccm.direct apply --validate=false -f gcp-ccm.yaml; then
                rm gcp-ccm.yaml kubeconfig.ccm.direct
                exit 0
            fi
            echo \"Retrying in 10s...\"
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
        cp ~/.kube/config kubeconfig.direct
        sed -i 's/${CP_ILB_IP}/${CP_0_IP}/g' kubeconfig.direct
        
        for i in {1..20}; do
            echo \"Attempting to apply VIP Alias (Attempt \$i/20)...\"
            if kubectl --kubeconfig ./kubeconfig.direct apply -f vip-alias.yaml; then
                echo \"VIP Alias applied successfully.\"
                rm vip-alias.yaml kubeconfig.direct
                exit 0
            fi
            echo \"Retrying in 5s...\"
            sleep 5
        done
        echo \"Failed to apply VIP alias after 20 attempts.\"
        exit 1
    "
    rm -f "${OUTPUT_DIR}/vip-alias.yaml"
}

deploy_csi() {
    log "Deploying GCP Compute Persistent Disk CSI Driver..."
    # Use official stable overlay via remote kustomize, pinned to a specific version used in testing
    local CSI_URL="github.com/kubernetes-sigs/gcp-compute-persistent-disk-csi-driver/deploy/kubernetes/overlays/stable-master?ref=v1.16.0"
    
    log "Applying CSI Driver with Talos Patches..."
    
    # Check if key exists locally, regenerate to ensure validity
    if [ -f "${OUTPUT_DIR}/service-account.json" ]; then
        log "Removing old Service Account Key..."
        rm -f "${OUTPUT_DIR}/service-account.json"
    fi
    
    log "Generating Service Account Key..."
    gcloud iam service-accounts keys create "${OUTPUT_DIR}/service-account.json" --iam-account="${SA_EMAIL}" --project="${PROJECT_ID}" || true

    # 1. Generate full manifest list using kustomize locally (requires kubectl)
    log "Generating CSI manifests..."
    "$KUBECTL" kustomize "${CSI_URL}" > "${OUTPUT_DIR}/csi-driver-original.yaml"
    
    # 2. Patch manifests to remove HostPath mounts incompatible with Talos (/etc/udev, /lib/udev, /run/udev)
    cat <<EOF > "${OUTPUT_DIR}/patch_csi.py"
import yaml
import sys

def patch_manifests(input_file, output_file):
    with open(input_file, 'r') as f:
        docs = list(yaml.safe_load_all(f))
    
    patched_docs = []
    for doc in docs:
        kind = doc.get('kind')
        name = doc.get('metadata', {}).get('name')
        
        # Patch both DaemonSet (Node) and Deployment (Controller)
        if doc and (
            (kind == 'DaemonSet' and name == 'csi-gce-pd-node') or 
            (kind == 'Deployment' and name == 'csi-gce-pd-controller')
        ):
            # Patch Container VolumeMounts
            containers = doc['spec']['template']['spec']['containers']
            for c in containers:
                if 'volumeMounts' in c:
                    c['volumeMounts'] = [vm for vm in c['volumeMounts'] if vm['name'] not in ['udev-rules-etc', 'udev-rules-lib', 'udev-socket']]
            
            # Patch Duplicate and Long Port Names
            seen_port_names = set()
            for c in containers:
                if 'ports' in c:
                    new_ports = []
                    for p in c['ports']:
                        p_name = p.get('name')
                        if p_name:
                            # 1. Rename specific long names first
                            if p_name == "http-endpoint-csi-attacher": p_name = "http-csi-attach"
                            elif p_name == "http-endpoint-csi-resizer": p_name = "http-csi-resize"
                            elif p_name == "http-endpoint-csi-snapshotter": p_name = "http-csi-snap"
                            
                            # 2. Truncate to 15 chars max (IANA standard)
                            p_name = p_name[:15]

                            # 3. Handle duplicates robustly
                            base_name = p_name
                            suffix_counter = 1
                            while p_name in seen_port_names:
                                suffix = f"-{suffix_counter}" 
                                allowed_len = 15 - len(suffix)
                                p_name = f"{base_name[:allowed_len]}{suffix}"
                                suffix_counter += 1
                            
                            p['name'] = p_name
                            seen_port_names.add(p_name)
                        new_ports.append(p)
                    c['ports'] = new_ports
            
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

    # Create Setup Script for Bastion
    cat <<EOF > "${OUTPUT_DIR}/csi-setup.sh"
#!/bin/bash
set -e

# Fix: Explicitly Create Namespace (Idempotent)
kubectl --kubeconfig ~/.kube/config create namespace gce-pd-csi-driver --dry-run=client -o yaml | kubectl --kubeconfig ~/.kube/config apply -f -

# Fix: Label for Pod Security Admission (Privileged)
# Label BEFORE applying manifests to avoid admission warnings/denials
kubectl --kubeconfig ~/.kube/config label namespace gce-pd-csi-driver pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/audit=privileged pod-security.kubernetes.io/warn=privileged --overwrite

# Apply Patched Manifests
kubectl --kubeconfig ~/.kube/config apply -f csi-driver-patched.yaml

# Fix: Create Secret for GCP Auth in CORRECT Namespaces
if [ -f "service-account.json" ]; then
    # 1. For CSI Driver (gce-pd-csi-driver namespace)
    kubectl --kubeconfig ~/.kube/config create secret generic cloud-sa --from-file=cloud-sa.json=service-account.json -n gce-pd-csi-driver --dry-run=client -o yaml | kubectl --kubeconfig ~/.kube/config apply -f -
    
    # 2. For CCM (kube-system namespace) - ensuring it has it too just in case
    kubectl --kubeconfig ~/.kube/config create secret generic gcp-service-account --from-file=key.json=service-account.json -n kube-system --dry-run=client -o yaml | kubectl --kubeconfig ~/.kube/config apply -f -
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
    run_safe gcloud compute scp "${OUTPUT_DIR}/csi-driver-patched.yaml" "${BASTION_NAME}:~" --zone "${ZONE}" --tunnel-through-iap
    run_safe gcloud compute scp "${OUTPUT_DIR}/csi-setup.sh" "${BASTION_NAME}:~" --zone "${ZONE}" --tunnel-through-iap
    run_safe gcloud compute scp "${OUTPUT_DIR}/service-account.json" "${BASTION_NAME}:~" --zone "${ZONE}" --tunnel-through-iap
    
    log "Executing CSI setup on Bastion..."
    run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "./csi-setup.sh && rm csi-setup.sh csi-driver-patched.yaml service-account.json"
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
    run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl --kubeconfig ~/.kube/config apply -f storageclass.yaml && rm storageclass.yaml"
    rm -f "${OUTPUT_DIR}/storageclass.yaml"
}
