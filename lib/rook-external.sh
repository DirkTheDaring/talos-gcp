#!/bin/bash

# Rook External Cluster Configuration
# Manages connection of client clusters to the central Rook storage cluster.

deploy_rook_client() {
    log "Deploying Rook Client..."
    
    # 1. Install Rook Operator (Required for CSI)
    # Ensure source rook.sh is loaded for install_rook_operator
    source "${SCRIPT_DIR}/lib/rook.sh"
    install_rook_operator

    # 2. Check for configured peer
    local found_peer="false"
    for peer in "${PEER_WITH[@]}"; do
        if [[ "$peer" == "rook-ceph" ]]; then
            found_peer="true"
            break
        fi
    done
    
    if [[ "$found_peer" == "false" ]]; then
        warn "Warning: 'rook-ceph' is not in PEER_WITH list. Storage might be unreachable."
    fi
    
    # 3. Import External Cluster and User Info
    import_external_cluster_info
}

import_external_cluster_info() {
    log "Importing connection info from 'rook-ceph' cluster..."
    
    # Prerequisite: Must have access to 'rook-ceph' kubeconfig or ability to fetch secrets.
    # We can use the 'get_credentials' logic or assume we can context switch if on the same machine/bastion.
    # Since we are on the management workstation (or bastion), we can fetch from the other cluster's context.

    # 1. Fetch Secrets from Source Cluster (rook-ceph)
    # We need:
    # - rook-ceph-mon-endpoints (ConfigMap)
    # - rook-ceph-mon (Secret)
    # - rook-ceph-admin-keyring (Secret) - For admin tasks (optional but good)
    # - rook-csi-rbd-provisioner (Secret) - If using separate user (best practice)
    # - rook-csi-rbd-node (Secret)
    
    # For now, we'll use the admin keyring for simplicity, but ideally we should create a specific client user.
    # Let's assume we use the admin keyring for the client for now to get it working (POC).
    
    # We need to act on the CLIENT cluster (current context), but read from the STORAGE cluster.
    # This requires switching contexts or explicit --kubeconfig.
    
    # IMPORTANT: The script runs against the CURRENT cluster (Client).
    # We need a way to target the REMOTE cluster (Storage).
    # We can look for `_out/rook-ceph/kubeconfig` if it exists locally.
    
    local ROOK_KUBECONFIG="${SCRIPT_DIR}/_out/rook-ceph/kubeconfig"
    
    # Since we might not have direct network access to the rook-ceph cluster (Private IP),
    # we use the rook-ceph-bastion to fetch the data.
    local SOURCE_BASTION="rook-ceph-bastion"
    
    # Remove local file check as we use Bastion
    # if [[ ! -f "$ROOK_KUBECONFIG" ]]; then ... fi
    
    log "Fetching secrets from ${SOURCE_BASTION}..."
    echo "DEBUG: SOURCE_BASTION='${SOURCE_BASTION}' ZONE='${ZONE}' PROJECT_ID='${PROJECT_ID}'"
    
    local MON_ENDPOINTS=$(gcloud compute ssh "${SOURCE_BASTION}" --zone "${ZONE}" --project="${PROJECT_ID}" --tunnel-through-iap --command "kubectl -n rook-ceph get cm rook-ceph-mon-endpoints -o jsonpath='{.data.data}'")
    local MON_SECRET=$(gcloud compute ssh "${SOURCE_BASTION}" --zone "${ZONE}" --project="${PROJECT_ID}" --tunnel-through-iap --command "kubectl -n rook-ceph get secret rook-ceph-mon -o jsonpath='{.data.mon-secret}'")
    local ADMIN_KEYRING=$(gcloud compute ssh "${SOURCE_BASTION}" --zone "${ZONE}" --project="${PROJECT_ID}" --tunnel-through-iap --command "kubectl -n rook-ceph get secret rook-ceph-admin-keyring -o jsonpath='{.data.keyring}'")
    local FSID=$(gcloud compute ssh "${SOURCE_BASTION}" --zone "${ZONE}" --project="${PROJECT_ID}" --tunnel-through-iap --command "kubectl -n rook-ceph get cephcluster rook-ceph -o jsonpath='{.status.ceph.fsid}' | base64 -w0")

    # Clean up output
    MON_ENDPOINTS=$(echo "$MON_ENDPOINTS" | tr -d '\r')
    MON_SECRET=$(echo "$MON_SECRET" | tr -d '\r')
    ADMIN_KEYRING=$(echo "$ADMIN_KEYRING" | tr -d '\r')
    FSID=$(echo "$FSID" | tr -d '\r')
    
    if [[ -z "$MON_ENDPOINTS" ]] || [[ -z "$MON_SECRET" ]] || [[ -z "$ADMIN_KEYRING" ]] || [[ -z "$FSID" ]]; then
        error "Failed to fetch one or more secrets from rook-ceph cluster."
        return 1
    
    fi
    
    # Validation: Extract Key early to ensure it's valid
    local ROOK_ADMIN_KEY
    ROOK_ADMIN_KEY=$(echo "$ADMIN_KEYRING" | base64 -d | grep 'key = ' | awk '{print $3}' | tr -d '\n\r')
    
    if [[ -z "$ROOK_ADMIN_KEY" ]]; then
        error "Failed to extract 'key' from admin keyring. Content might be invalid."
        return 1
    fi
    
    local ROOK_ADMIN_KEY_B64
    ROOK_ADMIN_KEY_B64=$(echo -n "$ROOK_ADMIN_KEY" | base64 -w0)

    log "Applying secrets to configured client namespace (rook-ceph)..."
    
    # Generate Manifests Locally
    mkdir -p "${OUTPUT_DIR}/rook-client"
    
    # 1. Secrets
    cat <<EOF > "${OUTPUT_DIR}/rook-client/secrets.yaml"
apiVersion: v1
kind: Secret
metadata:
  name: rook-ceph-mon
  namespace: rook-ceph
type: Opaque
data:
  mon-secret: $MON_SECRET
  cluster-name: $(echo -n "rook-ceph" | base64 -w0)
  fsid: $FSID
  admin-secret: $ROOK_ADMIN_KEY_B64
  userID: $(echo -n "admin" | base64 -w0)
  userKey: $ROOK_ADMIN_KEY_B64
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: rook-ceph-mon-endpoints
  namespace: rook-ceph
data:
  data: "$MON_ENDPOINTS"
  mapping: "{}"
  maxMonId: "2"
---
apiVersion: v1
kind: Secret
metadata:
  name: rook-ceph-admin-keyring
  namespace: rook-ceph
type: kubernetes.io/rook
data:
  keyring: $ADMIN_KEYRING
EOF

    # 2. External Cluster CR
    cat <<EOF > "${OUTPUT_DIR}/rook-client/external-cluster.yaml"
apiVersion: ceph.rook.io/v1
kind: CephCluster
metadata:
  name: rook-ceph
  namespace: rook-ceph
spec:
  external:
    enable: true
  dataDirHostPath: /var/lib/rook
  cephVersion:
    image: quay.io/ceph/ceph:v18.2.0 # Should match source
  healthCheck:
    daemonHealth:
      mon:
        disabled: false
        interval: 45s
  monitoring:
    enabled: false
  crashCollector:
    disable: true
EOF

    # 3. StorageClasses
    cat <<EOF > "${OUTPUT_DIR}/rook-client/storageclasses.yaml"
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ceph-block
provisioner: rook-ceph.rbd.csi.ceph.com
parameters:
  clusterID: rook-ceph
  pool: ceph-blockpool
  imageFormat: "2"
  imageFeatures: layering
  csi.storage.k8s.io/provisioner-secret-name: rook-ceph-mon
  csi.storage.k8s.io/provisioner-secret-namespace: rook-ceph
  csi.storage.k8s.io/controller-expand-secret-name: rook-ceph-mon
  csi.storage.k8s.io/controller-expand-secret-namespace: rook-ceph
  csi.storage.k8s.io/node-stage-secret-name: rook-ceph-mon
  csi.storage.k8s.io/node-stage-secret-namespace: rook-ceph
  csi.storage.k8s.io/fstype: ext4
allowVolumeExpansion: true
reclaimPolicy: Delete
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ceph-filesystem
provisioner: rook-ceph.cephfs.csi.ceph.com
parameters:
  clusterID: rook-ceph
  fsName: ceph-filesystem
  pool: ceph-filesystem-data0
  csi.storage.k8s.io/provisioner-secret-name: rook-ceph-mon
  csi.storage.k8s.io/provisioner-secret-namespace: rook-ceph
  csi.storage.k8s.io/controller-expand-secret-name: rook-ceph-mon
  csi.storage.k8s.io/controller-expand-secret-namespace: rook-ceph
  csi.storage.k8s.io/node-stage-secret-name: rook-ceph-mon
  csi.storage.k8s.io/node-stage-secret-namespace: rook-ceph
allowVolumeExpansion: true
reclaimPolicy: Delete
EOF

    # Apply via Bastion
    log "Pushing Rook Client manifests to Bastion..."
    run_safe gcloud compute scp --recurse "${OUTPUT_DIR}/rook-client" "${BASTION_NAME}:~" --zone "${ZONE}" --tunnel-through-iap
    
    log "Applying manifests on Bastion..."
    run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "
        kubectl apply -f rook-client/secrets.yaml
        kubectl apply -f rook-client/external-cluster.yaml
        kubectl apply -f rook-client/storageclasses.yaml
        rm -rf rook-client
    "
    
    log "Rook Client configured successfully (External Mode)."
}
