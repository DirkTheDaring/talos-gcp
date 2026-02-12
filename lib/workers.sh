#!/bin/bash

phase2_workers() {
    log "Phase 2d: Workers & Ingress..."
    # Rely on global variables from set_names
   
    
    # 1. Instance Group (Worker)
    if ! gcloud compute instance-groups unmanaged describe "${IG_WORKER_NAME}" --zone "${ZONE}" --project="${PROJECT_ID}" &> /dev/null; then
        run_safe gcloud compute instance-groups unmanaged create "${IG_WORKER_NAME}" --zone "${ZONE}" --project="${PROJECT_ID}"
    fi

    # Create/Update Ingress Resources
    apply_ingress

    # 3. Create Worker Instances
    for ((i=0; i<${WORKER_COUNT}; i++)); do
        create_worker_instance "${CLUSTER_NAME}-worker-$i"
    done
    # 4. Prune Extra Workers
    prune_workers
}

create_worker_instance() {
    local worker_name="$1"
    
    # Build Disk Flags
    local -a DISK_FLAGS
    if [ -n "${WORKER_ADDITIONAL_DISKS:-}" ]; then
        local disk_index=0
        for disk_def in ${WORKER_ADDITIONAL_DISKS}; do
            IFS=':' read -r dtype dsize dname <<< "${disk_def}"
            
            # Validation: Must have at least type and size
            if [[ -z "$dtype" || -z "$dsize" ]]; then
                error "Invalid WORKER_ADDITIONAL_DISKS definition: '${disk_def}'. Format: type:size[:device-name]"
                exit 1
            fi

            [ -z "${dname}" ] && dname="disk-${disk_index}"
            local gcp_disk_name="${worker_name}-disk-${disk_index}"
            DISK_FLAGS+=("--create-disk=name=${gcp_disk_name},size=${dsize},type=${dtype},device-name=${dname},mode=rw,auto-delete=yes")
            ((disk_index++))
        done
        log "Adding disks to ${worker_name}: ${DISK_FLAGS[*]}"
    fi

    # Workaround: gcloud filter hangs.
    # Prepare Network Interface Flags
    local ALIAS_FLAG=""
    if [ "${CILIUM_ROUTING_MODE:-}" == "native" ]; then
        # Format: RANGE_NAME:CIDR_LENGTH (e.g. pods:/24)
        ALIAS_FLAG=",aliases=pods:/24"
    fi

    local -a NETWORK_FLAGS
    # NIC0: Primary (Cluster Network)
    # MUST use --network-interface if mixing with --network-interface for nic1
    NETWORK_FLAGS=("--network-interface" "network=${VPC_NAME},subnet=${SUBNET_NAME},no-address${ALIAS_FLAG}")
    
    # NIC1: Storage Network (Optional)
    if [ -n "${STORAGE_CIDR:-}" ]; then
            NETWORK_FLAGS+=("--network-interface" "network=${VPC_STORAGE_NAME},subnet=${SUBNET_STORAGE_NAME},no-address")
    fi

    if gcloud compute instances list --zones "${ZONE}" --format="value(name)" --project="${PROJECT_ID}" | grep -q "^${worker_name}$"; then
         # Check for Drift (Machine Type)
         local current_mt
         current_mt=$(gcloud compute instances describe "${worker_name}" --zone "${ZONE}" --project="${PROJECT_ID}" --format="value(machineType)" 2>/dev/null)
         # Extract basename
         current_mt="${current_mt##*/}"
         
         if [ "$current_mt" != "${WORKER_MACHINE_TYPE}" ]; then
             warn "Worker ${worker_name} exists but has machine type '${current_mt}' (Expected: '${WORKER_MACHINE_TYPE}')."
             warn "To apply the new machine type, you must recreate the worker:"
             warn "  ./talos-gcp prune-worker ${worker_name} (Conceptual command, manually delete for now)"
             warn "  gcloud compute instances delete ${worker_name} --zone ${ZONE}"
         else
             log "Worker ${worker_name} exists and matches configuration."
         fi
    else
         log "Creating worker node (${worker_name})..."
         run_safe retry gcloud compute instances create "${worker_name}" \
            --image "${WORKER_IMAGE_NAME}" --zone "${ZONE}" --project="${PROJECT_ID}" \
            --machine-type="${WORKER_MACHINE_TYPE}" --boot-disk-size="${WORKER_DISK_SIZE}" \
            "${NETWORK_FLAGS[@]}" \
            --service-account="${WORKER_SERVICE_ACCOUNT}" --scopes cloud-platform \
            --tags "talos-worker,${worker_name}" \
            --labels="${LABELS:+${LABELS},}cluster=${CLUSTER_NAME},talos-version=${WORKER_TALOS_VERSION//./-},k8s-version=${KUBECTL_VERSION//./-},cilium-version=${CILIUM_VERSION//./-}" \
            --metadata-from-file=user-data="${OUTPUT_DIR}/worker.yaml" \
            "${DISK_FLAGS[@]}"
    fi
    ensure_instance_in_ig "${worker_name}" "${IG_WORKER_NAME}"
}

prune_workers() {
    log "Checking for extra worker nodes to prune (Target: ${WORKER_COUNT})..."
    # List all worker nodes for this cluster
    local existing_workers
    existing_workers=$(gcloud compute instances list --filter="name~'${CLUSTER_NAME}-worker-.*' AND zone:(${ZONE})" --format="value(name)" --project="${PROJECT_ID}")
    
    for instance in $existing_workers; do
        # Parse index from name (assuming ${CLUSTER_NAME}-worker-N)
        local prefix="${CLUSTER_NAME}-worker-"
        local suffix="${instance#$prefix}"
        
        # Check if suffix is a number
        if [[ "$suffix" =~ ^[0-9]+$ ]]; then
            if (( suffix >= WORKER_COUNT )); then
                log "Found extra worker node: ${instance} (Index ${suffix} >= ${WORKER_COUNT})..."
                
                # Check for confirmation
                if [ "${CONFIRM_CHANGES:-true}" == "true" ]; then
                    read -p "Are you sure you want to DELETE ${instance}? [y/N] " -r
                    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                        log "Skipping deletion of ${instance}."
                        continue
                    fi
                else
                     log "Auto-confirming deletion of ${instance} (Non-interactive mode)."
                fi

                # 1. Remove from Instance Group (idempotent-ish, ignore error if not found)
                if gcloud compute instance-groups unmanaged list-instances "${IG_WORKER_NAME}" --zone "${ZONE}" --project="${PROJECT_ID}" | grep -q "${instance}"; then
                     log "Removing ${instance} from Instance Group ${IG_WORKER_NAME}..."
                     run_safe gcloud compute instance-groups unmanaged remove-instances "${IG_WORKER_NAME}" \
                        --instances="${instance}" --zone "${ZONE}" --project="${PROJECT_ID}"
                fi
                
                # 2. Delete Instance
                log "Deleting instance ${instance}..."
                run_safe gcloud compute instances delete "${instance}" --zone "${ZONE}" --project="${PROJECT_ID}" --quiet
                log "Node ${instance} deleted."
            else
                log "Keeping worker node: ${instance} (Index ${suffix} < ${WORKER_COUNT})"
            fi
        fi
    done
}
