#!/bin/bash

# Rook Ceph Deployment via Helm

deploy_rook() {
    local FORCE_UPDATE="${1:-false}"
    log "Deploying Rook Ceph (Version: ${ROOK_CHART_VERSION})..."

    install_rook_operator
    deploy_rook_cluster
}

install_rook_operator() {
    # 0. Ensure Helm is installed on Bastion (Reuse CNI logic or simple check)
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

    # 1. Add Helm Repo
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
    "
    
    log "Waiting for Rook Operator to rollout..."
    run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl -n rook-ceph rollout status deployment/rook-ceph-operator --timeout=120s"

    # Pre-requisite for Monitoring: ServiceMonitor CRD
    log "Ensuring Prometheus Operator CRDs exist..."
    run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "
        if ! kubectl get crd servicemonitors.monitoring.coreos.com &>/dev/null; then
            echo 'Installing ServiceMonitor CRD...'
            kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.71.2/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml
        else
            echo 'ServiceMonitor CRD already exists.'
        fi
    "

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

def get_osd_nodes():
    try:
        # Get nodes with label role=ceph-osd
        cmd = ["kubectl", "get", "nodes", "-l", "role=ceph-osd", "-o", "json"]
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        data = json.loads(result.stdout)
        return [item['metadata']['name'] for item in data.get('items', [])]
    except subprocess.CalledProcessError as e:
        print(f"Error getting nodes: {e}", file=sys.stderr)
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
        return f"/dev/disk/by-id/google-{device_name}" # Fallback
        
    disks = disk_config_str.strip().split()
    target_index = -1
    
    for idx, disk_def in enumerate(disks):
        parts = disk_def.split(':')
        # Format: type:size:name
        if len(parts) >= 3 and parts[2] == device_name:
            target_index = idx
            break
            
    if target_index != -1:
        # Calculate SCSI ID
        scsi_id = target_index + 2
        return f"/dev/disk/by-path/pci-0000:00:03.0-scsi-0:0:{scsi_id}:0"
        
    return f"/dev/disk/by-id/google-{device_name}" # Fallback if not found

def generate_values():
    data_device = os.environ.get('ROOK_DATA_DEVICE_NAME')
    metadata_device = os.environ.get('ROOK_METADATA_DEVICE_NAME')
    storage_cidr = os.environ.get('STORAGE_CIDR')
    disk_config = os.environ.get('ROOK_DISK_CONFIG')

    if not data_device:
        print("Error: ROOK_DATA_DEVICE_NAME not set.", file=sys.stderr)
        sys.exit(1)

    nodes = get_osd_nodes()
    if not nodes:
        print("Warning: No nodes found with label role=ceph-osd. Cluster might be empty.", file=sys.stderr)
    
    # Build Storage Nodes Config
    storage_nodes = []
    
    # Pre-calculate paths
    data_dev_path = get_disk_path(data_device, disk_config)
    meta_dev_path = None
    if metadata_device:
        meta_dev_path = get_disk_path(metadata_device, disk_config)
        
    print(f"Resolved Data Device '{data_device}' to: {data_dev_path}")
    if meta_dev_path:
        print(f"Resolved Metadata Device '{metadata_device}' to: {meta_dev_path}")

    for node in nodes:
        node_config = {
            "name": node,
            "devices": [
                {
                    "name": data_dev_path,
                    "config": {}
                }
            ]
        }
        
        # Add metadata device if configured
        if meta_dev_path:
            node_config["devices"][0]["config"]["metadataDevice"] = meta_dev_path
            
        storage_nodes.append(node_config)

    values = {
        "cephClusterSpec": {
            "mon": {
                "count": 3,
                "allowMultiplePerNode": False
            },
            "mgr": {
                "count": 2,
                "allowMultiplePerNode": False
            },
            "storage": {
                "useAllNodes": False,
                "useAllDevices": False,
                "nodes": storage_nodes
            },
            "resources": {
                "osd": {
                    "limits": {
                        "cpu": os.environ.get('ROOK_OSD_CPU', '1'),
                        "memory": os.environ.get('ROOK_OSD_MEMORY', '2Gi')
                    },
                    "requests": {
                         "cpu": os.environ.get('ROOK_OSD_CPU', '1'),
                         "memory": os.environ.get('ROOK_OSD_MEMORY', '2Gi')
                    }
                }
            }
        },
        "cephFileSystems": [
            {
                "name": "ceph-filesystem",
                "spec": {
                    "metadataServer": {
                        "activeCount": 1,
                        "activeStandby": True,
                        "resources": {
                            "limits": {
                                "cpu": os.environ.get('ROOK_MDS_CPU', '3'),
                                "memory": os.environ.get('ROOK_MDS_MEMORY', '4Gi')
                            },
                            "requests": {
                                "cpu": os.environ.get('ROOK_MDS_CPU', '3'),
                                "memory": os.environ.get('ROOK_MDS_MEMORY', '4Gi')
                            }
                        }
                    },
                    "metadataPool": {
                        "replicated": {
                            "size": 3
                        }
                    },
                    "dataPools": [
                        {
                            "failureDomain": "host",
                            "replicated": {
                                "size": 3
                            },
                            "name": "data0"
                        }
                    ]
                },
                "storageClass": {
                    "enabled": True,
                    "isDefault": True,
                    "name": "ceph-filesystem",
                    "pool": "ceph-filesystem-data0",
                    "reclaimPolicy": "Delete",
                    "allowVolumeExpansion": True
                }
            }
        ],
        "toolbox": {
            "enabled": True 
        },
        "monitoring": {
            "enabled": True
        }
    }

    # Conditional Network Configuration
    if storage_cidr:
        print(f"Configuring Host Network with CIDR: {storage_cidr}")
        values["cephClusterSpec"]["network"] = {
            "provider": "host",
            "addressRanges": {
                "cluster": [storage_cidr]
                # public defaults to empty (host network)
            }
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

        FSID=\$(kubectl -n rook-ceph get cephcluster rook-ceph -o jsonpath='{.status.ceph.fsid}')
        
        # Get endpoints from ConfigMap (val=IP:port,...) and strip names
        MON_DATA=\$(kubectl -n rook-ceph get cm rook-ceph-mon-endpoints -o jsonpath='{.data.data}')
        MON_HOSTS=\$(echo "\$MON_DATA" | sed 's/[a-z]=//g')
        
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
