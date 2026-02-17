#!/bin/bash

# --- Phase 4: Lifecycle Management ---

apply() {
    set_names
    check_dependencies || return 1
    
    # Validation
    if [ "${ROOK_ENABLE}" == "true" ] && [ -n "${ROOK_EXTERNAL_CLUSTER_NAME}" ]; then
        error "Invalid Configuration: Cluster cannot be both Rook Server (ROOK_ENABLE=true) and Rook Client (ROOK_EXTERNAL_CLUSTER_NAME set)."
        return 1
    fi
    
    log "Updating Cluster Configuration..."
    log "Node Pools: ${NODE_POOLS[*]}"
    
    # Ensure Output Directory exists (Critical for generated files)
    mkdir -p "${OUTPUT_DIR}"
    
    # Ensure Images exist (create if missing, skip if present)
    ensure_role_images || return 1
    
    # Reconcile Networking (Firewall Rules, etc.) - Allows Day 2 updates
    provision_networking || return 1
    
    # Ensure Configs exist (for worker scaling/updates)
    generate_talos_configs || return 1
    
    # Reconcile Workers (Create missing, Prune extra)
    provision_workers || return 1
    
    # 2b. Apply Node Pool Labels/Taints
    apply_node_pool_labels
    
    # 2c. Rook Ceph (Optional - Automation coverage)
    if [ "${ROOK_ENABLE}" == "true" ]; then
        source "${SCRIPT_DIR}/lib/rook.sh"
        deploy_rook || return 1
    fi

    if [ -n "${ROOK_EXTERNAL_CLUSTER_NAME}" ]; then
        # Ensure we are peered (optional warning)
        if [[ ! " ${PEER_WITH[@]} " =~ " ${ROOK_EXTERNAL_CLUSTER_NAME} " ]]; then
            warn "ROOK_EXTERNAL_CLUSTER_NAME '${ROOK_EXTERNAL_CLUSTER_NAME}' is set, but it is not in PEER_WITH. Network connectivity might fail."
        fi
        source "${SCRIPT_DIR}/lib/rook-external.sh"
        deploy_rook_client || return 1
    fi
    
    # Update Schedule (Work Hours)
    update_schedule
    
    log "Apply complete. Run 'talos-gcp status' to verify."
    status
}

stop_nodes() {
    set_names
    local TARGET_CLUSTER="${1:-$CLUSTER_NAME}"
    local ZONE_FILTER="AND zone:(${ZONE})"
    
    if [ -n "${1:-}" ]; then
        log "Stopping cluster '${TARGET_CLUSTER}' (searching all zones)..."
        ZONE_FILTER=""
    else
        log "Stopping cluster '${TARGET_CLUSTER}' in zone ${ZONE}..."
    fi

    # check_dependencies - Not needed
    local INSTANCES
    INSTANCES=$(gcloud compute instances list --filter="labels.cluster=${TARGET_CLUSTER} AND status:RUNNING ${ZONE_FILTER}" --format="value(name,zone)" --project="${PROJECT_ID}")
    
    if [ -n "$INSTANCES" ]; then
        # We need to handle multiple zones if found
        while read -r instance_name instance_zone; do
            if [ -z "$instance_name" ]; then continue; fi
            log "Stopping ${instance_name} in ${instance_zone}..."
            run_safe gcloud compute instances stop "${instance_name}" --zone "${instance_zone}" --project="${PROJECT_ID}" &
        done <<< "$INSTANCES"
        wait
        log "Nodes stopped."
    else
        log "No running nodes found for '${TARGET_CLUSTER}'."
    fi
}

start_nodes() {
    set_names
    local TARGET_CLUSTER="${1:-$CLUSTER_NAME}"
    local ZONE_FILTER="AND zone:(${ZONE})"
    
    if [ -n "${1:-}" ]; then
        log "Starting cluster '${TARGET_CLUSTER}' (searching all zones)..."
        ZONE_FILTER=""
    else
        log "Starting cluster '${TARGET_CLUSTER}' in zone ${ZONE}..."
    fi

    # check_dependencies - Not needed
    local INSTANCES
    INSTANCES=$(gcloud compute instances list --filter="labels.cluster=${TARGET_CLUSTER} AND (status:TERMINATED OR status:STOPPED) ${ZONE_FILTER}" --format="value(name,zone)" --project="${PROJECT_ID}")
    
    if [ -n "$INSTANCES" ]; then
        # We need to handle multiple zones if found
        while read -r instance_name instance_zone; do
            if [ -z "$instance_name" ]; then continue; fi
            log "Starting ${instance_name} in ${instance_zone}..."
            run_safe gcloud compute instances start "${instance_name}" --zone "${instance_zone}" --project="${PROJECT_ID}" &
        done <<< "$INSTANCES"
        wait
        log "Nodes started."
    else
        log "No stopped nodes found for '${TARGET_CLUSTER}'."
    fi
}

provision_resources() {
    log "Phase 1: Resource Gathering..."
    check_apis
    check_quotas
    ensure_service_account
    
    # Ensure Images for both roles
    ensure_role_images || return 1
    
    # Create output directory
    mkdir -p "${OUTPUT_DIR}"
    
    # Ensure local talosctl matches CP version
    local binary_version="${CP_TALOS_VERSION}"
    local TALOSCTL_BIN="${OUTPUT_DIR}/talosctl"
    
    log "Ensuring local talosctl matches ${binary_version}..."
    if [ ! -f "${TALOSCTL_BIN}" ]; then
        if [ -n "${TALOSCTL:-}" ] && [ -x "${TALOSCTL}" ]; then
            log "Copying ensured talosctl from ${TALOSCTL}..."
            cp "${TALOSCTL}" "${TALOSCTL_BIN}"
            local local_ver=$("${TALOSCTL}" version --client --short 2>/dev/null || echo "none")
            if [[ "$local_ver" != *"${binary_version}"* ]]; then
                warn "Local talosctl ($local_ver) might not match requested ($binary_version)."
            fi
        else
            warn "TALOSCTL variable not set or binary not found. Skipping local copy."
        fi
        chmod +x "${TALOSCTL_BIN}" || true
    fi
}

provision_peering() {
    log "Phase 2b: Reconciling VPC Peering..."
    # Always run to handle cleanup of stale peerings even if PEER_WITH is empty
    source "${SCRIPT_DIR}/lib/peering.sh"
    reconcile_peering || return 1
}

deploy_all() {
    set_names
    check_dependencies || return 1

    # Validation
    if [ "${ROOK_ENABLE}" == "true" ] && [ -n "${ROOK_EXTERNAL_CLUSTER_NAME}" ]; then
        error "Invalid Configuration: Cluster cannot be both Rook Server (ROOK_ENABLE=true) and Rook Client (ROOK_EXTERNAL_CLUSTER_NAME set)."
        return 1
    fi
    
    # 1. Resources & Checks
    provision_resources || return 1
    
    # 2. Infrastructure (Networking & Control Plane)
    provision_controlplane_infra || return 1 
    
    # 2b. VPC Peering (Multi-Cluster)
    provision_peering || return 1
    
    # 3. Bastion Creation
    provision_bastion || return 1
    
    # 4. Wait for Control Plane to be RUNNING
    wait_for_controlplane || return 1
    
    # 4b. Ensure Clean Networking (Resolve Collisions)
    # Checks for duplicate Alias IPs which break routing and clears them on both nodes.
    # This allows connectivity to trigger configuration/bootstrap.
    resolve_collisions

    # 5. Configure Bastion (and push initial configs)
    configure_bastion || return 1
    
    # 6. Bootstrap & Kubeconfig
    bootstrap_etcd || return 1
    

    # 7. K8s Networking (VIP Alias & CNI)
    provision_k8s_networking || return 1
    
    # 8. K8s Addons (CCM & CSI)
    provision_k8s_addons || return 1
    
    # 9. Workers (Created only AFTER CNI is ready)
    provision_workers || return 1

    # Ensure Native Routing Aliases are correct (Fix for GCP inconsistencies)
    # 9a. Fix Aliases (Immediately after workers are created)
    fix_aliases

    # 9b. Apply Node Pool Labels/Taints
    # We do this after provisioning, though nodes might not be ready instantly.
    # The function handles "No nodes found" gracefully.
    apply_node_pool_labels
    
    # 9c. Rook Ceph (Optional - Automation coverage)
    # 1. Rook Host Cluster (Server)
    if [ "${ROOK_ENABLE}" == "true" ]; then
        source "${SCRIPT_DIR}/lib/rook.sh"
        deploy_rook || return 1
    fi

    # 2. Rook Client Cluster
    if [ -n "${ROOK_EXTERNAL_CLUSTER_NAME}" ]; then
        # Ensure we are peered (optional warning)
        if [[ ! " ${PEER_WITH[@]} " =~ " ${ROOK_EXTERNAL_CLUSTER_NAME} " ]]; then
            warn "ROOK_EXTERNAL_CLUSTER_NAME '${ROOK_EXTERNAL_CLUSTER_NAME}' is set, but it is not in PEER_WITH. Network connectivity might fail."
        fi
        source "${SCRIPT_DIR}/lib/rook-external.sh"
        deploy_rook_client || return 1
    fi
    
    # 10. Finalize Bastion (Sync /etc/skel)
    
    finalize_bastion_config || return 1
    
    # Update Schedule (Work Hours)
    update_schedule

    # Verify
    if [ "${INSTALL_CSI}" == "true" ]; then
        verify_storage || return 1
    fi
    
    log "Deployment Complete!"
    status
}

cleanup() {
    set_names
    echo -e "${RED}WARNING: You are about to DESTROY the Talos Cluster '${CLUSTER_NAME}' in:${NC}"
    echo -e "  Project: ${PROJECT_ID}"
    echo -e "  Zone:    ${ZONE}"
    echo -e "  Cluster: ${CLUSTER_NAME}"
    echo -e "This will delete instances, disks, networks, IGs, LBs, and IAM bindings."
    if [ "${CONFIRM_CHANGES:-true}" != "false" ]; then
        echo -n "Are you sure you want to proceed? [y/N] "
        read -r response
        if [[ ! "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
            log "Cleanup aborted."
            exit 0
        fi
    fi

    log "Cleaning up resources for cluster: ${CLUSTER_NAME}..."
    
    # 1. Delete Instances
    log "Deleting Instances..."
    local INSTANCES
    INSTANCES=$(gcloud compute instances list --filter="(labels.cluster=${CLUSTER_NAME} OR name~'${CLUSTER_NAME}-.*') AND zone:(${ZONE})" --format="value(name)" --project="${PROJECT_ID}")
    if [ -n "$INSTANCES" ]; then
        local INSTANCES_LIST
        INSTANCES_LIST=$(echo "$INSTANCES" | tr '\n' ' ')
        run_safe gcloud compute instances delete -q $INSTANCES_LIST --zone "${ZONE}" --project="${PROJECT_ID}" || warn "Failed to delete some instances."
    else
        log "No instances found."
    fi

    # 2. Cleanup Ingress (Workers)
    log "Cleaning up Ingress Resources..."
    # Configurable resources (Pattern Match)
    local ING_RULES=$(gcloud compute forwarding-rules list --filter="name~'${CLUSTER_NAME}-ingress.*'" --format="value(name)" --project="${PROJECT_ID}" --regions="${REGION}")
    if [ -n "$ING_RULES" ]; then
        # Must replace newlines with spaces for command args
        ING_RULES=$(echo "$ING_RULES" | tr '\n' ' ')
        gcloud compute forwarding-rules delete -q $ING_RULES --region "${REGION}" --project="${PROJECT_ID}" || true
    fi
    local ING_ADDRS=$(gcloud compute addresses list --filter="name~'${CLUSTER_NAME}-ingress.*'" --format="value(name)" --project="${PROJECT_ID}" --regions="${REGION}")
    if [ -n "$ING_ADDRS" ]; then
        ING_ADDRS=$(echo "$ING_ADDRS" | tr '\n' ' ')
        gcloud compute addresses delete -q $ING_ADDRS --region "${REGION}" --project="${PROJECT_ID}" || true
    fi
    local ING_FW=$(gcloud compute firewall-rules list --filter="name~'${FW_INGRESS_BASE}-.*'" --format="value(name)" --project="${PROJECT_ID}")
    if [ -n "$ING_FW" ]; then
        ING_FW=$(echo "$ING_FW" | tr '\n' ' ')
        gcloud compute firewall-rules delete -q $ING_FW --project="${PROJECT_ID}" || true
    fi

    # Worker Backend/HC/IG
    gcloud compute backend-services delete -q "${BE_WORKER_NAME}" --region "${REGION}" --project="${PROJECT_ID}" || true
    gcloud compute health-checks delete -q "${HC_WORKER_NAME}" --region "${REGION}" --project="${PROJECT_ID}" || true
    # UDP Worker Backend/HC
    gcloud compute backend-services delete -q "${BE_WORKER_UDP_NAME}" --region "${REGION}" --project="${PROJECT_ID}" || true
    gcloud compute health-checks delete -q "${HC_WORKER_UDP_NAME}" --region "${REGION}" --project="${PROJECT_ID}" || true
    
    gcloud compute instance-groups unmanaged delete -q "${IG_WORKER_NAME}" --zone "${ZONE}" --project="${PROJECT_ID}" || true
    
    # Custom Pool IGs
    if [ -n "${NODE_POOLS:-}" ]; then
        for pool in "${NODE_POOLS[@]}"; do
            local safe_pool="${pool//-/_}"
            local ig_name="${CLUSTER_NAME}-ig-${pool}"
            gcloud compute instance-groups unmanaged delete -q "${ig_name}" --zone "${ZONE}" --project="${PROJECT_ID}" || true
        done
    fi

    # 3. Cleanup Control Plane (Internal LB)
    log "Cleaning up Control Plane Resources..."
    gcloud compute forwarding-rules delete -q "${ILB_CP_RULE}" --region "${REGION}" --project="${PROJECT_ID}" || true
    gcloud compute addresses delete -q "${ILB_CP_IP_NAME}" --region "${REGION}" --project="${PROJECT_ID}" || true
    gcloud compute backend-services delete -q "${BE_CP_NAME}" --region "${REGION}" --project="${PROJECT_ID}" || true
    gcloud compute health-checks delete -q "${HC_CP_NAME}" --region "${REGION}" --project="${PROJECT_ID}" || true
    gcloud compute instance-groups unmanaged delete -q "${IG_CP_NAME}" --zone "${ZONE}" --project="${PROJECT_ID}" || true

    # 4. Old Cleanup (Backward Compatibility / Safety)
    # Just in case legacy resources exist (External LB)
    gcloud compute forwarding-rules delete -q "${FWD_RULE}" --global --project="${PROJECT_ID}" 2>/dev/null || true
    gcloud compute addresses delete -q "${LB_IP_NAME}" --global --project="${PROJECT_ID}" 2>/dev/null || true
    gcloud compute target-tcp-proxies delete -q "${PROXY_NAME}" --global --project="${PROJECT_ID}" 2>/dev/null || true
    gcloud compute backend-services delete -q "${BE_NAME}" --global --project="${PROJECT_ID}" 2>/dev/null || true
    gcloud compute health-checks delete -q "${HC_NAME}" --global --project="${PROJECT_ID}" 2>/dev/null || true
    gcloud compute instance-groups unmanaged delete -q "${IG_NAME}" --zone "${ZONE}" --project="${PROJECT_ID}" 2>/dev/null || true

    # 5. IAM & Network
    log "Cleaning up IAM & Network..."

    
    # --- Safe Service Account Deletion ---
    if gcloud iam service-accounts describe "${SA_EMAIL}" --project="${PROJECT_ID}" &> /dev/null; then
        # Remove IAM bindings logic...
        local ROLE
        for ROLE in roles/compute.loadBalancerAdmin roles/compute.viewer roles/compute.securityAdmin roles/compute.networkViewer roles/compute.storageAdmin roles/compute.instanceAdmin.v1 roles/iam.serviceAccountUser; do
            gcloud projects remove-iam-policy-binding "${PROJECT_ID}" --member serviceAccount:"${SA_EMAIL}" --role "${ROLE}" --quiet &> /dev/null || true
        done
        
        # Safety Check: Only delete if matches generated pattern OR force flag is present
        # Pattern: ${CLUSTER_NAME}-${HASH}-sa OR ${CLUSTER_NAME}-sa (Legacy)
        # We construct a regex to match safe patterns.
        # Hash is 4 chars hex (or similar).
        # Legacy is just -sa.
        # Custom names should be preserved unless --delete-service-account is used.
        
        local DELETE_SA="false"
        
        # Check for Force Flag (via env var or arg, assummed env var DELETE_SERVICE_ACCOUNT from args parsing in main script if implemented, or just safest default)
        if [ "${DELETE_SERVICE_ACCOUNT:-false}" == "true" ]; then
            DELETE_SA="true"
        else
            # Auto-Detection
            # We restricting to [0-9a-f] to match md5sum hex output (and cksum digits).
            # This prevents deleting custom names like 'prod' or 'test' (which have non-hex chars).
            if [[ "${SA_NAME}" =~ ^${CLUSTER_NAME}-[0-9a-f]{4}-sa$ ]] || [[ "${SA_NAME}" == "${CLUSTER_NAME}-sa" ]]; then
                DELETE_SA="true"
            fi
        fi
        
        if [ "$DELETE_SA" == "true" ]; then
            log "Deleting Service Account '${SA_EMAIL}'..."
            gcloud iam service-accounts delete "${SA_EMAIL}" --project="${PROJECT_ID}" --quiet || warn "Could not delete SA."
        else
            log "Preserving Service Account '${SA_EMAIL}' (Does not match auto-generated pattern or --delete-service-account not set)."
            warn "If you wish to delete it, run: gcloud iam service-accounts delete ${SA_EMAIL}"
        fi
    fi

    # Delete ALL Firewall Rules attached to the VPC (Automated Cleanup)
    log "Cleaning up all Firewall Rules for network '${VPC_NAME}'..."
    local ALL_VPC_FW
    # Use regex filter to match the network name at the end of the URL
    ALL_VPC_FW=$(gcloud compute firewall-rules list --filter="network ~ .*/${VPC_NAME}$" --format="value(name)" --project="${PROJECT_ID}")
    
    if [ -n "$ALL_VPC_FW" ]; then
        # Convert newlines to spaces
        local ALL_VPC_FW_LIST
        ALL_VPC_FW_LIST=$(echo "$ALL_VPC_FW" | tr '\n' ' ')
        run_safe gcloud compute firewall-rules delete -q $ALL_VPC_FW_LIST --project="${PROJECT_ID}" || warn "Failed to delete some firewall rules."
    else
        log "No remaining firewall rules found for '${VPC_NAME}'."
    fi
    
    gcloud compute routers nats delete -q "${NAT_NAME}" --router "${ROUTER_NAME}" --region "${REGION}" --project="${PROJECT_ID}" || true
    gcloud compute routers delete -q "${ROUTER_NAME}" --region "${REGION}" --project="${PROJECT_ID}" || true
    
    # Delete VPC Peerings (Must be done before deleting VPC)
    log "Cleaning up VPC Peerings..."
    local PEERINGS
    PEERINGS=$(gcloud compute networks peerings list --network="${VPC_NAME}" --project="${PROJECT_ID}" --format="value(name)" 2>/dev/null)
    if [ -n "$PEERINGS" ]; then
        for peering in $PEERINGS; do
            log "  - Deleting peering '${peering}'..."
            run_safe gcloud compute networks peerings delete "${peering}" --network="${VPC_NAME}" --project="${PROJECT_ID}" --quiet || warn "Failed to delete peering '${peering}'."
        done
    fi

    if ! gcloud compute networks subnets delete -q "${SUBNET_NAME}" --region "${REGION}" --project="${PROJECT_ID}"; then
        warn "Could not delete Subnet."
    fi
    gcloud compute networks delete -q "${VPC_NAME}" --project="${PROJECT_ID}" || true

    # --- Storage Network Cleanup (Multi-NIC) ---
    # We explicitly define the names here to ensure cleanup happens even if STORAGE_CIDR (and thus the config.sh variables) 
    # are missing from the current environment/config.
    local LOCAL_VPC_STORAGE="${CLUSTER_NAME}-storage-vpc"
    local LOCAL_SUBNET_STORAGE="${CLUSTER_NAME}-storage-subnet"
    local LOCAL_FW_STORAGE="${CLUSTER_NAME}-storage-internal"

    if [ -n "${LOCAL_VPC_STORAGE}" ]; then
        log "Checking for Storage Network resources..."
        # Firewall
        if gcloud compute firewall-rules describe "${LOCAL_FW_STORAGE}" --project="${PROJECT_ID}" &>/dev/null; then
            log "Deleting Storage Firewall '${LOCAL_FW_STORAGE}'..."
            run_safe gcloud compute firewall-rules delete -q "${LOCAL_FW_STORAGE}" --project="${PROJECT_ID}" || warn "Failed to delete storage firewall."
        fi
        
        # Subnet
        if gcloud compute networks subnets describe "${LOCAL_SUBNET_STORAGE}" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
            log "Deleting Storage Subnet '${LOCAL_SUBNET_STORAGE}'..."
            run_safe gcloud compute networks subnets delete -q "${LOCAL_SUBNET_STORAGE}" --region="${REGION}" --project="${PROJECT_ID}" || warn "Failed to delete storage subnet."
        fi

        # VPC
        if gcloud compute networks describe "${LOCAL_VPC_STORAGE}" --project="${PROJECT_ID}" &>/dev/null; then
            log "Deleting Storage VPC '${LOCAL_VPC_STORAGE}'..."
            run_safe gcloud compute networks delete -q "${LOCAL_VPC_STORAGE}" --project="${PROJECT_ID}" || warn "Failed to delete storage VPC."
        fi
    fi

    # --- Schedule Policy Cleanup ---
    if [ -n "${SCHEDULE_POLICY_NAME}" ]; then
        if gcloud compute resource-policies describe "${SCHEDULE_POLICY_NAME}" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
             log "Deleting Schedule Policy '${SCHEDULE_POLICY_NAME}'..."
             run_safe gcloud compute resource-policies delete -q "${SCHEDULE_POLICY_NAME}" --region="${REGION}" --project="${PROJECT_ID}" || warn "Failed to delete schedule policy."
        fi
    fi

    # --- GCS Cleanup ---
    log "Cleaning up GCS Bucket Artifacts..."
    if [ -n "${BUCKET_NAME}" ] && [ -n "${CLUSTER_NAME}" ]; then
        # secrets.yaml (Known)
        if gsutil -q stat "${GCS_SECRETS_URI}" &>/dev/null; then
            log "Deleting secrets.yaml from ${GCS_SECRETS_URI}..."
            run_safe gsutil rm "${GCS_SECRETS_URI}" || warn "Failed to delete secrets.yaml."
        fi

        # talosconfig/kubeconfig (User Request / Safety)
        # We assume standard paths gs://BUCKET/CLUSTER/filename
        local GCS_BASE="gs://${BUCKET_NAME}/${CLUSTER_NAME}"
        
        if gsutil -q stat "${GCS_BASE}/talosconfig" &>/dev/null; then
            log "Deleting talosconfig from bucket..."
            run_safe gsutil rm "${GCS_BASE}/talosconfig" || true
        fi
        
        if gsutil -q stat "${GCS_BASE}/kubeconfig" &>/dev/null; then
            log "Deleting kubeconfig from bucket..."
            run_safe gsutil rm "${GCS_BASE}/kubeconfig" || true
        fi
    fi
    
    if [ -n "${OUTPUT_DIR}" ] && [ "${OUTPUT_DIR}" != "/" ]; then
        rm -rf "${OUTPUT_DIR}" "patch_config.py"
    else
        warn "Skipping dangerous cleanup of OUTPUT_DIR=${OUTPUT_DIR}"
    fi
    log "Cleanup Complete."
}
