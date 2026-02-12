#!/bin/bash

# --- Phase 4: Lifecycle Management ---

apply() {
    set_names
    check_dependencies || return 1
    
    log "Applying configuration changes..."
    log "Target Worker Count: ${WORKER_COUNT}"
    
    # Ensure Images exist (create if missing, skip if present)
    ensure_role_images || return 1
    
    # Reconcile Networking (Firewall Rules, etc.) - Allows Day 2 updates
    phase2_networking || return 1
    
    # Reconcile Workers (Create missing, Prune extra)
    phase2_workers || return 1
    
    # Update Schedule (Work Hours)
    update_schedule
    
    log "Apply complete. Run 'talos-gcp status' to verify."
    status
}

stop_nodes() {
    set_names
    # check_dependencies - Not needed
    log "Stopping all Talos nodes to save costs..."
    local INSTANCES
    INSTANCES=$(gcloud compute instances list --filter="name~'${CLUSTER_NAME}-.*' AND status:RUNNING AND zone:(${ZONE})" --format="value(name)" --project="${PROJECT_ID}")
    
    if [ -n "$INSTANCES" ]; then
        local INSTANCES_LIST
        INSTANCES_LIST=$(echo "$INSTANCES" | tr '\n' ' ')
        run_safe gcloud compute instances stop $INSTANCES_LIST --zone "${ZONE}" --project="${PROJECT_ID}"
        log "All nodes stopped."
    else
        log "No running nodes found."
    fi
}

start_nodes() {
    set_names
    # check_dependencies - Not needed
    log "Starting all Talos nodes..."
    local INSTANCES
    INSTANCES=$(gcloud compute instances list --filter="name~'${CLUSTER_NAME}-.*' AND (status:TERMINATED OR status:STOPPED) AND zone:(${ZONE})" --format="value(name)" --project="${PROJECT_ID}")
    
    if [ -n "$INSTANCES" ]; then
        local INSTANCES_LIST
        INSTANCES_LIST=$(echo "$INSTANCES" | tr '\n' ' ')
        run_safe gcloud compute instances start $INSTANCES_LIST --zone "${ZONE}" --project="${PROJECT_ID}"
        log "Nodes started."
    else
        log "No stopped nodes found."
    fi
}

phase1_resources() {
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

deploy_all() {
    set_names
    check_dependencies || return 1
    phase1_resources || return 1
    phase2_infra_cp || return 1 # Networking, CP
    phase2_bastion || return 1  # Create Bastion
    phase3_run || return 1      # Wait for CP
    phase4_bastion || return 1  # Wait for Bastion
    phase5_register || return 1 # Bootstrap, CNI, CCM, CSI
    
    # Create Workers AFTER CNI is ready (Critical for Cilium)
    phase2_workers || return 1
    
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
    
    if [ -n "${OUTPUT_DIR}" ] && [ "${OUTPUT_DIR}" != "/" ]; then
        rm -rf "${OUTPUT_DIR}" "patch_config.py"
    else
        warn "Skipping dangerous cleanup of OUTPUT_DIR=${OUTPUT_DIR}"
    fi
    log "Cleanup Complete."
}
