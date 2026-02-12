#!/bin/bash


phase2_infra_cp() {
    phase2_networking
    phase2_controlplane
}

phase2_controlplane() {
    log "Phase 2c: Control Plane..."

    # 1. Instance Group (Control Plane)
    if ! gcloud compute instance-groups unmanaged describe "${IG_CP_NAME}" --zone "${ZONE}" --project="${PROJECT_ID}" &> /dev/null; then
        run_safe gcloud compute instance-groups unmanaged create "${IG_CP_NAME}" --zone "${ZONE}" --project="${PROJECT_ID}"
        run_safe gcloud compute instance-groups set-named-ports "${IG_CP_NAME}" --named-ports tcp6443:6443 --zone "${ZONE}" --project="${PROJECT_ID}"
    fi

    # 2. Internal Load Balancer
    # Health Check
    if ! gcloud compute health-checks describe "${HC_CP_NAME}" --region "${REGION}" --project="${PROJECT_ID}" &> /dev/null; then
        run_safe gcloud compute health-checks create tcp "${HC_CP_NAME}" --region "${REGION}" --port 50000 --project="${PROJECT_ID}"
    fi
    # Backend Service
    if ! gcloud compute backend-services describe "${BE_CP_NAME}" --region "${REGION}" --project="${PROJECT_ID}" &> /dev/null; then
        run_safe gcloud compute backend-services create "${BE_CP_NAME}" --region "${REGION}" --load-balancing-scheme=INTERNAL --protocol=TCP --health-checks-region="${REGION}" --health-checks="${HC_CP_NAME}" --project="${PROJECT_ID}"
    fi
    # Enforce correct Health Check (Fixes 50000 vs 6443 drift)
    run_safe gcloud compute backend-services update "${BE_CP_NAME}" --region "${REGION}" --health-checks="${HC_CP_NAME}" --health-checks-region="${REGION}" --project="${PROJECT_ID}"
    # IP Address
    if ! gcloud compute addresses describe "${ILB_CP_IP_NAME}" --region "${REGION}" --project="${PROJECT_ID}" &> /dev/null; then
        run_safe gcloud compute addresses create "${ILB_CP_IP_NAME}" --region "${REGION}" --subnet "${SUBNET_NAME}" --purpose=GCE_ENDPOINT --project="${PROJECT_ID}"
    fi
    local CP_ILB_IP=$(gcloud compute addresses describe "${ILB_CP_IP_NAME}" --region "${REGION}" --format="value(address)" --project="${PROJECT_ID}")
    log "Control Plane Internal IP: ${CP_ILB_IP}"
    
    # Forwarding Rule
    if ! gcloud compute forwarding-rules describe "${ILB_CP_RULE}" --region "${REGION}" --project="${PROJECT_ID}" &> /dev/null; then
        run_safe gcloud compute forwarding-rules create "${ILB_CP_RULE}" --region "${REGION}" --load-balancing-scheme=INTERNAL --ports=6443,50000,50001 --network="${VPC_NAME}" --subnet="${SUBNET_NAME}" --address="${ILB_CP_IP_NAME}" --backend-service="${BE_CP_NAME}" --project="${PROJECT_ID}"
    fi

    # 3. Generate Secrets & Configs
    local SECRETS_FILE="${OUTPUT_DIR}/secrets.yaml"
    if gsutil -q stat "${GCS_SECRETS_URI}"; then
        log "Downloading existing secrets..."
        run_safe gsutil cp "${GCS_SECRETS_URI}" "${SECRETS_FILE}"
    else
        log "Generating new secrets..."
        rm -f "${SECRETS_FILE}"
        if command -v podman &> /dev/null; then
             run_safe podman run --rm -v "${OUTPUT_DIR}:/out:Z" -w /out "ghcr.io/siderolabs/talosctl:${CP_TALOS_VERSION}" gen secrets -o secrets.yaml
        elif command -v docker &> /dev/null; then
             run_safe docker run --rm -v "${OUTPUT_DIR}:/out:Z" -w /out "ghcr.io/siderolabs/talosctl:${CP_TALOS_VERSION}" gen secrets -o secrets.yaml
        else
             run_safe "$TALOSCTL" gen secrets -o "${SECRETS_FILE}"
        fi
        run_safe gsutil cp "${SECRETS_FILE}" "${GCS_SECRETS_URI}"
    fi
    chmod 600 "${SECRETS_FILE}"

    log "Generating Configs (Endpoint: https://${CP_ILB_IP}:6443)..."
    rm -f "${OUTPUT_DIR}/controlplane.yaml" "${OUTPUT_DIR}/worker.yaml" "${OUTPUT_DIR}/talosconfig"
    
    if command -v podman &> /dev/null; then
        run_safe podman run --rm -v "${OUTPUT_DIR}:/out:Z" -w /out "ghcr.io/siderolabs/talosctl:${CP_TALOS_VERSION}" gen config "${CLUSTER_NAME}" "https://${CP_ILB_IP}:6443" --with-secrets secrets.yaml --with-docs=false --with-examples=false
    elif command -v docker &> /dev/null; then
        run_safe docker run --rm -v "${OUTPUT_DIR}:/out:Z" -w /out "ghcr.io/siderolabs/talosctl:${CP_TALOS_VERSION}" gen config "${CLUSTER_NAME}" "https://${CP_ILB_IP}:6443" --with-secrets secrets.yaml --with-docs=false --with-examples=false
    else
        run_safe "$TALOSCTL" gen config "${CLUSTER_NAME}" "https://${CP_ILB_IP}:6443" --with-secrets "${SECRETS_FILE}" --with-docs=false --with-examples=false --output-dir "${OUTPUT_DIR}"
    fi

    # Patch Configs (External Cloud Provider & certSANs)
    cat <<PYEOF > "${OUTPUT_DIR}/patch_config.py"
import sys
import yaml
import os

def patch_file(filename, is_controlplane):
    if not os.path.exists(filename):
        return
    with open(filename, 'r') as f:
        docs = list(yaml.safe_load_all(f))
    for data in docs:
        if data.get('kind') == 'HostnameConfig': continue
        
        # 1. Cloud Provider
        if 'cluster' not in data: data['cluster'] = {}
        if 'externalCloudProvider' not in data['cluster']: data['cluster']['externalCloudProvider'] = {}
        data['cluster']['externalCloudProvider']['enabled'] = True
        
        # 2. certSANs (Control Plane Only)
        if is_controlplane:
            if 'machine' not in data: data['machine'] = {}
            
            # certSANs
            if 'certSANs' not in data['machine']: data['machine']['certSANs'] = []
            ilb_ip = "${CP_ILB_IP}"
            if ilb_ip and ilb_ip not in data['machine']['certSANs']:
                data['machine']['certSANs'].append(ilb_ip)
            
        # 4. Cilium Configuration (Conditional)
        install_cilium = "${INSTALL_CILIUM}" == "true"
        if install_cilium:
            # Disable Flannel CNI
            if 'cluster' not in data: data['cluster'] = {}
            if 'network' not in data['cluster']: data['cluster']['network'] = {}
            if 'cni' not in data['cluster']['network']: data['cluster']['network']['cni'] = {}
            data['cluster']['network']['cni']['name'] = 'none'

            # Disable KubeProxy
            if 'cluster' not in data: data['cluster'] = {}
            if 'proxy' not in data['cluster']: data['cluster']['proxy'] = {}
            data['cluster']['proxy']['disabled'] = True

            # Sysctls (Required for Cilium + GCP)
            if 'machine' not in data: data['machine'] = {}
            if 'sysctls' not in data['machine']: data['machine']['sysctls'] = {}
            data['machine']['sysctls']['net.ipv4.conf.all.rp_filter'] = "0"
            data['machine']['sysctls']['net.ipv4.conf.default.rp_filter'] = "0"
            data['machine']['sysctls']['net.ipv4.ip_forward'] = "1"
            data['machine']['sysctls']['net.ipv6.conf.all.forwarding'] = "1"

        # 5. Enable KubePrism (Port 7445)
        if 'machine' not in data: data['machine'] = {}
        if 'features' not in data['machine']: data['machine']['features'] = {}
        if 'kubePrism' not in data['machine']['features']: data['machine']['features']['kubePrism'] = {}
        data['machine']['features']['kubePrism']['enabled'] = True
        data['machine']['features']['kubePrism']['port'] = 7445

        # 6. Set Install Image (For Upgrades / Factory Support)
        if is_controlplane:
            install_image = "${CP_INSTALLER_IMAGE}"
        else:
            install_image = "${WORKER_INSTALLER_IMAGE}"
            
        if install_image:
            if 'machine' not in data: data['machine'] = {}
            if 'install' not in data['machine']: data['machine']['install'] = {}
            data['machine']['install']['image'] = install_image

        if install_image:
            if 'machine' not in data: data['machine'] = {}
            if 'install' not in data['machine']: data['machine']['install'] = {}
            data['machine']['install']['image'] = install_image

        # 7. Force Node IP Selection (Fixes Cert SAN mismatch)
        if 'machine' not in data: data['machine'] = {}
        if 'kubelet' not in data['machine']: data['machine']['kubelet'] = {}
        if 'nodeIP' not in data['machine']['kubelet']: data['machine']['kubelet']['nodeIP'] = {}
        # validSubnets forces Talos to pick IP from this range.
        # We strictly INCLUDE the Primary Subnet.
        # If STORAGE_CIDR is present, we EXCLUDE it.
        valid_subnets = ["${SUBNET_RANGE}"]
        storage_cidr_chk = "${STORAGE_CIDR}"
        # robustness: strip whitespace to avoid false positives on empty/blank strings
        if storage_cidr_chk and storage_cidr_chk.strip():
            valid_subnets.append("!" + storage_cidr_chk.strip())
        
        data['machine']['kubelet']['nodeIP']['validSubnets'] = valid_subnets

        # 8. Etcd Advertised Subnets (Fixes Peer URL Collision)
        # Force etcd to use the GCP Subnet for peering, ensuring unique IPs are advertised.
        if is_controlplane:
            if 'cluster' not in data: data['cluster'] = {}
            if 'etcd' not in data['cluster']: data['cluster']['etcd'] = {}
            # advertisedSubnets is a list of CIDRs
            # advertisedSubnets is a list of CIDRs
            advertised_subnets = ["${SUBNET_RANGE}"]
            ilb_ip = "${CP_ILB_IP}"
            # CRITICAL: Exclude the VIP from advertised subnets.
            # If the VIP is included, nodes may try to peer with themselves via the VIP (loopback),
            # causing "Peer URLs already exists" errors and quorum failure.
            # By excluding it, we force Etcd to use the unique Node IP in the subnet.
            if ilb_ip:
                advertised_subnets.append("!" + ilb_ip)
            data['cluster']['etcd']['advertisedSubnets'] = advertised_subnets

        # 8.5 Enforce Custom CIDRs (Service & Pod)
        if 'cluster' not in data: data['cluster'] = {}
        if 'network' not in data['cluster']: data['cluster']['network'] = {}
        
        # Service CIDR
        service_cidr = "${SERVICE_CIDR}"
        if service_cidr:
            data['cluster']['network']['serviceSubnets'] = [service_cidr]
            
        # Pod CIDR
        pod_cidr = "${POD_CIDR}"
        if pod_cidr:
            data['cluster']['network']['podSubnets'] = [pod_cidr]

        # Prepare Network Interfaces
        if 'machine' not in data: data['machine'] = {}
        if 'network' not in data['machine']: data['machine']['network'] = {}
        if 'interfaces' not in data['machine']['network']: data['machine']['network']['interfaces'] = []
        interfaces = data['machine']['network']['interfaces']

        # 8. Global Network Configuration (MTU & Interfaces)
        # Ensure nic0 (Primary) exists and has correct MTU (1460) for GCP.
        # This is CRITICAL to prevent DHCP/Etcd packet drops.
        nic0 = next((i for i in interfaces if i.get('deviceSelector', {}).get('busPath') == '0*'), None)
        if not nic0:
            nic0 = {'deviceSelector': {'busPath': '0*'}, 'dhcp': True}
            interfaces.insert(0, nic0)
        nic0['mtu'] = 1460

        # 9. Multi-NIC Routing (Storage Network)
        storage_cidr = "${STORAGE_CIDR}"
        if storage_cidr:
            # Configure nic1 (Storage)
            nic1 = next((i for i in interfaces if i.get('deviceSelector', {}).get('busPath') == '1*'), None)
            if not nic1:
                nic1 = {'deviceSelector': {'busPath': '1*'}}
                interfaces.append(nic1)
            
            nic1['dhcp'] = True
            nic1['mtu'] = 1460
            # Crucial: Prevent default gateway on storage network to force Primary IP selection
            nic1['ignoreDefaultRoute'] = True



    with open(filename, 'w') as f:
        yaml.safe_dump_all(docs, f)

patch_file("${OUTPUT_DIR}/controlplane.yaml", True)
patch_file("${OUTPUT_DIR}/worker.yaml", False)
PYEOF
    run_safe python3 "${OUTPUT_DIR}/patch_config.py"
    rm -f "${OUTPUT_DIR}/patch_config.py"
    
    # 4. Create Instances
    for ((i=0; i<${CP_COUNT}; i++)); do
        local cp_name="${CLUSTER_NAME}-cp-$i"
        # Workaround: gcloud filter hangs on checking non-existent instances. List all and grep locally.
        # Prepare Network Interface Flags
        local -a NETWORK_FLAGS
        # NIC0: Primary (Cluster Network)
        # MUST use --network-interface if mixing with --network-interface for nic1
        NETWORK_FLAGS=("--network-interface" "network=${VPC_NAME},subnet=${SUBNET_NAME},no-address")
        
        # NIC1: Storage Network (Optional)
        if [ -n "${STORAGE_CIDR:-}" ]; then
             NETWORK_FLAGS+=("--network-interface" "network=${VPC_STORAGE_NAME},subnet=${SUBNET_STORAGE_NAME},no-address")
        fi

        if ! gcloud compute instances list --zones "${ZONE}" --format="value(name)" --project="${PROJECT_ID}" | grep -q "^${cp_name}$"; then
            log "Creating control plane node $i (${cp_name})..."
            run_safe retry gcloud compute instances create "${cp_name}" \
                --image "${CP_IMAGE_NAME}" --zone "${ZONE}" --project="${PROJECT_ID}" \
                --machine-type="${CP_MACHINE_TYPE}" --boot-disk-size="${CP_DISK_SIZE}" \
                "${NETWORK_FLAGS[@]}" \
                --tags "talos-controlplane,${cp_name}" \
                --service-account="${CP_SERVICE_ACCOUNT}" --scopes cloud-platform \
                --labels="${LABELS:+${LABELS},}cluster=${CLUSTER_NAME},talos-version=${CP_TALOS_VERSION//./-},k8s-version=${KUBECTL_VERSION//./-},cilium-version=${CILIUM_VERSION//./-}" \
                --metadata-from-file=user-data="${OUTPUT_DIR}/controlplane.yaml"
        fi
        ensure_instance_in_ig "${cp_name}" "${IG_CP_NAME}"
    done

    # 5. Attach IG to Backend Service (Must be done AFTER instances exist so IG has a network)
    if ! gcloud compute backend-services describe "${BE_CP_NAME}" --region "${REGION}" --project="${PROJECT_ID}" | grep -q "group: .*${IG_CP_NAME}"; then
         log "Attaching Instance Group ${IG_CP_NAME} to Backend Service ${BE_CP_NAME}..."
         run_safe gcloud compute backend-services add-backend "${BE_CP_NAME}" --region "${REGION}" --instance-group "${IG_CP_NAME}" --instance-group-zone "${ZONE}" --project="${PROJECT_ID}"
    fi
}

phase3_run() {
    log "Phase 3: Waiting for Nodes to be RUNNING (max 10m)..."
    local MAX_RETRIES=60
    local COUNT=0
    
    while true; do
        # Use || echo "" to prevent set -e from killing the script on gcloud failure
        # Filter for control plane nodes explicitly
        STATUS=$(gcloud compute instances list --filter="name~'${CLUSTER_NAME}-cp-*' AND zone:(${ZONE})" --format="value(status)" --project="${PROJECT_ID}" | sort | uniq || echo "")
        
        if [ "$STATUS" == "RUNNING" ]; then
            log "All Control Plane nodes are RUNNING."
            break
        fi
        
        if [ -z "$STATUS" ]; then
             log "Waiting for instance readiness (API call failed or empty)... (Attempt $((COUNT+1))/$MAX_RETRIES)"
        else
             log "Control Plane node status: $STATUS. Waiting for RUNNING state... (Attempt $((COUNT+1))/$MAX_RETRIES, elapsed: $((COUNT*10))s)"
        fi
        
        sleep 10
        COUNT=$((COUNT+1))
        if [ $COUNT -ge $MAX_RETRIES ]; then
            error "Timeout waiting for nodes to start (10m exceed)."
            exit 1
        fi
    done
}
