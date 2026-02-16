#!/bin/bash

# Rook Ceph Deployment via Helm

verify_rook_nodes() {
    log "Verifying Rook Ceph Node Infrastructure..."
    
    for pool in "${NODE_POOLS[@]}"; do
        # Sanitize pool name (e.g. rook-ceph-mon -> rook_ceph_mon)
        local safe_pool="${pool//-/_}"
        local count_var="POOL_${safe_pool^^}_COUNT"
        local expected_count="${!count_var:-0}"
        local label_var="POOL_${safe_pool^^}_LABELS"
        local labels="${!label_var:-}"
        
        # Extract the role label (e.g. role=ceph-osd) for filtering
        local role_label=""
        for l in ${labels//,/ }; do
            if [[ "$l" == role=* ]]; then
                role_label="$l"
                break
            fi
        done
        
        if [ -z "$role_label" ]; then
            warn "Pool '$pool' has no 'role=*' label. Skipping verification."
            continue
        fi
        
        if [[ "$expected_count" -gt 0 ]]; then
            log "  > Checking pool '$pool' (Expected: $expected_count, Label: $role_label)..."
            
            local actual_count=0
            local retries=30
            local wait_time=10
            
            for ((i=1; i<=retries; i++)); do
                 local cmd="kubectl get nodes -l $role_label --no-headers 2>/dev/null | wc -l"
                 local remote_output
                 
                 if remote_output=$(run_on_bastion "$cmd"); then
                     actual_count="${remote_output//[[:space:]]/}"
                     if [[ "$actual_count" -ge "$expected_count" ]]; then
                         log "    OK: Found $actual_count/$expected_count nodes."
                         break
                     fi
                 fi
                 
                 if [[ $i -lt $retries ]]; then
                     log "    Attempt $i/$retries: Found $actual_count/$expected_count nodes. Waiting ${wait_time}s..."
                     sleep $wait_time
                 fi
            done
            
            if [[ "$actual_count" -lt "$expected_count" ]]; then
                error "Node count mismatch for pool '$pool'. Expected: $expected_count, Found: $actual_count after $((retries * wait_time))s."
                error "Please provision the missing infrastructure before deploying Rook."
                exit 1
            fi
        fi
    done
}

wait_for_crd() {
    local crd_name="$1"
    local retries=30
    local wait_time=10
    
    log "Waiting for CRD '$crd_name' to be established..."
    for ((i=1; i<=retries; i++)); do
        if run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl get crd $crd_name" &>/dev/null; then
            log "CRD '$crd_name' is ready."
            return 0
        fi
        log "Attempt $i/$retries: CRD not yet ready. Waiting ${wait_time}s..."
        sleep $wait_time
    done
    
    error "Timed out waiting for CRD '$crd_name'."
    return 1
}

deploy_rook() {
    local FORCE_UPDATE="${1:-false}"
    
    # Pre-flight Verification
    verify_rook_nodes

    log "Deploying Rook Ceph Operator (Version: ${ROOK_CHART_VERSION}) via Helm..."
    
    # 0. Ensure Helm is installed on Bastion
    log "Ensuring Helm is installed on Bastion..."
    run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "
        set -o pipefail
        if ! command -v helm &>/dev/null; then
            echo 'Helm not found. Installing...'
            curl -f -sL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
        else
            echo 'Helm is already installed.'
        fi
    "

    # 1. Add Rook Helm Repo
    log "Adding Rook Helm Repo..."
    run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "
        helm repo add rook-release https://charts.rook.io/release
        helm repo update
    "

    # 2. Deploy Rook Operator
    log "Deploying Rook Operator..."
    # We must enable privileged mode for Talos
    run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "
        kubectl create namespace rook-ceph --dry-run=client -o yaml | kubectl apply -f -
        kubectl label namespace rook-ceph pod-security.kubernetes.io/enforce=privileged \\
            pod-security.kubernetes.io/audit=privileged \\
            pod-security.kubernetes.io/warn=privileged --overwrite

        helm upgrade --install --namespace rook-ceph rook-ceph rook-release/rook-ceph \\
            --version ${ROOK_CHART_VERSION} \\
            --set env.ROOK_HOSTPATH_REQUIRES_PRIVILEGED=true
            
        kubectl -n rook-ceph rollout status deployment/rook-ceph-operator --timeout=120s
        
        if ! kubectl get crd servicemonitors.monitoring.coreos.com &>/dev/null; then
            echo 'Installing ServiceMonitor CRD...'
            kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.71.2/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml
        else
            echo 'ServiceMonitor CRD already exists.'
        fi
    "

    # Ensure Rook CephCluster CRD is available before proceeding
    wait_for_crd "cephclusters.ceph.rook.io"

    deploy_rook_cluster
}

deploy_rook_cluster() {
    # 3. Deploy Rook Cluster
    log "Preparing Rook Cluster Configuration..."
    
    # Locate the pool that contains the data device to determine disk ordering
    local disk_config_str=""
    for pool in "${NODE_POOLS[@]}"; do
        local safe_pool="${pool//-/_}"
        local var_name="POOL_${safe_pool^^}_ADDITIONAL_DISKS"
        local disks="${!var_name}"
        if [[ "$disks" == *"$ROOK_DATA_DEVICE_NAME"* ]]; then
             disk_config_str="$disks"
             break
        fi
    done
    export ROOK_DISK_CONFIG="$disk_config_str"

    # Export variables for the helper script
    export ROOK_DATA_DEVICE_NAME
    export ROOK_METADATA_DEVICE_NAME
    export STORAGE_CIDR
    
    cat <<EOF > "${OUTPUT_DIR}/gen_rook_values.py"
import os
import yaml
import subprocess
import json
import sys

def get_nodes_info(label_selector):
    """Returns list of dicts {name, ip} for nodes matching label."""
    try:
        cmd = ["kubectl", "get", "nodes", "-l", label_selector, "-o", "json"]
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        data = json.loads(result.stdout)
        nodes = []
        for item in data.get('items', []):
            name = item['metadata']['name']
            ip = None
            for addr in item.get('status', {}).get('addresses', []):
                if addr['type'] == 'InternalIP':
                    ip = addr['address']
                    break
            nodes.append({'name': name, 'ip': ip})
        return nodes
    except subprocess.CalledProcessError as e:
        print(f"Error getting nodes ({label_selector}): {e}", file=sys.stderr)
        return []

def get_disk_path(device_name, disk_config_str):
    """
    Calculates the stable /dev/disk/by-path/ address for a given device name
    based on its index in the configuration string.
    Assumes GCP e2-standard (Virtio-SCSI) attachment order.
    Boot Disk: scsi-0:0:1:0
    Disk Index 0: scsi-0:0:2:0
    Disk Index N: scsi-0:0:(N+2):0
    """
    if not disk_config_str:
        return f"/dev/disk/by-id/google-{device_name}" # Default

    # Talos on GCP uses scsi-0Google_PersistentDisk_ prefix
    return f"/dev/disk/by-id/scsi-0Google_PersistentDisk_{device_name}"

def parse_size_to_bytes(size_str):
    """Converts a size string (e.g., '2Gi', '512Mi') to bytes."""
    if not size_str:
        return 0
    units = {"Ki": 1024, "Mi": 1024**2, "Gi": 1024**3, "Ti": 1024**4}
    for unit, multiplier in units.items():
        if size_str.endswith(unit):
             try:
                 return int(float(size_str[:-2]) * multiplier)
             except ValueError:
                 return 0
    try:
        return int(size_str)
    except ValueError:
        return 0

def get_osd_nodes():
    return [n['name'] for n in get_nodes_info("role=ceph-osd")]

def generate_values():
    data_device = os.environ.get('ROOK_DATA_DEVICE_NAME')
    metadata_device = os.environ.get('ROOK_METADATA_DEVICE_NAME')
    storage_cidr = os.environ.get('STORAGE_CIDR')
    disk_config = os.environ.get('ROOK_DISK_CONFIG')
    
    # Resource Limits (with defaults if unset or empty)
    osd_memory_limit_str = os.environ.get('ROOK_OSD_MEMORY') or '4Gi'
    osd_cpu_limit = os.environ.get('ROOK_OSD_CPU') or '2000m'
    mds_memory_limit = os.environ.get('ROOK_MDS_MEMORY') or '1Gi'
    mds_cpu_limit = os.environ.get('ROOK_MDS_CPU') or '500m'

    if not data_device:
        print("Error: ROOK_DATA_DEVICE_NAME not set.", file=sys.stderr)
        sys.exit(1)

    # Get Monitor IPs (role=ceph-mon)
    mon_label = "role=ceph-mon"
    mon_nodes_info = get_nodes_info(mon_label)

    if not mon_nodes_info:
        # Fallback to osd nodes if mon nodes specific label missing (converged)
        mon_label = "role=ceph-osd"
        mon_nodes_info = get_nodes_info(mon_label)
        
    mon_ips = [n['ip'] for n in mon_nodes_info if n['ip']]
    mon_host_str = ','.join(mon_ips)
    print(f"Monitor Hosts: {mon_host_str}")

    osd_nodes = get_osd_nodes()
    storage_nodes = []
    
    data_dev_path = get_disk_path(data_device, disk_config)
    meta_dev_path = None
    if metadata_device:
        meta_dev_path = get_disk_path(metadata_device, disk_config)
        
    for node in osd_nodes:
        node_config = {
            'name': node,
            'devices': [{'name': data_dev_path, 'config': {}}]
        }
        if meta_dev_path:
            node_config['devices'][0]['config']['metadataDevice'] = meta_dev_path
        storage_nodes.append(node_config)

    osd_memory_bytes = parse_size_to_bytes(osd_memory_limit_str)
    osd_memory_bytes = parse_size_to_bytes(osd_memory_limit_str)
    
    fs_spec = {
        'metadataServer': {
            'activeCount': 1, 
            'activeStandby': True, 
            'resources': {'limits': {'cpu': mds_cpu_limit, 'memory': mds_memory_limit}, 'requests': {'cpu': '100m', 'memory': '512Mi'}}
        },
        'metadataPool': {'replicated': {'size': 3}},
        'dataPools': [{'failureDomain': 'host', 'replicated': {'size': 3}, 'name': 'data0'}]
    }
    
    # Toleration/Affinity value depends on label
    mon_role_value = mon_label.split('=')[1]

    values = {
        'cephClusterSpec': {
            'cephVersion': {'image': 'quay.io/ceph/ceph:v18.2.4'},
            'mon': {'count': 3, 'allowMultiplePerNode': False},
            'mgr': {'count': 2, 'allowMultiplePerNode': False},
            'cleanupPolicy': {
                'sanitizeDisks': {'method': 'quick', 'dataSource': 'zero', 'iteration': 1},
                'wipeDevicesFromOtherClusters': True
            },
            'resources': {
                'mon': {'limits': {'cpu': '1000m', 'memory': '2Gi'}, 'requests': {'cpu': '100m', 'memory': '512Mi'}},
                'mgr': {'limits': {'cpu': '500m', 'memory': '1Gi'}, 'requests': {'cpu': '100m', 'memory': '512Mi'}},
                'osd': {'limits': {'cpu': osd_cpu_limit, 'memory': osd_memory_limit_str}, 'requests': {'cpu': '100m', 'memory': '512Mi'}}
            },
            'storage': {'useAllNodes': False, 'useAllDevices': False, 'nodes': storage_nodes},
            'placement': {
                'mon': {
                    'tolerations': [{'key': 'role', 'operator': 'Equal', 'value': mon_role_value, 'effect': 'NoSchedule'}],
                    'nodeAffinity': {'requiredDuringSchedulingIgnoredDuringExecution': {'nodeSelectorTerms': [{'matchExpressions': [{'key': 'role', 'operator': 'In', 'values': [mon_role_value]}]}]}}
                },
                'mgr': {
                    'tolerations': [{'key': 'role', 'operator': 'Equal', 'value': mon_role_value, 'effect': 'NoSchedule'}],
                    'nodeAffinity': {'requiredDuringSchedulingIgnoredDuringExecution': {'nodeSelectorTerms': [{'matchExpressions': [{'key': 'role', 'operator': 'In', 'values': [mon_role_value]}]}]}}
                }
            }
        },
        'configOverride': None,
        'cephFileSystems': [{'name': 'ceph-filesystem', 'spec': fs_spec, 'storageClass': {'enabled': True, 'isDefault': True, 'name': 'ceph-filesystem', 'pool': 'ceph-filesystem-data0', 'reclaimPolicy': 'Delete', 'allowVolumeExpansion': True}}],
        'cephBlockPools': [{
            'name': 'ceph-blockpool',
            'spec': {
                'failureDomain': 'host',
                'replicated': {'size': 3}
            },
            'storageClass': {
                'enabled': True,
                'name': 'ceph-block',
                'isDefault': False,
                'reclaimPolicy': 'Delete',
                'allowVolumeExpansion': True,
                'parameters': {
                    'imageFormat': '2',
                    'imageFeatures': 'layering' # simplified features for broad kernel support
                }
            }
        }],
        'toolbox': {'enabled': True},
        'monitoring': {'enabled': True}
    }

    if storage_cidr:
        print(f"Configuring Host Network with CIDR: {storage_cidr}")
        values['cephClusterSpec']['network'] = {
            'provider': 'host',
            'addressRanges': {'cluster': [storage_cidr]}
        }
    else:
        print("Using default CNI networking (No STORAGE_CIDR set).")

    with open("rook-values.yaml", "w") as f:
        yaml.dump(values, f)

if __name__ == "__main__":
    generate_values()
EOF

    log "Uploading generation script..."
    run_safe gcloud compute scp "${OUTPUT_DIR}/gen_rook_values.py" "${BASTION_NAME}:~" --zone "${ZONE}" --project="${PROJECT_ID}" --tunnel-through-iap
    
    log "Generating values.yaml on Bastion..."
    # Ensure dependencies (Quietly)
    run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "
        if ! dpkg -s python3-yaml &>/dev/null; then
            echo 'Installing python3-yaml...'
            sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-yaml
        fi
    "

    # Execute python script on bastion with env vars
    run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "
        export ROOK_DATA_DEVICE_NAME='${ROOK_DATA_DEVICE_NAME}'
        export ROOK_METADATA_DEVICE_NAME='${ROOK_METADATA_DEVICE_NAME}'
        export STORAGE_CIDR='${STORAGE_CIDR}'
        export ROOK_DISK_CONFIG='${ROOK_DISK_CONFIG}'
        export ROOK_MDS_CPU='${ROOK_MDS_CPU}'
        export ROOK_MDS_MEMORY='${ROOK_MDS_MEMORY}'
        export ROOK_OSD_CPU='${ROOK_OSD_CPU}'
        export ROOK_OSD_MEMORY='${ROOK_OSD_MEMORY}'
        python3 gen_rook_values.py
    "
    
    log "Deploying Rook Cluster Chart..."
    run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "
        # Cleanup stale jobs to force re-provisioning if config changed
        kubectl -n rook-ceph delete job -l app=rook-ceph-osd-prepare --ignore-not-found
        
        helm upgrade --install --namespace rook-ceph rook-ceph-cluster rook-release/rook-ceph-cluster \\
            --version ${ROOK_CHART_VERSION} \\
            --reset-values \\
            --values rook-values.yaml
    "
    
    log "Rook Ceph Cluster deployment initiated."
    rm -f "${OUTPUT_DIR}/gen_rook_values.py"

    # 4. Install Ceph Client on Bastion (if enabled)
    if [[ "${ROOK_ENABLE}" == "true" ]]; then
        install_ceph_client
    fi
}

install_ceph_client() {
    log "Configuring Ceph Client on Bastion..."
    
    run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "
        set -e
        
        # 1. Install ceph-common
        if ! command -v ceph &>/dev/null; then
            echo 'Installing ceph-common...'
            sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ceph-common
        else
            echo 'ceph-common is already installed.'
        fi

        # Wait for Secret
        echo 'Waiting for rook-ceph-admin-keyring secret...'
        for i in {1..60}; do
            if kubectl -n rook-ceph get secret rook-ceph-admin-keyring &>/dev/null; then
                break
            fi
            echo \"Attempt \$i/60: Secret not found. Waiting 10s...\"
            sleep 10
        done

        # 2. Extract Credentials
        echo 'Extracting credentials from cluster...'
        KEYRING_BASE64=\$(kubectl -n rook-ceph get secret rook-ceph-admin-keyring -o jsonpath='{.data.keyring}')
        
        if [ -z \"\$KEYRING_BASE64\" ]; then
            echo 'Error: Could not retrieve rook-ceph-admin-keyring secret.'
            exit 1
        fi

        # 3. Configure files
        echo \"\$KEYRING_BASE64\" | base64 -d | sudo tee /etc/ceph/ceph.client.admin.keyring >/dev/null
        sudo chmod 600 /etc/ceph/ceph.client.admin.keyring

        # Wait for CephCluster
        echo 'Waiting for CephCluster FSID...'
        for i in {1..60}; do
            FSID=\$(kubectl -n rook-ceph get cephcluster rook-ceph -o jsonpath='{.status.ceph.fsid}' 2>/dev/null)
            if [ -n \"\$FSID\" ]; then
                break
            fi
            echo \"Attempt \$i/60: FSID not ready. Waiting 10s...\"
            sleep 10
        done

        if [ -z \"\$FSID\" ]; then
             echo 'Error: Could not retrieve FSID.'
             exit 1
        fi
        
        # Get endpoints from ConfigMap (val=IP:port,...) and strip names
        echo 'Waiting for mon-endpoints ConfigMap...'
        for i in {1..60}; do
            MON_DATA=\$(kubectl -n rook-ceph get cm rook-ceph-mon-endpoints -o jsonpath='{.data.data}' 2>/dev/null)
            if [ -n \"\$MON_DATA\" ]; then
                break
            fi
            echo \"Attempt \$i/60: ConfigMap not ready. Waiting 10s...\"
            sleep 10
        done

        MON_HOSTS=\$(echo \"\$MON_DATA\" | sed 's/[a-z]=//g')
        
        echo \"[global]\" | sudo tee /etc/ceph/ceph.conf >/dev/null
        echo \"fsid = \$FSID\" | sudo tee -a /etc/ceph/ceph.conf >/dev/null
        echo \"mon_host = \$MON_HOSTS\" | sudo tee -a /etc/ceph/ceph.conf >/dev/null
        
        sudo chmod 644 /etc/ceph/ceph.conf
        sudo chmod 600 /etc/ceph/ceph.client.admin.keyring
        sudo chown \$USER:\$USER /etc/ceph/ceph.conf /etc/ceph/ceph.client.admin.keyring
        
        echo 'Ceph Client configured successfully.'
    "
    
    log "You can now run 'ceph status' on the bastion (without sudo)."
}
