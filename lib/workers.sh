#!/bin/bash


# Generic Node Pool Provisioning
provision_node_pools() {
    log "Phase 10: Provisioning Node Pools..."

    for pool in "${NODE_POOLS[@]}"; do
        provision_pool "${pool}"
    done
}

provision_pool() {
    local pool_name="$1"
    log "Provisioning Node Pool: ${pool_name}..."

    # 1. Resolve Pool Configuration (Dynamic Variables)
    # Sanitize pool name for variable lookup (replace - with _)
    local safe_pool_name="${pool_name//-/_}"
    local pool_count_var="POOL_${safe_pool_name^^}_COUNT"
    local pool_type_var="POOL_${safe_pool_name^^}_TYPE"
    local pool_size_var="POOL_${safe_pool_name^^}_DISK_SIZE"
    local pool_image_var="POOL_${safe_pool_name^^}_IMAGE"
    local pool_labels_var="POOL_${safe_pool_name^^}_LABELS"
    local pool_taints_var="POOL_${safe_pool_name^^}_TAINTS"
    local pool_ext_var="POOL_${safe_pool_name^^}_EXTENSIONS"
    local pool_disks_var="POOL_${safe_pool_name^^}_ADDITIONAL_DISKS"
    local pool_storage_net_var="POOL_${safe_pool_name^^}_USE_STORAGE_NET"

    local pool_vcpu_var="POOL_${safe_pool_name^^}_VCPU"
    local pool_mem_var="POOL_${safe_pool_name^^}_MEMORY_GB"
    local pool_family_var="POOL_${safe_pool_name^^}_FAMILY"

    local count="${!pool_count_var:-0}"
    local machine_type="${!pool_type_var:-e2-medium}" 
    local disk_size="${!pool_size_var:-200GB}"
    local install_image="${!pool_image_var:-}"
    local labels="${!pool_labels_var:-}"
    local taints="${!pool_taints_var:-}"
    local extensions="${!pool_ext_var:-$POOL_EXTENSIONS}"
    local additional_disks="${!pool_disks_var:-}"
    local use_storage_net="${!pool_storage_net_var:-false}"
    
    local pool_kargs_var="POOL_${safe_pool_name^^}_KERNEL_ARGS"
    local kernel_args="${!pool_kargs_var:-$POOL_KERNEL_ARGS}"

    local pool_nv_var="POOL_${safe_pool_name^^}_ALLOW_NESTED_VIRT"
    local nested_virt="${!pool_nv_var:-false}"

    # Handle Custom Machine Types for Pools
    if [ "${machine_type}" == "custom" ]; then
        local vcpu="${!pool_vcpu_var:-}"
        local mem_gb="${!pool_mem_var:-}"
        local family="${!pool_family_var:-n2}" # Default family for pools
        
        if [ -n "$vcpu" ] && [ -n "$mem_gb" ]; then
             if ! [[ "$vcpu" =~ ^[0-9]+$ ]] || ! [[ "$mem_gb" =~ ^[0-9]+$ ]]; then
                error "Pool '${pool_name}': VCPU and MEMORY_GB must be integers for custom type."
                exit 1
             fi
             local mem_mb=$((mem_gb * 1024))
             machine_type="${family}-custom-${vcpu}-${mem_mb}"
             log "  > Pool '${pool_name}' using custom type: ${machine_type}"
        else
             error "Pool '${pool_name}' set to 'custom' but VCPU or MEMORY_GB is missing."
             exit 1
        fi
    fi

    # Validation: Nested Virtualization requires non-E2 machine types
    if [ "${nested_virt}" == "true" ]; then
        if [[ "${machine_type}" == "e2-"* ]]; then
            error "Pool '${pool_name}': Nested Virtualization is NOT supported on E2 machine types."
            error "Please use N1, N2, N2D, or C2 machine types."
            exit 1
        fi
        log "  > Pool '${pool_name}': Nested Virtualization ENABLED."
    fi

    log "  > Pool '${pool_name}': Count=${count}, Type=${machine_type}, StorageNet=${use_storage_net}"

    if [ "$count" -eq 0 ]; then
        log "  > Skipping empty pool '${pool_name}'."
        return
    fi

    # 2. Instance Group (Per Pool)
    # Naming convention: {CLUSTER_NAME}-ig-{pool_name}
    local ig_name="${CLUSTER_NAME}-ig-${pool_name}"
    
    if ! gcloud compute instance-groups unmanaged describe "${ig_name}" --zone "${ZONE}" --project="${PROJECT_ID}" &> /dev/null; then
        run_safe gcloud compute instance-groups unmanaged create "${ig_name}" --zone "${ZONE}" --project="${PROJECT_ID}"
    fi

    # 3. Generate Pool-Specific Config (worker-${pool}.yaml)
    # We generate a specific config for this pool to inject Labels and Taints at boot time.
    # This avoids the race condition where nodes join before taints are applied.
    local pool_config="${OUTPUT_DIR}/worker-${pool_name}.yaml"
    
    # We use the generic 'worker.yaml' as base.
    if [ ! -f "${OUTPUT_DIR}/worker.yaml" ]; then
        warn "Base 'worker.yaml' not found. Skipping pool config generation (dependent on Phase 5)."
        pool_config="${OUTPUT_DIR}/worker.yaml" # Fallback
    else
        log "Generating config for pool '${pool_name}' with Labels='${labels}' Taints='${taints}' StorageNet='${use_storage_net}'..."
        # Pass Extensions, Kernel Args, and Ports
        # Use existing variables: extensions, kernel_args
        # Use global variables: WORKER_OPEN_TCP_PORTS, WORKER_OPEN_UDP_PORTS
        
        # Use inline generation to avoid external script dependency
        generate_pool_config_inline \
            "${OUTPUT_DIR}/worker.yaml" \
            "${pool_config}" \
            "${labels}" \
            "${taints}" \
            "${use_storage_net}" \
            "${extensions}" \
            "${kernel_args}" \
            "${WORKER_OPEN_TCP_PORTS:-}" \
            "${WORKER_OPEN_UDP_PORTS:-}"
            
        validate_talos_config "${pool_config}" "machine"
    fi



    # 4. Resolve Image Name for this Pool
    # We need to replicate the hashing logic from lib/images.sh to know which image to usage.
    # Alternatively, we could export a map, but bash maps are tricky across subshells.
    # Re-implementing the safe suffix logic here is robust.
    
    local image_to_use=""
    if [ -n "${install_image}" ]; then
        image_to_use="${install_image}"
    else
        # Default logic
        local safe_ver="${WORKER_TALOS_VERSION//./-}" # sanitize_version
        safe_ver=$(echo "${safe_ver}" | tr '[:upper:]' '[:lower:]')
        
        local suffix="gcp-${ARCH}"
        if [ -n "${extensions}" ] || [ -n "${kernel_args}" ]; then
             local normalized_ext
             normalized_ext=$(echo "${extensions}" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | sort | tr '\n' ',' | sed 's/,$//')
             
             local normalized_kargs
             normalized_kargs=$(echo "${kernel_args}" | tr ' ' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | sort | tr '\n' ',' | sed 's/,$//')
     
             local ext_hash
             ext_hash=$(echo "${normalized_ext}|${normalized_kargs}" | md5sum | cut -c1-8)
             suffix="worker-${ext_hash}-${ARCH}"
        fi

        # Append 'nv' suffix for Nested Virtualization
        if [ "${nested_virt}" == "true" ]; then
            suffix="${suffix}-nv"
        fi

        image_to_use="talos-${safe_ver}-${suffix}"
    fi

    # 5. Create Instances
    for ((i=0; i<count; i++)); do
        local instance_name="${CLUSTER_NAME}-${pool_name}-${i}"
        
        create_node_instance \
            "${instance_name}" \
            "${machine_type}" \
            "${disk_size}" \
            "${ig_name}" \
            "${use_storage_net}" \
            "${additional_disks}" \
            "${labels}" \
            "${taints}" \
            "${pool_config}" \
            "${image_to_use}"
    done
    
    # 5. Verify Serial Console Logs
    log "Verifying serial console logs for pool '${pool_name}'..."
    for ((i=0; i<count; i++)); do
        local instance_name="${CLUSTER_NAME}-${pool_name}-${i}"
        verify_node_log "${instance_name}" "${ZONE}" || {
             warn "Verification failed for ${instance_name}. Proceeding anyway..."
             # exit 1
        }
    done

    # 5. Prune Pool
    prune_pool "${pool_name}" "${count}" "${ig_name}"
    
    # 6. Attach to Ingress Backend Services (Only for 'worker' pool for now?)
    # If we want generic Ingress, we might need a "POOL_EXPOSE_INGRESS" flag.
    # For backward compatibility, strictly 'worker' pool is attached to existing BEs.
    if [ "$pool_name" == "worker" ]; then
         attach_worker_ig_to_bes "${ig_name}"
    fi
}

create_node_instance() {
    local instance_name="$1"
    local machine_type="$2"
    local disk_size="$3"
    local ig_name="$4"
    local use_storage_net="$5"
    local additional_disks="$6"
    local labels="$7"
    local taints="$8" # Currently unused in gcloud create (for labels), but used in config generation.
    local custom_config="${9:-}" # Optional custom config file path
    local image_arg="${10:-}"

    # Image Resolution (if not explicitly passed)
    local target_image="${image_arg}"
    
    if [ -z "$target_image" ]; then
        # We try to fall back to WORKER_IMAGE_NAME
        target_image="${WORKER_IMAGE_NAME}"
    fi

    # Build Disk Flags
    local -a DISK_FLAGS
    if [ -n "${additional_disks:-}" ]; then
        local disk_index=0
        for disk_def in ${additional_disks}; do
            IFS=':' read -r dtype dsize dname <<< "${disk_def}"
            
            # Validation
            if [[ -z "$dtype" || -z "$dsize" ]]; then
                error "Invalid Disk Definition in pool: '${disk_def}'. Format: type:size[:device-name]"
                exit 1
            fi

            [ -z "${dname}" ] && dname="disk-${disk_index}"
            local gcp_disk_name="${instance_name}-disk-${disk_index}"
            DISK_FLAGS+=("--create-disk=name=${gcp_disk_name},size=${dsize},type=${dtype},device-name=${dname},mode=rw,auto-delete=yes")
            ((++disk_index))
        done
        log "For ${instance_name}: Adding ${#DISK_FLAGS[@]} additional disks."
    fi

    # Network Flags
    local ALIAS_FLAG=""
    if [ "${CILIUM_ROUTING_MODE:-}" == "native" ]; then
        ALIAS_FLAG=",aliases=pods:/24"
    fi

    local -a NETWORK_FLAGS
    # NIC0: Primary
    NETWORK_FLAGS=("--network-interface" "network=${VPC_NAME},subnet=${SUBNET_NAME},no-address${ALIAS_FLAG}")
    
    # NIC1: Storage (Conditional)
    if [ -n "${STORAGE_CIDR:-}" ] && [ "${use_storage_net}" == "true" ]; then
         NETWORK_FLAGS+=("--network-interface" "network=${VPC_STORAGE_NAME},subnet=${SUBNET_STORAGE_NAME},no-address")
    fi

    # Check Existence & Drift
    if gcloud compute instances list --zones "${ZONE}" --format="value(name)" --project="${PROJECT_ID}" | grep -q "^${instance_name}$"; then
         # Check Machine Type Drift
         local current_mt
         current_mt=$(gcloud compute instances describe "${instance_name}" --zone "${ZONE}" --project="${PROJECT_ID}" --format="value(machineType)" 2>/dev/null)
         current_mt="${current_mt##*/}"
         
         if [ "$current_mt" != "${machine_type}" ]; then
             warn "Node ${instance_name} exists but has type '${current_mt}' (Expected: '${machine_type}')."
             warn "Manual recreation required to apply machine type change."
         else
             log "Node ${instance_name} exists and matches Machine Type."
             
             # Check Alias IP Drift (If Native Routing)
             if [ "${CILIUM_ROUTING_MODE:-}" == "native" ]; then
                 local current_aliases
                 current_aliases=$(gcloud compute instances describe "${instance_name}" --zone "${ZONE}" --project="${PROJECT_ID}" --format="value(networkInterfaces[0].aliasIpRanges[0].ipCidrRange)" 2>/dev/null || true)
                 
                 if [ -z "$current_aliases" ]; then
                     warn "Node ${instance_name} exists but is missing Alias IP (Required for Native Routing)."
                      warn "This detection indicates drift. Run fix-aliases to synchronize."
                      # Auto-repair disabled
                 else
                     log "Node ${instance_name} has Alias IP: ${current_aliases}"
                 fi
             fi
             
             ensure_instance_in_ig "${instance_name}" "${ig_name}"
         fi
    else
         log "Creating node instance (${instance_name})..."
         
         # Construct GCP Labels
         # Add generic cluster tags + user provided pool labels (if formatted correctly for GCP)
         # For simplicity, we just add the standard set + list labels in description or metadata?
         # GCP Labels must be key=val, lowercase.
         local gcp_labels="cluster=${CLUSTER_NAME},talos-version=${WORKER_TALOS_VERSION//./-},k8s-version=${KUBECTL_VERSION//./-},cilium-version=${CILIUM_VERSION//./-}"
         
         # Convert env labels (role=storage) to GCP labels (role=storage) if compatible
         if [ -n "$labels" ]; then
             # Simple sanitization or direct append if trusted
             gcp_labels="${gcp_labels},${labels// /_}" 
         fi

         run_safe retry gcloud compute instances create "${instance_name}" \
            --image "${target_image}" --zone "${ZONE}" --project="${PROJECT_ID}" \
            --machine-type="${machine_type}" --boot-disk-size="${disk_size}" \
            "${NETWORK_FLAGS[@]}" \
            --service-account="${WORKER_SERVICE_ACCOUNT}" --scopes cloud-platform \
            --tags "talos-worker,${CLUSTER_NAME}-worker,${instance_name}" \
            --labels="${gcp_labels}" \
            --metadata=talos-image="${target_image}" \
            --metadata-from-file=user-data="${custom_config:-${OUTPUT_DIR}/worker.yaml}" \
            "${DISK_FLAGS[@]}"
            
         ensure_instance_in_ig "${instance_name}" "${ig_name}"
    fi
}

prune_pool() {
    local pool_name="$1"
    local target_count="$2"
    local ig_name="$3"
    
    local prefix="${CLUSTER_NAME}-${pool_name}-"
    
    log "Pruning pool '${pool_name}' (Target: ${target_count})..."
    local existing
    existing=$(gcloud compute instances list --filter="name~'${prefix}.*' AND zone:(${ZONE})" --format="value(name)" --project="${PROJECT_ID}")

    for instance in $existing; do
        local suffix="${instance#$prefix}"
        if [[ "$suffix" =~ ^[0-9]+$ ]]; then
            if (( suffix >= target_count )); then
                if [ "${CONFIRM_CHANGES:-true}" == "true" ]; then
                    read -p "Delete extra node ${instance}? [y/N] " -r
                    if [[ ! $REPLY =~ ^[Yy]$ ]]; then continue; fi
                fi
                
                # Remove from IG & Delete
                run_safe gcloud compute instance-groups unmanaged remove-instances "${ig_name}" --instances="${instance}" --zone "${ZONE}" --project="${PROJECT_ID}" || true
                run_safe gcloud compute instances delete "${instance}" --zone "${ZONE}" --project="${PROJECT_ID}" --quiet
                log "Deleted ${instance}."
            fi
        fi
    done
}


attach_worker_ig_to_bes() {
    local ig_name="$1"
    log "Attaching ${ig_name} to Ingress Backend Services..."
    
    # TCP Backend
    if ! gcloud compute backend-services describe "${BE_WORKER_NAME}" --region "${REGION}" --project="${PROJECT_ID}" | grep -q "group: .*${ig_name}"; then
         run_safe gcloud compute backend-services add-backend "${BE_WORKER_NAME}" --region "${REGION}" --instance-group "${ig_name}" --instance-group-zone "${ZONE}" --project="${PROJECT_ID}"
    fi
     # UDP Backend
    if ! gcloud compute backend-services describe "${BE_WORKER_UDP_NAME}" --region "${REGION}" --project="${PROJECT_ID}" | grep -q "group: .*${ig_name}"; then
         run_safe gcloud compute backend-services add-backend "${BE_WORKER_UDP_NAME}" --region "${REGION}" --instance-group "${ig_name}" --instance-group-zone "${ZONE}" --project="${PROJECT_ID}"
    fi
}


apply_node_pool_labels() {
    log "Applying Node Pool Labels & Taints..."
    export KUBECONFIG="${OUTPUT_DIR}/kubeconfig"
    
    local KUBECTL_CMD="kubectl"
    local EXEC_MODE="local"
    
    # 1. Determine Execution Mode (Local vs Bastion)
    if [ -n "${BASTION_NAME:-}" ] && gcloud compute instances describe "${BASTION_NAME}" --zone "${ZONE}" --project="${PROJECT_ID}" --format="value(status)" 2>/dev/null | grep -q "RUNNING"; then
        log "Bastion '${BASTION_NAME}' is running. Switching to Bastion execution for kubectl..."
        EXEC_MODE="bastion"
        
        # Upload config to ensure we have the right credentials
        log "Uploading kubeconfig to Bastion..."
        if ! gcloud compute scp "${OUTPUT_DIR}/kubeconfig" "${BASTION_NAME}:~/kubeconfig.pool" --zone "${ZONE}" --project="${PROJECT_ID}" --tunnel-through-iap --quiet; then
            error "Failed to upload kubeconfig to bastion."
            return 1
        fi
        
        KUBECTL_CMD="kubectl --kubeconfig ~/kubeconfig.pool"
    else
        # Fallback to local
        log "Bastion not available or not configured. Using local kubectl..."
        if ! timeout 5s kubectl get nodes &>/dev/null; then
             warn "Local kubectl unreachable (and no Bastion available). Node labeling might fail."
        fi
    fi

    for pool in "${NODE_POOLS[@]}"; do
        local pool_name="${pool}"
        local safe_pool_name="${pool_name//-/_}"
        
        local pool_labels_var="POOL_${safe_pool_name^^}_LABELS"
        local pool_taints_var="POOL_${safe_pool_name^^}_TAINTS"
        local labels="${!pool_labels_var:-}"
        local taints="${!pool_taints_var:-}"
        
        if [ -z "$labels" ] && [ -z "$taints" ]; then continue; fi
        
        log "  > Pool '${pool}': Applying Labels='${labels}', Taints='${taints}'"
        
        # Get Nodes (Wait for them to join)
        local nodes=""
        local grep_pattern="${CLUSTER_NAME}-${pool}-[0-9]+$"
        local max_attempts=30 # 5 minutes (30 * 10s)
        local attempt=1
        
        while [ $attempt -le $max_attempts ]; do
            if [ "$EXEC_MODE" == "local" ]; then
                nodes=$(kubectl get nodes -o name 2>/dev/null | grep -E "$grep_pattern" || true)
            else
                # Run via Bastion
                local remote_output
                remote_output=$(run_on_bastion "${KUBECTL_CMD} get nodes -o name" || echo "")
                nodes=$(echo "$remote_output" | grep -E "$grep_pattern" || true)
            fi
            
            if [ -n "$nodes" ]; then
                break
            fi
            
            log "    Waiting for nodes in pool '${pool}' to register... ($attempt/$max_attempts)"
            sleep 10
            ((attempt++))
        done
        
        if [ -z "$nodes" ]; then
             error "    Timeout waiting for nodes in pool '${pool}' to join. Halting deployment."
             return 1
        fi
        
        for node in $nodes; do
            node=${node#node/} # remove prefix
            
            # Prepare commands
            local clean_labels="${labels//,/ }"
            local clean_taints="${taints//,/ }"
            
            if [ -n "$labels" ]; then
                if [ "$EXEC_MODE" == "local" ]; then
                    run_safe kubectl label node "${node}" ${clean_labels} --overwrite
                else
                    run_on_bastion "${KUBECTL_CMD} label node ${node} ${clean_labels} --overwrite"
                fi
            fi
            
            if [ -n "$taints" ]; then
                if [ "$EXEC_MODE" == "local" ]; then
                    run_safe kubectl taint nodes "${node}" ${clean_taints} --overwrite
                else
                    run_on_bastion "${KUBECTL_CMD} taint nodes ${node} ${clean_taints} --overwrite"
                fi
            fi
        done
    done
}

# Alias for backward compatibility if called directly
provision_workers() {
    provision_node_pools
}
