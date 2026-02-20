# Proposal: Pluggable Rook-Ceph Deployment Modes (Server & Client)

## 1. Context & Motivation
Currently, setting `ROOK_ENABLE="true"` invokes a heavily automated deployment inside `lib/rook.sh`. For external client clusters (like `prod1`), `lib/rook-external.sh` dynamically fetches secrets via SSH, and then generates raw Kubernetes YAML manifests (Secrets, ConfigMaps, `CephCluster`, and StorageClasses) to apply via `kubectl`.

For robust GitOps/Helm-driven environments, applying raw manifests for major application topologies is undesirable. Users want to strictly utilize the standard upstream `rook-release/rook-ceph-cluster` Helm chart for both their server *and* client clusters, feeding it different `values.yaml` definitions.

## 2. Proposed Solution
We introduce a new configuration variable: `ROOK_DEPLOY_MODE`.

This variable will dictate *how* Rook is deployed when `ROOK_ENABLE="true"`.

### Allowed Values:
1. `operator` (Default for backwards compatibility): 
   Executes the current logic, generating and applying raw YAML manifests via `lib/rook.sh` and `lib/rook-external.sh`.
2. `helm`: 
   - **For Server deployments:** Executes a standard `helm install` against the upstream Rook Ceph chart utilizing a declarative `values.yaml`.
   - **For Client deployments (External Cluster):** 
     - The upstream `rook-ceph-cluster` chart supports external cluster connections via `cephClusterSpec.external.enable: true`. 
     - While the standard chart dictates that the low-level authentication `Secret`s must be created *prior* to installing the chart, the chart *can* completely template the `CephCluster` CR and `StorageClass` CRs internally based on its values.
     - Therefore, `talos-gcp` will continue to dynamically fetch the live auth tokens, but it will then isolate them into a clean `secrets.yaml` (applied via `kubectl`), and subsequently orchestrate the remainder of the deployment purely via `helm upgrade --install rook-ceph-cluster rook-release/rook-ceph-cluster --values rook-client-values.yaml`.

## 3. Implementation Steps

### Step 1: Update `lib/config.sh`
```bash
# Rook Ceph Defaults
ROOK_ENABLE="${ROOK_ENABLE:-false}"
+ ROOK_DEPLOY_MODE="${ROOK_DEPLOY_MODE:-helm}" # Options: operator, helm
ROOK_CHART_VERSION="${ROOK_CHART_VERSION:-v1.18.9}"
```

### Step 2: Refactor `lib/rook-external.sh`
Modify the script to support the `helm` mode. It will continue to run the `import_external_cluster_info()` loop to fetch the credentials. 

Instead of generating raw `CephCluster` and `StorageClass` manifests, it will do:
```bash
    if [[ "${ROOK_DEPLOY_MODE}" == "helm" ]]; then
        # 1. Generate core auth Secrets (Helm doesn't natively template these for external)
        cat <<EOF > "${OUTPUT_DIR}/rook-client-${ext_cluster}/secrets.yaml"
# ... Namespace, rook-ceph-mon Secret, rook-ceph-mon-endpoints ConfigMap, admin-keyring Secret ...
EOF
        
        # 2. Generate customized values.yaml for the upstream rook-ceph-cluster chart
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
      metadataServer:
        activeCount: 1
        activeStandby: true
    storageClass:
      enabled: true
      isDefault: false
      name: ${helm_sc_prefix}ceph-filesystem
      pool: ceph-filesystem-data0
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

        # 3. Ship and Apply
        run_safe gcloud compute ssh "${BASTION_NAME}" ... --command "
            kubectl apply -f rook-client-${ext_cluster}/secrets.yaml
            
            helm repo add rook-release https://charts.rook.io/release
            helm repo update
            
            helm upgrade --install rook-ceph rook-release/rook-ceph-cluster \\
                --version ${ROOK_CHART_VERSION} \\
                --namespace ${LOCAL_NAMESPACE} \\
                --values rook-client-${ext_cluster}/values.yaml
        "
    else
        # ... Fallback to old behavior ...
    fi
```

### 4. Implementation Details
Notice we completely bypass building local charts. We directly tap the `rook-release/rook-ceph-cluster` upstream chart that the core server natively uses. However, we feed it an explicit `values.yaml` detailing an `external` connection alongside specifically parametrized `storageClass` configurations.
