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

prune_sa_keys() {
    local sa_email="$1"
    if [ -z "$sa_email" ]; then return; fi
    
    log "Checking key limit for SA: ${sa_email}..."
    
    # List USER_MANAGED keys, sorted by validity (oldest first)
    local keys
    if ! keys=$(gcloud iam service-accounts keys list \
        --iam-account="${sa_email}" \
        --project="${PROJECT_ID}" \
        --managed-by="user" \
        --sort-by="validAfterTime" \
        --format="value(name)" 2>/dev/null); then
        warn "Failed to list keys for ${sa_email}. Skipping prune."
        return
    fi
    
    # Count non-empty lines
    # Count non-empty lines
    local count=0
    if [ -n "$keys" ]; then
        # grep -c prints the count. If count is 0, grep exits with 1.
        # We use || true to prevent set -e from killing the script, while capturing the '0' output.
        count=$(echo "$keys" | grep -c -v "^$" || true)
    fi
    
    log "Found ${count} user-managed keys."
    
    # Safety Check: Only prune if SA Email contains Cluster Name
    # We want to avoid pruning shared SAs (e.g. 'rook-ceph' used by 'nested')
    if [[ "${sa_email}" != *"${CLUSTER_NAME}"* ]]; then
        warn "Service Account '${sa_email}' does not appear to belong exclusively to cluster '${CLUSTER_NAME}'."
        warn "Skipping key pruning to prevent accidental deletion of shared keys."
        warn "Please manually delete old keys if you hit the 10-key limit (User Managed)."
        return
    fi

    # Limit is 10 (User-Managed). Prune if >= 8 to be safe.
    if [ "$count" -ge 8 ]; then
        local prune_count=$((count - 5))
        if [ "$prune_count" -gt 0 ]; then
            log "Pruning ${prune_count} old keys..."
            local to_delete
            to_delete=$(echo "$keys" | head -n "${prune_count}")
            
            for key_id in $to_delete; do
                # Extract basename just in case, though value(name) returns full path usually
                # But 'keys delete' takes full path or ID. Full path is safer.
                run_safe gcloud iam service-accounts keys delete "${key_id}" \
                    --iam-account="${sa_email}" \
                    --project="${PROJECT_ID}" \
                    --quiet
            done
            log "Pruned old keys."
        fi
    fi
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

    if [ ! -f "${OUTPUT_DIR}/gcp-ccm.yaml" ]; then
        error "File ${OUTPUT_DIR}/gcp-ccm.yaml was NOT created!"
        exit 1
    else
        log "File ${OUTPUT_DIR}/gcp-ccm.yaml created successfully."
    fi

    local GCP_SA_KEY="${OUTPUT_DIR}/service-account.json"

    # Ensure GCP SA Key exists
    if [ ! -f "${GCP_SA_KEY}" ]; then
        prune_sa_keys "${SA_EMAIL}"
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

wait_for_ccm() {
    log "Waiting for CCM to become Active and assign PodCIDRs..."
    
    # 1. Wait for Pod Running
    log "Waiting for gcp-cloud-controller-manager Pod to be Running..."
    run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "
        kubectl wait --for=condition=Ready pod -l k8s-app=gcp-cloud-controller-manager -n kube-system --timeout=300s || echo 'Warning: CCM Pod not Ready yet.'
    "

    # 2. Wait for IPAM (PodCIDR assignment)
    log "Waiting for PodCIDR assignment on Control Plane node..."
    local cp_node="${CLUSTER_NAME}-cp-0"
    
    run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "
        for i in {1..60}; do
            CIDR=\$(kubectl get node ${cp_node} -o jsonpath='{.spec.podCIDR}' 2>/dev/null)
            if [ -n \"\$CIDR\" ]; then
                echo \"✅ Node ${cp_node} has PodCIDR: \$CIDR\"
                exit 0
            fi
            echo \"Waiting for CCM to assign PodCIDR... (Attempt \$i/60)\"
            sleep 5
        done
        echo \"ERROR: Timeout waiting for PodCIDR assignment. CCM might be broken.\"
        echo \"Check logs: kubectl logs -n kube-system -l k8s-app=gcp-cloud-controller-manager\"
        exit 1
    "
}





deploy_csi() {
    log "Deploying GCP Compute Persistent Disk CSI Driver..."
    # Use official stable overlay via remote kustomize, pinned to a specific version used in testing
    local CSI_URL="github.com/kubernetes-sigs/gcp-compute-persistent-disk-csi-driver/deploy/kubernetes/overlays/stable-master?ref=v1.16.0"
    
    log "Applying CSI Driver with Talos Patches..."
    
    # Check if key exists locally, regenerate to ensure validity
    if [ -f "${OUTPUT_DIR}/service-account.json" ]; then
        log "Removing old Service Account Key (local)..."
        rm -f "${OUTPUT_DIR}/service-account.json"
    fi
    
    # Prune old keys from GMP to avoid hitting limit (10 keys per SA)
    prune_sa_keys "${SA_EMAIL}"
    
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

cat <<EOF > "${OUTPUT_DIR}/csi-setup.sh"
#!/bin/bash
set -e

# Retry function for kubectl commands
retry_kubectl() {
    local max_attempts=20
    local attempt=1
    local exit_code=0
    
    echo "Running: \$@" >&2
    for ((attempt=1; attempt<=max_attempts; attempt++)); do
        if "\$@"; then
            return 0
        fi
        exit_code=\$?
        echo "Command failed (Attempt \$attempt/\$max_attempts). Retrying in 10s..." >&2
        sleep 10
    done
    return \$exit_code
}

# Fix: Explicitly Create Namespace (Idempotent)
retry_kubectl kubectl --kubeconfig ~/.kube/config create namespace gce-pd-csi-driver --dry-run=client -o yaml | kubectl --kubeconfig ~/.kube/config apply -f -

# Fix: Label for Pod Security Admission (Privileged)
# Label BEFORE applying manifests to avoid admission warnings/denials
retry_kubectl kubectl --kubeconfig ~/.kube/config label namespace gce-pd-csi-driver pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/audit=privileged pod-security.kubernetes.io/warn=privileged --overwrite

# Apply Patched Manifests
retry_kubectl kubectl --kubeconfig ~/.kube/config apply -f csi-driver-patched.yaml

# Fix: Create Secret for GCP Auth in CORRECT Namespaces
if [ -f "service-account.json" ]; then
    # 1. For CSI Driver (gce-pd-csi-driver namespace)
    retry_kubectl kubectl --kubeconfig ~/.kube/config create secret generic cloud-sa --from-file=cloud-sa.json=service-account.json -n gce-pd-csi-driver --dry-run=client -o yaml | kubectl --kubeconfig ~/.kube/config apply -f -
    
    # 2. For CCM (kube-system namespace) - ensuring it has it too just in case
    retry_kubectl kubectl --kubeconfig ~/.kube/config create secret generic gcp-service-account --from-file=key.json=service-account.json -n kube-system --dry-run=client -o yaml | kubectl --kubeconfig ~/.kube/config apply -f -
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
    run_safe gcloud compute scp "${OUTPUT_DIR}/csi-driver-patched.yaml" "${BASTION_NAME}:~" --zone "${ZONE}" --tunnel-through-iap || return 1
    run_safe gcloud compute scp "${OUTPUT_DIR}/csi-setup.sh" "${BASTION_NAME}:~" --zone "${ZONE}" --tunnel-through-iap || return 1
    run_safe gcloud compute scp "${OUTPUT_DIR}/service-account.json" "${BASTION_NAME}:~" --zone "${ZONE}" --tunnel-through-iap || return 1
    
    log "Executing CSI setup on Bastion..."
    run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "./csi-setup.sh && rm csi-setup.sh csi-driver-patched.yaml service-account.json" || return 1
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
    run_safe gcloud compute scp "${OUTPUT_DIR}/storageclass.yaml" "${BASTION_NAME}:~" --zone "${ZONE}" --tunnel-through-iap || return 1
    run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl --kubeconfig ~/.kube/config apply -f storageclass.yaml && rm storageclass.yaml" || return 1
    rm -f "${OUTPUT_DIR}/storageclass.yaml"
}
