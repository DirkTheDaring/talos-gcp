#!/bin/bash

# --- Phase 4: Lifecycle Management ---

apply() {
    set_names
    check_dependencies || return 1
    
    log "Applying configuration changes..."
    log "Target Worker Count: ${WORKER_COUNT}"
    
    # Ensure Images exist (create if missing, skip if present)
    ensure_role_images || return 1
    
    # Reconcile Workers (Create missing, Prune extra)
    phase2_workers || return 1
    
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
         local local_ver=$(talosctl version --client --short 2>/dev/null || echo "none")
         # Simple check (contains version string)
         if [[ "$local_ver" == *"${binary_version}"* ]]; then
             cp "$(which talosctl)" "${TALOSCTL_BIN}"
         else
             if command -v talosctl &>/dev/null; then
                 # Fallback to system one but warn
                 cp "$(which talosctl)" "${TALOSCTL_BIN}"
                 warn "Local talosctl ($local_ver) might not match requested ($binary_version)."
             else
                 warn "talosctl not found locally. Bootstrap might fail if not in PATH."
             fi
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
    if gcloud iam service-accounts describe "${SA_EMAIL}" --project="${PROJECT_ID}" &> /dev/null; then
            # Remove IAM bindings logic...
            local ROLE
            for ROLE in roles/compute.loadBalancerAdmin roles/compute.viewer roles/compute.securityAdmin roles/compute.networkViewer roles/compute.storageAdmin roles/compute.instanceAdmin.v1 roles/iam.serviceAccountUser; do
                gcloud projects remove-iam-policy-binding "${PROJECT_ID}" --member serviceAccount:"${SA_EMAIL}" --role "${ROLE}" --quiet &> /dev/null || true
            done
            gcloud iam service-accounts delete "${SA_EMAIL}" --project="${PROJECT_ID}" --quiet || warn "Could not delete SA."
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
    
    if [ -n "${OUTPUT_DIR}" ] && [ "${OUTPUT_DIR}" != "/" ]; then
        rm -rf "${OUTPUT_DIR}" "patch_config.py"
    else
        warn "Skipping dangerous cleanup of OUTPUT_DIR=${OUTPUT_DIR}"
    fi
    log "Cleanup Complete."
}
