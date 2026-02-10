#!/bin/bash

# --- Phase 4: Lifecycle Management ---

scale_up() {
    set_names
    check_quotas
    check_permissions
    local CURRENT_WORKERS
    # Filter by label 'cluster=${CLUSTER_NAME}' and name pattern
    CURRENT_WORKERS=$(gcloud compute instances list --filter="labels.cluster=${CLUSTER_NAME} AND name~'${CLUSTER_NAME}-worker.*'" --format="value(name)" --project="${PROJECT_ID}")
    
    local MAX_INDEX=-1
    for worker in $CURRENT_WORKERS; do
        local suffix="${worker##*-}"
        if [[ "$suffix" =~ ^[0-9]+$ ]]; then
            if [ "$suffix" -gt "$MAX_INDEX" ]; then
                MAX_INDEX=$suffix
            fi
        fi
    done
    
    local NEXT_INDEX=$((MAX_INDEX + 1))
    local WORKER="${CLUSTER_NAME}-worker-${NEXT_INDEX}"
    
    log "Scaling up: Creating ${WORKER}..."
    if [ ! -f "${OUTPUT_DIR}/worker.yaml" ]; then error "${OUTPUT_DIR}/worker.yaml not found!"; exit 1; fi
    
    create_worker_instance "${WORKER}"
        
    log "Scaling operations complete."
        
    log "Scaling operations complete."
    status
}

scale_down() {
    set_names
    check_dependencies
    local CURRENT_WORKERS
    CURRENT_WORKERS=$(gcloud compute instances list --filter="labels.cluster=${CLUSTER_NAME} AND name~'${CLUSTER_NAME}-worker.*'" --format="value(name)" --project="${PROJECT_ID}")
    
    local MAX_INDEX=-1
    local TARGET_WORKER=""
    
    for worker in $CURRENT_WORKERS; do
        local suffix="${worker##*-}"
        if [[ "$suffix" =~ ^[0-9]+$ ]]; then
            if [ "$suffix" -gt "$MAX_INDEX" ]; then
                MAX_INDEX=$suffix
                TARGET_WORKER="$worker"
            fi
        fi
    done
    
    if [ -z "$TARGET_WORKER" ] || [ "$MAX_INDEX" -eq -1 ]; then
        error "No worker nodes found!"
        exit 1
    fi
    
    if [ "$MAX_INDEX" -eq 0 ]; then
        warn "Refusing to delete worker-0. Use cleanup to destroy the cluster."
        exit 1
    fi
    
    log "Scaling down: Deleting ${TARGET_WORKER}..."
    run_safe gcloud compute instances delete "${TARGET_WORKER}" --zone "${ZONE}" --project="${PROJECT_ID}" -q
    # IG automatically updates
    log "Scale down complete."
}

stop_nodes() {
    set_names
    check_dependencies
    log "Stopping all Talos nodes to save costs..."
    INSTANCES=$(gcloud compute instances list --filter="name~'${CLUSTER_NAME}-.*' AND status:RUNNING AND zone:(${ZONE})" --format="value(name)" --project="${PROJECT_ID}")
    
    if [ -n "$INSTANCES" ]; then
        INSTANCES_LIST=$(echo "$INSTANCES" | tr '\n' ' ')
        run_safe gcloud compute instances stop $INSTANCES_LIST --zone "${ZONE}" --project="${PROJECT_ID}"
        log "All nodes stopped."
    else
        log "No running nodes found."
    fi
}

start_nodes() {
    set_names
    check_dependencies
    log "Starting all Talos nodes..."
    INSTANCES=$(gcloud compute instances list --filter="name~'${CLUSTER_NAME}-.*' AND (status:TERMINATED OR status:STOPPED) AND zone:(${ZONE})" --format="value(name)" --project="${PROJECT_ID}")
    
    if [ -n "$INSTANCES" ]; then
        INSTANCES_LIST=$(echo "$INSTANCES" | tr '\n' ' ')
        run_safe gcloud compute instances start $INSTANCES_LIST --zone "${ZONE}" --project="${PROJECT_ID}"
        log "Nodes started."
    else
        log "No stopped nodes found."
    fi
}

deploy_all() {
    set_names
    check_dependencies
    phase1_resources
    phase2_infra_cp # Networking, CP
    phase2_bastion  # Create Bastion
    phase3_run      # Wait for CP
    phase4_bastion  # Wait for Bastion
    phase5_register # Bootstrap, CNI, CCM, CSI
    
    # Create Workers AFTER CNI is ready (Critical for Cilium)
    phase2_workers
    
    # Verify
    if [ "${INSTALL_CSI}" == "true" ]; then
        verify_storage
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
    echo -n "Are you sure you want to proceed? [y/N] "
    read -r response
    if [[ ! "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        log "Cleanup aborted."
        exit 0
    fi

    log "Cleaning up resources for cluster: ${CLUSTER_NAME}..."
    
    # 1. Delete Instances
    log "Deleting Instances..."
    INSTANCES=$(gcloud compute instances list --filter="(labels.cluster=${CLUSTER_NAME} OR name~'${CLUSTER_NAME}-.*') AND zone:(${ZONE})" --format="value(name)" --project="${PROJECT_ID}")
    if [ -n "$INSTANCES" ]; then
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
    
    rm -rf "${OUTPUT_DIR}" "patch_config.py"
    log "Cleanup Complete."
}
