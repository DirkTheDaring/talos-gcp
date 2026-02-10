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
    # Workaround: gcloud filter hangs.
    if ! gcloud compute instances list --zones "${ZONE}" --format="value(name)" --project="${PROJECT_ID}" | grep -q "^${worker_name}$"; then
         log "Creating worker node (${worker_name})..."
         run_safe retry gcloud compute instances create "${worker_name}" \
            --image "${TALOS_IMAGE_NAME}" --zone "${ZONE}" --project="${PROJECT_ID}" \
            --machine-type="${WORKER_MACHINE_TYPE}" --boot-disk-size="${WORKER_DISK_SIZE}" \
            --network="${VPC_NAME}" --subnet="${SUBNET_NAME}" \
            --no-address --service-account="${SA_EMAIL}" --scopes cloud-platform \
            --tags "talos-worker,${worker_name}" \
            --labels="${LABELS:+${LABELS},}cluster=${CLUSTER_NAME},talos-version=${TALOS_VERSION//./-},k8s-version=${KUBECTL_VERSION//./-},cilium-version=${CILIUM_VERSION//./-}" \
            --metadata-from-file=user-data="${OUTPUT_DIR}/worker.yaml"
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
                log "Pruning extra worker node: ${instance} (Index ${suffix} >= ${WORKER_COUNT})..."
                
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
