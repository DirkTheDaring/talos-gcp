#!/bin/bash

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
    
    # 1. Verify Region and Zone Safety (Fail Fast)
    log "Verifying resources location..."
    
    # Check Instances (Global Scan for Mismatches)
    local STRAY_INSTANCES
    if ! STRAY_INSTANCES=$(gcloud compute instances list --filter="(labels.cluster=${CLUSTER_NAME} OR name~'${CLUSTER_NAME}-.*') AND NOT zone:(${ZONE})" --format="value(name,zone)" --project="${PROJECT_ID}"); then
         error "Failed to list instances. Please check your connection and permissions."
         exit 1
    fi
    
    if [ -n "$STRAY_INSTANCES" ]; then
        error "Safety Check Failed: Found instances for cluster '${CLUSTER_NAME}' in zones merging from '${ZONE}'!"
        echo "${STRAY_INSTANCES}"
        error "Please update your configuration to match these resources or delete them manually."
        exit 1
    fi

    # Check Router Region Mismatch
    # We only check if the router exists at all first.
    if gcloud compute routers describe "${ROUTER_NAME}" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
        log "Router '${ROUTER_NAME}' verified in region '${REGION}'."
    else
        # Not found in target region. Check elsewhere.
        local FOUND_REGIONS
        if ! FOUND_REGIONS=$(gcloud compute routers list --filter="name=${ROUTER_NAME}" --format="value(region)" --project="${PROJECT_ID}" | awk -F/ '{print $NF}'); then
             error "Failed to list routers. Aborting safety check for router '${ROUTER_NAME}'."
             exit 1
        fi
        
        if [ -n "$FOUND_REGIONS" ]; then
             error "Safety Check Failed: Router '${ROUTER_NAME}' not found in configured region '${REGION}', but found in: ${FOUND_REGIONS}."
             error "Please update your configuration (REGION) to match the existing infrastructure before destroying."
             exit 1
        fi
        # If not found anywhere, strictly speaking safely proceed (idempotent), or warn.
        warn "Router '${ROUTER_NAME}' not found in region '${REGION}' (or anywhere). Assuming already deleted."
    fi

    # 1. Delete Instances (Strict Zone)
    log "Deleting Instances in zone ${ZONE}..."
    local INSTANCES
    if ! INSTANCES=$(gcloud compute instances list --filter="(labels.cluster=${CLUSTER_NAME} OR name~'${CLUSTER_NAME}-.*') AND zone:(${ZONE})" --format="value(name)" --project="${PROJECT_ID}"); then
         error "Failed to list instances in zone ${ZONE}. Cleanup aborted for safety."
         exit 1
    fi
    
    if [ -n "$INSTANCES" ]; then
        local INSTANCES_LIST
        INSTANCES_LIST=$(echo "$INSTANCES" | tr '\n' ' ')
        gcloud compute instances delete -q $INSTANCES_LIST --zone "${ZONE}" --project="${PROJECT_ID}" --quiet || warn "Failed to delete some instances."
    else
        log "No instances found in zone ${ZONE}."
    fi

    # 2. Cleanup Ingress (Workers)
    log "Cleaning up Ingress Resources..."
    # Configurable resources (Pattern Match)
    local ING_RULES
    if ! ING_RULES=$(gcloud compute forwarding-rules list --filter="name~'${CLUSTER_NAME}-ingress.*'" --format="value(name)" --project="${PROJECT_ID}" --regions="${REGION}"); then
        warn "Failed to list Ingress Rules for cleanup."
    fi
    if [ -n "$ING_RULES" ]; then
        # Must replace newlines with spaces for command args
        ING_RULES=$(echo "$ING_RULES" | tr '\n' ' ')
        gcloud compute forwarding-rules delete -q $ING_RULES --region "${REGION}" --project="${PROJECT_ID}" --quiet || warn "Failed to delete Ingress Rules."
    fi
    local ING_ADDRS
    if ! ING_ADDRS=$(gcloud compute addresses list --filter="name~'${CLUSTER_NAME}-ingress.*'" --format="value(name)" --project="${PROJECT_ID}" --regions="${REGION}"); then
        warn "Failed to list Ingress IPs for cleanup."
    fi
    if [ -n "$ING_ADDRS" ]; then
        ING_ADDRS=$(echo "$ING_ADDRS" | tr '\n' ' ')
        gcloud compute addresses delete -q $ING_ADDRS --region "${REGION}" --project="${PROJECT_ID}" --quiet || warn "Failed to delete Ingress IPs."
    fi
    local ING_FW
    if ! ING_FW=$(gcloud compute firewall-rules list --filter="name~'${FW_INGRESS_BASE}-.*'" --format="value(name)" --project="${PROJECT_ID}"); then
        warn "Failed to list Ingress Firewalls for cleanup."
    fi
    if [ -n "$ING_FW" ]; then
        ING_FW=$(echo "$ING_FW" | tr '\n' ' ')
        gcloud compute firewall-rules delete -q $ING_FW --project="${PROJECT_ID}" --quiet || warn "Failed to delete Ingress Firewalls."
    fi

    if gcloud compute backend-services describe "${BE_WORKER_NAME}" --region "${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
        gcloud compute backend-services delete -q "${BE_WORKER_NAME}" --region "${REGION}" --project="${PROJECT_ID}" --quiet || warn "Failed to delete Backend Service '${BE_WORKER_NAME}'"
    fi
    
    if gcloud compute health-checks describe "${HC_WORKER_NAME}" --region "${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
        gcloud compute health-checks delete -q "${HC_WORKER_NAME}" --region "${REGION}" --project="${PROJECT_ID}" --quiet || warn "Failed to delete Health Check '${HC_WORKER_NAME}'"
    fi

    # UDP Worker Backend/HC
    if gcloud compute backend-services describe "${BE_WORKER_UDP_NAME}" --region "${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
        gcloud compute backend-services delete -q "${BE_WORKER_UDP_NAME}" --region "${REGION}" --project="${PROJECT_ID}" --quiet || warn "Failed to delete UDP Backend '${BE_WORKER_UDP_NAME}'"
    fi
        
    if gcloud compute health-checks describe "${HC_WORKER_UDP_NAME}" --region "${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
        gcloud compute health-checks delete -q "${HC_WORKER_UDP_NAME}" --region "${REGION}" --project="${PROJECT_ID}" --quiet || warn "Failed to delete UDP Health Check '${HC_WORKER_UDP_NAME}'"
    fi
    
    # Check IG existence before delete
    if gcloud compute instance-groups unmanaged describe "${IG_WORKER_NAME}" --zone "${ZONE}" --project="${PROJECT_ID}" &>/dev/null; then
        gcloud compute instance-groups unmanaged delete -q "${IG_WORKER_NAME}" --zone "${ZONE}" --project="${PROJECT_ID}" --quiet || warn "Failed to delete Instance Group '${IG_WORKER_NAME}'"
    fi
    
    # Custom Pool IGs
    if [ -n "${NODE_POOLS:-}" ]; then
        for pool in "${NODE_POOLS[@]}"; do
            local safe_pool="${pool//-/_}"
            local ig_name="${CLUSTER_NAME}-ig-${pool}"
            if gcloud compute instance-groups unmanaged describe "${ig_name}" --zone "${ZONE}" --project="${PROJECT_ID}" &>/dev/null; then
                 gcloud compute instance-groups unmanaged delete -q "${ig_name}" --zone "${ZONE}" --project="${PROJECT_ID}" --quiet || warn "Failed to delete custom pool IG '${ig_name}'"
            fi
        done
    fi

    # 3. Cleanup Control Plane (Internal LB)
    log "Cleaning up Control Plane Resources..."
    
    if gcloud compute forwarding-rules describe "${ILB_CP_RULE}" --region "${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
        gcloud compute forwarding-rules delete -q "${ILB_CP_RULE}" --region "${REGION}" --project="${PROJECT_ID}" --quiet || warn "Failed to delete ILB Rule '${ILB_CP_RULE}'"
    fi
        
    if gcloud compute addresses describe "${ILB_CP_IP_NAME}" --region "${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
        gcloud compute addresses delete -q "${ILB_CP_IP_NAME}" --region "${REGION}" --project="${PROJECT_ID}" --quiet || warn "Failed to delete ILB IP '${ILB_CP_IP_NAME}'"
    fi
        
    if gcloud compute backend-services describe "${BE_CP_NAME}" --region "${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
        gcloud compute backend-services delete -q "${BE_CP_NAME}" --region "${REGION}" --project="${PROJECT_ID}" --quiet || warn "Failed to delete CP Backend '${BE_CP_NAME}'"
    fi
        
    if gcloud compute health-checks describe "${HC_CP_NAME}" --region "${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
        gcloud compute health-checks delete -q "${HC_CP_NAME}" --region "${REGION}" --project="${PROJECT_ID}" --quiet || warn "Failed to delete CP Health Check '${HC_CP_NAME}'"
    fi
        
    if gcloud compute instance-groups unmanaged describe "${IG_CP_NAME}" --zone "${ZONE}" --project="${PROJECT_ID}" &>/dev/null; then
        gcloud compute instance-groups unmanaged delete -q "${IG_CP_NAME}" --zone "${ZONE}" --project="${PROJECT_ID}" --quiet || warn "Failed to delete CP IG '${IG_CP_NAME}'"
    fi

    # 4. Old Cleanup (Backward Compatibility / Safety)
    # Just in case legacy resources exist (External LB)
    if gcloud compute forwarding-rules describe "${FWD_RULE}" --global --project="${PROJECT_ID}" &>/dev/null; then
        gcloud compute forwarding-rules delete -q "${FWD_RULE}" --global --project="${PROJECT_ID}" --quiet || warn "Failed to delete Legacy Rule '${FWD_RULE}'"
    fi
        
    if gcloud compute addresses describe "${LB_IP_NAME}" --global --project="${PROJECT_ID}" &>/dev/null; then
        gcloud compute addresses delete -q "${LB_IP_NAME}" --global --project="${PROJECT_ID}" --quiet || warn "Failed to delete Legacy IP '${LB_IP_NAME}'"
    fi
        
    if gcloud compute target-tcp-proxies describe "${PROXY_NAME}" --global --project="${PROJECT_ID}" &>/dev/null; then
        gcloud compute target-tcp-proxies delete -q "${PROXY_NAME}" --global --project="${PROJECT_ID}" --quiet || warn "Failed to delete Legacy Proxy '${PROXY_NAME}'"
    fi
        
    if gcloud compute backend-services describe "${BE_NAME}" --global --project="${PROJECT_ID}" &>/dev/null; then
        gcloud compute backend-services delete -q "${BE_NAME}" --global --project="${PROJECT_ID}" --quiet || warn "Failed to delete Legacy Backend '${BE_NAME}'"
    fi
        
    if gcloud compute health-checks describe "${HC_NAME}" --global --project="${PROJECT_ID}" &>/dev/null; then
        gcloud compute health-checks delete -q "${HC_NAME}" --global --project="${PROJECT_ID}" --quiet || warn "Failed to delete Legacy HC '${HC_NAME}'"
    fi
        
    if gcloud compute instance-groups unmanaged describe "${IG_NAME}" --zone "${ZONE}" --project="${PROJECT_ID}" &>/dev/null; then
        gcloud compute instance-groups unmanaged delete -q "${IG_NAME}" --zone "${ZONE}" --project="${PROJECT_ID}" --quiet || warn "Failed to delete Legacy IG '${IG_NAME}'"
    fi

    # 5. IAM & Network
    log "Cleaning up IAM & Network..."

    
    # --- Safe Service Account Deletion ---
    if gcloud iam service-accounts describe "${SA_EMAIL}" --project="${PROJECT_ID}" &> /dev/null; then
        # Remove IAM bindings logic...
        local ROLE
        for ROLE in roles/compute.loadBalancerAdmin roles/compute.viewer roles/compute.securityAdmin roles/compute.networkViewer roles/compute.storageAdmin roles/compute.instanceAdmin.v1 roles/iam.serviceAccountUser; do
            gcloud projects remove-iam-policy-binding "${PROJECT_ID}" --member serviceAccount:"${SA_EMAIL}" --role "${ROLE}" --quiet &> /dev/null || warn "Failed to remove role ${ROLE} from SA."
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
    if ! ALL_VPC_FW=$(gcloud compute firewall-rules list --filter="network ~ .*/${VPC_NAME}$" --format="value(name)" --project="${PROJECT_ID}"); then
         warn "Failed to list VPC Firewall Rules. Some rules might remain."
    fi
    
    if [ -n "$ALL_VPC_FW" ]; then
        # Convert newlines to spaces
        local ALL_VPC_FW_LIST
        ALL_VPC_FW_LIST=$(echo "$ALL_VPC_FW" | tr '\n' ' ')
        gcloud compute firewall-rules delete -q $ALL_VPC_FW_LIST --project="${PROJECT_ID}" --quiet || warn "Failed to delete some firewall rules."
    else
        log "No remaining firewall rules found for '${VPC_NAME}'."
    fi
    
    if gcloud compute routers nats describe "${NAT_NAME}" --router "${ROUTER_NAME}" --region "${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
        gcloud compute routers nats delete -q "${NAT_NAME}" --router "${ROUTER_NAME}" --region "${REGION}" --project="${PROJECT_ID}" --quiet || warn "Failed to delete Cloud NAT '${NAT_NAME}'"
    fi
    
    if gcloud compute routers describe "${ROUTER_NAME}" --region "${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
        gcloud compute routers delete -q "${ROUTER_NAME}" --region "${REGION}" --project="${PROJECT_ID}" --quiet || warn "Failed to delete Router '${ROUTER_NAME}'"
    fi
    
    # Delete VPC Peerings (Must be done before deleting VPC)
    log "Cleaning up VPC Peerings..."
    local PEERINGS
    if ! PEERINGS=$(gcloud compute networks peerings list --network="${VPC_NAME}" --project="${PROJECT_ID}" --format="value(name)" 2>/dev/null); then
         warn "Failed to list VPC Peerings. VPC deletion might fail."
    fi
    if [ -n "$PEERINGS" ]; then
        for peering in $PEERINGS; do
            log "  - Deleting peering '${peering}'..."
            gcloud compute networks peerings delete "${peering}" --network="${VPC_NAME}" --project="${PROJECT_ID}" --quiet || warn "Failed to delete peering '${peering}'."
        done
    fi

    if gcloud compute networks subnets describe "${SUBNET_NAME}" --region "${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
         if ! gcloud compute networks subnets delete -q "${SUBNET_NAME}" --region "${REGION}" --project="${PROJECT_ID}"; then
             warn "Could not delete Subnet."
         fi
    fi

    if gcloud compute networks describe "${VPC_NAME}" --project="${PROJECT_ID}" &>/dev/null; then
         gcloud compute networks delete -q "${VPC_NAME}" --project="${PROJECT_ID}" --quiet || warn "Failed to delete VPC '${VPC_NAME}'"
    fi

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
            gcloud compute firewall-rules delete -q "${LOCAL_FW_STORAGE}" --project="${PROJECT_ID}" --quiet || warn "Failed to delete storage firewall."
        fi
        
        # Subnet
        if gcloud compute networks subnets describe "${LOCAL_SUBNET_STORAGE}" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
            log "Deleting Storage Subnet '${LOCAL_SUBNET_STORAGE}'..."
            gcloud compute networks subnets delete -q "${LOCAL_SUBNET_STORAGE}" --region="${REGION}" --project="${PROJECT_ID}" --quiet || warn "Failed to delete storage subnet."
        fi

        # VPC
        if gcloud compute networks describe "${LOCAL_VPC_STORAGE}" --project="${PROJECT_ID}" &>/dev/null; then
            log "Deleting Storage VPC '${LOCAL_VPC_STORAGE}'..."
            gcloud compute networks delete -q "${LOCAL_VPC_STORAGE}" --project="${PROJECT_ID}" --quiet || warn "Failed to delete storage VPC."
        fi
    fi

    # --- Schedule Policy Cleanup ---
    if [ -n "${SCHEDULE_POLICY_NAME}" ]; then
        if gcloud compute resource-policies describe "${SCHEDULE_POLICY_NAME}" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
             log "Deleting Schedule Policy '${SCHEDULE_POLICY_NAME}'..."
             gcloud compute resource-policies delete -q "${SCHEDULE_POLICY_NAME}" --region="${REGION}" --project="${PROJECT_ID}" --quiet || warn "Failed to delete schedule policy."
        fi
    fi

    # --- GCS Cleanup ---
    log "Cleaning up GCS Bucket Artifacts..."
    if [ -n "${BUCKET_NAME}" ] && [ -n "${CLUSTER_NAME}" ]; then
        # secrets.yaml (Known)
        if gsutil -q stat "${GCS_SECRETS_URI}" &>/dev/null; then
            log "Deleting secrets.yaml from ${GCS_SECRETS_URI}..."
            gsutil rm "${GCS_SECRETS_URI}" || warn "Failed to delete secrets.yaml."
        fi

        # talosconfig/kubeconfig (User Request / Safety)
        # We assume standard paths gs://BUCKET/CLUSTER/filename
        local GCS_BASE="gs://${BUCKET_NAME}/${CLUSTER_NAME}"
        
        if gsutil -q stat "${GCS_BASE}/talosconfig" &>/dev/null; then
            log "Deleting talosconfig from bucket..."
            gsutil rm "${GCS_BASE}/talosconfig" || warn "Failed to delete talosconfig."
        fi
        
        if gsutil -q stat "${GCS_BASE}/kubeconfig" &>/dev/null; then
            log "Deleting kubeconfig from bucket..."
            gsutil rm "${GCS_BASE}/kubeconfig" || warn "Failed to delete kubeconfig."
        fi
    fi
    
    if [ -n "${OUTPUT_DIR}" ] && [ "${OUTPUT_DIR}" != "/" ]; then
        rm -rf "${OUTPUT_DIR}"
    else
        warn "Skipping dangerous cleanup of OUTPUT_DIR=${OUTPUT_DIR}"
    fi
    log "Cleanup Complete."
}
