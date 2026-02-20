#!/bin/bash

# Rook External Cluster Configuration
# Manages connection of client clusters to the central Rook storage cluster.

deploy_rook_client() {
    log "Deploying Rook Client..."
    
    # 1. Install Rook Operator (Required for CSI)
    # Ensure source rook.sh is loaded for install_rook_operator
    source "${SCRIPT_DIR}/lib/rook.sh"
    install_rook_operator || return 1
    
    # Track local namespaces to enforce Uniqueness Rule
    local -a LOCAL_NAMESPACES=()

    local idx=0
    for ext_cluster in "${ROOK_EXTERNAL_CLUSTERS[@]:-}"; do
        # 2. Import External Cluster and User Info
        import_external_cluster_info "$ext_cluster" "$idx" || return 1
        idx=$((idx + 1))
    done
}

import_external_cluster_info() {
    local ext_cluster="$1"
    local idx="$2"
    
    log "Importing connection info from '${ext_cluster}' cluster..."

    # Extract dynamic properties
    local safe_pool="${ext_cluster//-/_}"
    
    local remote_ns_var="ROOK_EXT_${safe_pool^^}_REMOTE_NAMESPACE"
    local local_ns_var="ROOK_EXT_${safe_pool^^}_LOCAL_NAMESPACE"
    local sc_prefix_var="ROOK_EXT_${safe_pool^^}_SC_PREFIX"
    local bastion_var="ROOK_EXT_${safe_pool^^}_BASTION"

    # Default Rules mapping
    local REMOTE_NAMESPACE="${!remote_ns_var:-}"
    local LOCAL_NAMESPACE="${!local_ns_var:-rook-client-${ext_cluster}}"
    local SC_PREFIX="${!sc_prefix_var:-${ext_cluster}-}"
    local SOURCE_BASTION="${!bastion_var:-${ext_cluster}-bastion}"

    # Rule 1: Fallbacks and mandatory definitions
    if [ -z "$REMOTE_NAMESPACE" ]; then
        if [ "$idx" -eq 0 ]; then
            REMOTE_NAMESPACE="rook-ceph"
            log "  - Defaulting REMOTE_NAMESPACE to 'rook-ceph' for first cluster."
        else
            error "ROOK_EXT_${safe_pool^^}_REMOTE_NAMESPACE is missing for ${ext_cluster}. It is mandatory for index ${idx}."
            return 1
        fi
    fi

    # Rule 2: Uniqueness check
    for existing_ns in "${LOCAL_NAMESPACES[@]:-}"; do
        if [ "$existing_ns" == "$LOCAL_NAMESPACE" ]; then
            error "Local namespace collision detected: '${LOCAL_NAMESPACE}' has already been processed for another cluster. Must be unique."
            return 1
        fi
    done
    LOCAL_NAMESPACES+=("$LOCAL_NAMESPACE")

    # Detect Zone of Source Bastion
    log "Locating external bastion '${SOURCE_BASTION}'..."
    local SOURCE_ZONE
    SOURCE_ZONE=$(gcloud compute instances list --filter="name=${SOURCE_BASTION}" --format="value(zone)" --project="${PROJECT_ID}" --limit=1)
    
    if [ -z "$SOURCE_ZONE" ]; then
        error "Could not find '${SOURCE_BASTION}' in project '${PROJECT_ID}'. Is the external cluster deployed?"
        return 1
    fi
    
    log "Found '${SOURCE_BASTION}' in zone '${SOURCE_ZONE}'."
    
    log "Fetching secrets from ${SOURCE_BASTION} (Remote NS: ${REMOTE_NAMESPACE})..."
    
    local MON_ENDPOINTS=$(gcloud compute ssh "${SOURCE_BASTION}" --zone "${SOURCE_ZONE}" --project="${PROJECT_ID}" --tunnel-through-iap --command "kubectl -n ${REMOTE_NAMESPACE} get cm rook-ceph-mon-endpoints -o jsonpath='{.data.data}'" 2>/dev/null)
    local MON_SECRET=$(gcloud compute ssh "${SOURCE_BASTION}" --zone "${SOURCE_ZONE}" --project="${PROJECT_ID}" --tunnel-through-iap --command "kubectl -n ${REMOTE_NAMESPACE} get secret rook-ceph-mon -o jsonpath='{.data.mon-secret}'" 2>/dev/null)
    local ADMIN_KEYRING=$(gcloud compute ssh "${SOURCE_BASTION}" --zone "${SOURCE_ZONE}" --project="${PROJECT_ID}" --tunnel-through-iap --command "kubectl -n ${REMOTE_NAMESPACE} get secret rook-ceph-admin-keyring -o jsonpath='{.data.keyring}'" 2>/dev/null)
    local FSID=$(gcloud compute ssh "${SOURCE_BASTION}" --zone "${SOURCE_ZONE}" --project="${PROJECT_ID}" --tunnel-through-iap --command "kubectl -n ${REMOTE_NAMESPACE} get cephcluster rook-ceph -o jsonpath='{.status.ceph.fsid}' | base64 -w0" 2>/dev/null)

    # Clean up output
    MON_ENDPOINTS=$(echo "$MON_ENDPOINTS" | tr -d '\r')
    MON_SECRET=$(echo "$MON_SECRET" | tr -d '\r')
    ADMIN_KEYRING=$(echo "$ADMIN_KEYRING" | tr -d '\r')
    FSID=$(echo "$FSID" | tr -d '\r')
    
    if [[ -z "$MON_ENDPOINTS" ]] || [[ -z "$MON_SECRET" ]] || [[ -z "$ADMIN_KEYRING" ]] || [[ -z "$FSID" ]]; then
        error "Failed to fetch one or more secrets from ${ext_cluster} cluster."
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

    log "Applying secrets to configured client namespace (${LOCAL_NAMESPACE})..."
    
    mkdir -p "${OUTPUT_DIR}/rook-client-${ext_cluster}"
    
    if [[ "${ROOK_DEPLOY_MODE}" == "helm" ]]; then
        log "Mode is 'helm'. Generating values.yaml for upstream rook-ceph-cluster chart..."
        
        local helm_sc_prefix="${SC_PREFIX}"
        
        # 1. Base Auth Manifests (Helm doesn't generate these for external mode)
        cat <<EOF > "${OUTPUT_DIR}/rook-client-${ext_cluster}/secrets.yaml"
apiVersion: v1
kind: Namespace
metadata:
  name: ${LOCAL_NAMESPACE}
---
apiVersion: v1
kind: Secret
metadata:
  name: rook-ceph-mon
  namespace: ${LOCAL_NAMESPACE}
type: Opaque
data:
  mon-secret: $MON_SECRET
  cluster-name: $(echo -n "${REMOTE_NAMESPACE}" | base64 -w0)
  fsid: $FSID
  admin-secret: $ROOK_ADMIN_KEY_B64
  userID: $(echo -n "admin" | base64 -w0)
  userKey: $ROOK_ADMIN_KEY_B64
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: rook-ceph-mon-endpoints
  namespace: ${LOCAL_NAMESPACE}
data:
  data: "$MON_ENDPOINTS"
  mapping: "{}"
  maxMonId: "2"
---
apiVersion: v1
kind: Secret
metadata:
  name: rook-ceph-admin-keyring
  namespace: ${LOCAL_NAMESPACE}
type: kubernetes.io/rook
data:
  keyring: $ADMIN_KEYRING
EOF

        # 2. Values for the upstream chart
        cat <<EOF > "${OUTPUT_DIR}/rook-client-${ext_cluster}/values.yaml"
cephClusterSpec:
  external:
    enable: true
  dataDirHostPath: /var/lib/rook
  cephVersion:
    image: quay.io/ceph/ceph:v18.2.0
  healthCheck:
    daemonHealth:
      mon:
        disabled: false
        interval: 45s
  monitoring:
    enabled: false
  crashCollector:
    disable: true

cephBlockPools:
  - name: ceph-blockpool
    spec:
      failureDomain: host
      replicated:
        size: 3
    storageClass:
      enabled: true
      name: ${helm_sc_prefix}ceph-block
      isDefault: false
      reclaimPolicy: Delete
      allowVolumeExpansion: true
      parameters:
        clusterID: ${LOCAL_NAMESPACE}
        pool: ceph-blockpool
        imageFormat: "2"
        imageFeatures: layering
        csi.storage.k8s.io/provisioner-secret-name: rook-ceph-mon
        csi.storage.k8s.io/provisioner-secret-namespace: ${LOCAL_NAMESPACE}
        csi.storage.k8s.io/controller-expand-secret-name: rook-ceph-mon
        csi.storage.k8s.io/controller-expand-secret-namespace: ${LOCAL_NAMESPACE}
        csi.storage.k8s.io/node-stage-secret-name: rook-ceph-mon
        csi.storage.k8s.io/node-stage-secret-namespace: ${LOCAL_NAMESPACE}
        csi.storage.k8s.io/fstype: ext4

cephFileSystems:
  - name: ceph-filesystem
    spec:
      metadataPool:
        replicated:
          size: 3
      dataPools:
        - name: data0
          replicated:
            size: 3
      metadataServer:
        activeCount: 1
        activeStandby: true
    storageClass:
      enabled: true
      isDefault: false
      name: ${helm_sc_prefix}ceph-filesystem
      pool: data0
      reclaimPolicy: Delete
      allowVolumeExpansion: true
      parameters:
        clusterID: ${LOCAL_NAMESPACE}
        fsName: ceph-filesystem
        csi.storage.k8s.io/provisioner-secret-name: rook-ceph-mon
        csi.storage.k8s.io/provisioner-secret-namespace: ${LOCAL_NAMESPACE}
        csi.storage.k8s.io/controller-expand-secret-name: rook-ceph-mon
        csi.storage.k8s.io/controller-expand-secret-namespace: ${LOCAL_NAMESPACE}
        csi.storage.k8s.io/node-stage-secret-name: rook-ceph-mon
        csi.storage.k8s.io/node-stage-secret-namespace: ${LOCAL_NAMESPACE}
EOF

        log "Pushing Rook Client secrets and values to Bastion..."
        run_safe gcloud compute scp --recurse "${OUTPUT_DIR}/rook-client-${ext_cluster}" "${BASTION_NAME}:~" --zone "${ZONE}" --project="${PROJECT_ID}" --tunnel-through-iap
        
        log "Applying secrets and executing Helm chart on Bastion..."
        run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --project="${PROJECT_ID}" --tunnel-through-iap --command "
            # Apply base secrets
            kubectl apply -f rook-client-${ext_cluster}/secrets.yaml
            
            # Ensure Helm is installed
            if ! command -v helm &>/dev/null; then
                curl -f -sL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
            fi
            
            helm repo add rook-release https://charts.rook.io/release
            helm repo update
            
            helm upgrade --install rook-ceph rook-release/rook-ceph-cluster \\
                --version ${ROOK_CHART_VERSION} \\
                --namespace ${LOCAL_NAMESPACE} \\
                --values rook-client-${ext_cluster}/values.yaml
                
            EXIT_CODE=\$?
            rm -rf rook-client-${ext_cluster}
            exit \$EXIT_CODE
        "
        
    else
        log "Mode is 'operator'. Generating raw Kubernetes manifests..."
        
        # 1. Secrets
        cat <<EOF > "${OUTPUT_DIR}/rook-client-${ext_cluster}/secrets.yaml"
apiVersion: v1
kind: Namespace
metadata:
  name: ${LOCAL_NAMESPACE}
---
apiVersion: v1
kind: Secret
metadata:
  name: rook-ceph-mon
  namespace: ${LOCAL_NAMESPACE}
type: Opaque
data:
  mon-secret: $MON_SECRET
  cluster-name: $(echo -n "${REMOTE_NAMESPACE}" | base64 -w0)
  fsid: $FSID
  admin-secret: $ROOK_ADMIN_KEY_B64
  userID: $(echo -n "admin" | base64 -w0)
  userKey: $ROOK_ADMIN_KEY_B64
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: rook-ceph-mon-endpoints
  namespace: ${LOCAL_NAMESPACE}
data:
  data: "$MON_ENDPOINTS"
  mapping: "{}"
  maxMonId: "2"
---
apiVersion: v1
kind: Secret
metadata:
  name: rook-ceph-admin-keyring
  namespace: ${LOCAL_NAMESPACE}
type: kubernetes.io/rook
data:
  keyring: $ADMIN_KEYRING
EOF

        # 2. External Cluster CR
        cat <<EOF > "${OUTPUT_DIR}/rook-client-${ext_cluster}/external-cluster.yaml"
apiVersion: ceph.rook.io/v1
kind: CephCluster
metadata:
  name: rook-ceph
  namespace: ${LOCAL_NAMESPACE}
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
        cat <<EOF > "${OUTPUT_DIR}/rook-client-${ext_cluster}/storageclasses.yaml"
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${SC_PREFIX}ceph-block
provisioner: rook-ceph.rbd.csi.ceph.com
parameters:
  clusterID: ${LOCAL_NAMESPACE}
  pool: ceph-blockpool
  imageFormat: "2"
  imageFeatures: layering
  csi.storage.k8s.io/provisioner-secret-name: rook-ceph-mon
  csi.storage.k8s.io/provisioner-secret-namespace: ${LOCAL_NAMESPACE}
  csi.storage.k8s.io/controller-expand-secret-name: rook-ceph-mon
  csi.storage.k8s.io/controller-expand-secret-namespace: ${LOCAL_NAMESPACE}
  csi.storage.k8s.io/node-stage-secret-name: rook-ceph-mon
  csi.storage.k8s.io/node-stage-secret-namespace: ${LOCAL_NAMESPACE}
  csi.storage.k8s.io/fstype: ext4
allowVolumeExpansion: true
reclaimPolicy: Delete
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${SC_PREFIX}ceph-filesystem
provisioner: rook-ceph.cephfs.csi.ceph.com
parameters:
  clusterID: ${LOCAL_NAMESPACE}
  fsName: ceph-filesystem
  pool: ceph-filesystem-data0
  csi.storage.k8s.io/provisioner-secret-name: rook-ceph-mon
  csi.storage.k8s.io/provisioner-secret-namespace: ${LOCAL_NAMESPACE}
  csi.storage.k8s.io/controller-expand-secret-name: rook-ceph-mon
  csi.storage.k8s.io/controller-expand-secret-namespace: ${LOCAL_NAMESPACE}
  csi.storage.k8s.io/node-stage-secret-name: rook-ceph-mon
  csi.storage.k8s.io/node-stage-secret-namespace: ${LOCAL_NAMESPACE}
allowVolumeExpansion: true
reclaimPolicy: Delete
EOF

        # Apply via Bastion
        log "Pushing Rook Client manifests to Bastion..."
        run_safe gcloud compute scp --recurse "${OUTPUT_DIR}/rook-client-${ext_cluster}" "${BASTION_NAME}:~" --zone "${ZONE}" --project="${PROJECT_ID}" --tunnel-through-iap
        
        log "Applying manifests on Bastion..."
        # Add namespace creation strictly via direct execution to ensure namespace exists first
        run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --project="${PROJECT_ID}" --tunnel-through-iap --command "
            kubectl apply -f rook-client-${ext_cluster}/secrets.yaml && \\
            kubectl apply -f rook-client-${ext_cluster}/external-cluster.yaml && \\
            kubectl apply -f rook-client-${ext_cluster}/storageclasses.yaml
            EXIT_CODE=\$?
            rm -rf rook-client-${ext_cluster}
            exit \$EXIT_CODE
        "
    fi
    
    log "Rook Client configured successfully for ${ext_cluster} (Mode: ${ROOK_DEPLOY_MODE})."
}
