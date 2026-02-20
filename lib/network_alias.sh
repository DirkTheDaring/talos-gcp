#!/bin/bash

# Network Alias Management
# Handles resolving native routing collisions and fixing alias mappings.

fix_aliases() {
    log "Synchronizing GCP Alias IPs with Kubernetes PodCIDRs..."
    
    # Check if native routing is enabled
    if [ "${CILIUM_ROUTING_MODE:-}" != "native" ]; then
        log "Native routing not enabled (CILIUM_ROUTING_MODE=${CILIUM_ROUTING_MODE:-}). Skipping Alias IP sync."
        return 0
    fi

    # 3. Fetch K8s Data (Desired State) via Bastion
    log "Fetching Node Data via Bastion..."
    
    # Wait for API Server Readiness (max 2m)
    log "Waiting for API Server to be reachable via Bastion..."

    # Check if default (VIP) is working, if not try Node IP fallback
    local kv_server=""
    if ! run_on_bastion "kubectl get --raw='/healthz' --request-timeout=5s" >/dev/null 2>&1; then
        local cp0_ip
        cp0_ip=$(gcloud compute instances describe "${CLUSTER_NAME}-cp-0" --zone "${ZONE}" --format="value(networkInterfaces[0].networkIP)" --project="${PROJECT_ID}" 2>/dev/null || echo "")
        
        if [ -n "$cp0_ip" ]; then
             log "API Server (VIP) not ready. Checking Direct Node IP (${cp0_ip})..."
             # Check if Node IP works (with insecure skip verify as cert holds VIP/SANs)
             if run_on_bastion "kubectl --server=https://${cp0_ip}:6443 --insecure-skip-tls-verify=true get --raw='/healthz' --request-timeout=5s" >/dev/null 2>&1; then
                 kv_server="--server=https://${cp0_ip}:6443 --insecure-skip-tls-verify=true"
                 log "Using Direct Node IP for fix_aliases commands."
             fi
        fi
    fi
    
    local ready=false
    for i in {1..24}; do
        if run_on_bastion "kubectl ${kv_server} get --raw='/healthz' --request-timeout=5s" &>/dev/null; then
            ready=true
            break
        fi
        sleep 5
    done
    
    if [ "$ready" != "true" ]; then
        warn "API Server not reachable after 2m. skipping alias fix for now."
        return 1
    fi

    local k8s_output
    # Use --request-timeout to fail fast if API is unresponsive
    if ! k8s_output=$(run_on_bastion "kubectl ${kv_server} get nodes -o jsonpath='{range .items[*]}{.metadata.name} {.spec.podCIDR}{\"\\n\"}{end}' --request-timeout=10s"); then
        warn "Failed to fetch Kubernetes node data via Bastion. Skipping."
        return 1
    fi

    # 2. Fetch GCP Data (Current State) - Bulk Fetch
    log "Fetching current GCP Alias IPs..."
    local gcp_output
    if ! gcp_output=$(gcloud compute instances list --filter="name:(${CLUSTER_NAME}-*) AND zone:(${ZONE}) AND networkInterfaces.network:(${VPC_NAME})" --format="value(name,networkInterfaces[0].aliasIpRanges[0].ipCidrRange)" --project="${PROJECT_ID}" 2>/dev/null); then
        warn "Failed to fetch instance data from GCP. Skipping."
        return 1
    fi

    # 3. Parse into Associative Arrays (Bash 4+)
    declare -A k8s_cidrs
    declare -A gcp_aliases
    
    # Parse K8s Data
    while read -r name cidr; do
        if [ -n "$name" ]; then k8s_cidrs["$name"]="$cidr"; fi
    done <<< "$k8s_output"

    # Parse GCP Data
    while read -r name alias_ip; do
        if [ -n "$name" ]; then gcp_aliases["$name"]="$alias_ip"; fi
    done <<< "$gcp_output"

    local changes_made=0

    # --- Phase 1: Clear Mismatches (Solve Conflicts) ---
    # We loop through GCP nodes that we found
    for node in "${!gcp_aliases[@]}"; do
        local current="${gcp_aliases[$node]}"
        local target="${k8s_cidrs[$node]:-}" # Might be empty if not in K8s list or no PodCIDR
        
        # SAFETY CHECK: If K8s target is empty, do NOT clear the alias.
        # This prevents race conditions where KCM hasn't assigned CIDRs yet.
        if [ -z "$target" ] && [ -n "$current" ]; then
             warn "Node $node has GCP Alias '$current' but K8s reports no PodCIDR. Preserving GCP Alias."
             continue
        fi

        # If we have a current alias, but it doesn't match the target
        if [ -n "$current" ] && [ "$current" != "$target" ]; then
             log "Mismatch for $node: Current='$current', Target='${target:-none}'. Clearing..."
             run_safe gcloud compute instances network-interfaces update "$node" --zone "$ZONE" --project="$PROJECT_ID" --aliases ""
             gcp_aliases["$node"]="" # Update local state
             ((changes_made++))
        fi
    done

    local -a nodes_to_reboot=()
    
    # --- Phase 2: Set Correct Aliases ---
    for node in "${!k8s_cidrs[@]}"; do
        local target="${k8s_cidrs[$node]}"
        local current="${gcp_aliases[$node]:-}"
        
        # Only proceed if we have a valid target CIDR
        if [ -n "$target" ] && [ "$target" != "<none>" ]; then
            if [ "$current" != "$target" ]; then
                log "Refining Alias IP for $node: Current='$current', Target='$target'..."
                
                # SAFE REPAIR STRATEGY:
                # Updating the alias on a running Talos node breaks the DHCP lease/connectivity.
                # We collect nodes to reboot and handle them in batch.
                
                # 1. Update Alias
                run_safe gcloud compute instances network-interfaces update "$node" --zone "$ZONE" --project="$PROJECT_ID" --aliases "pods:${target}"
                
                nodes_to_reboot+=("$node")
                ((changes_made++))
            fi
        fi
    done
    
    # --- Phase 3: Batch Reboot and Wait ---
    if [ ${#nodes_to_reboot[@]} -gt 0 ]; then
        local node_list="${nodes_to_reboot[*]}"
        warn "⚠️  Safe Repair Triggered for: ${node_list}"
        warn "   Broadcasting REBOOT to restore connectivity..."
        
        # 1. Batch Reboot
        run_safe gcloud compute instances reset ${node_list} --zone "$ZONE" --project="$PROJECT_ID" --quiet
        
        # 2. Resolve IPs LOCALLY (Bastion does not have gcloud)
        log "Resolving IPs for recovery check..."
        local -a target_ips=()
        for node in "${nodes_to_reboot[@]}"; do
            local ip
            if ip=$(gcloud compute instances describe "$node" --zone "$ZONE" --format="value(networkInterfaces[0].networkIP)" --project="$PROJECT_ID"); then
                target_ips+=("$ip")
            else
                warn "Could not resolve IP for $node. It will be skipped in recovery check."
            fi
        done
        
        if [ ${#target_ips[@]} -eq 0 ]; then
            warn "No IPs resolved. Skipping recovery check."
        else
            # 3. Wait for Recovery (5 Minutes)
            log "Waiting for nodes to recover (Timeout: 5m)..."
            local ip_string="${target_ips[*]}"
            
            # Construct a check loop for ALL nodes
            # We pass the IPs as a string to the bastion script.
            local check_script="
                ips=\"${ip_string}\"
                # Split space-separated string into array
                IFS=' ' read -r -a ip_array <<< \"\${ips}\"
                
                timeout=300 # 5 minutes
                start_time=\$(date +%s)
                
                echo \"Checking recovery for IPs: \${ips}\"
                
                while true; do
                    current_time=\$(date +%s)
                    elapsed=\$((current_time - start_time))
                    
                    if [ \$elapsed -ge \$timeout ]; then
                        echo 'ERROR: Timeout waiting for nodes to recover.'
                        exit 1
                    fi
                    
                    all_up=true
                    for ip in \"\${ip_array[@]}\"; do
                        if ! ping -c 1 -W 1 \"\$ip\" >/dev/null 2>&1; then
                            all_up=false
                            # Check next IP
                        fi
                    done
                    
                    if [ \"\$all_up\" = true ]; then
                        echo 'All nodes recovered successfully.'
                        exit 0
                    fi
                    
                    echo \"Waiting for nodes... (\$elapsed/\${timeout}s)\"
                    sleep 5
                done
            "
            
            if ! run_on_bastion "$check_script"; then
                error "One or more nodes failed to recover after 5 minutes. Aborting deployment."
                return 1
            fi
        fi
    fi
    
    if [ $changes_made -eq 0 ]; then
        log "All Alias IPs are correct. No changes made."
    else
        log "Alias IP synchronization complete ($changes_made updates with reboots)."
        # Force a short sleep to allow api-server/etcd to stabilize
        sleep 10
    fi
}

reset_aliases() {
    log "RESETTING GCP Alias IPs for all cluster nodes..."
    
    # Check if native routing is enabled
    if [ "${CILIUM_ROUTING_MODE:-}" != "native" ]; then
        warn "Native routing not enabled (CILIUM_ROUTING_MODE=${CILIUM_ROUTING_MODE:-}). Resetting aliases is not applicable."
        return 0
    fi
    
    warn "This will remove ALL Alias IPs from nodes. Pod connectivity will be interrupted until 'fix-aliases' is run."
    
    echo -n "Are you sure you want to proceed? [y/N] "
    read -r response
    if [[ ! "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        log "Reset aborted."
        return 0
    fi
    
    log "Pruning all Alias IPs..."
    
    # Bulk Fetch
    local gcp_output
    if ! gcp_output=$(gcloud compute instances list --filter="name:(${CLUSTER_NAME}-*) AND zone:(${ZONE}) AND networkInterfaces.network:(${VPC_NAME})" --format="value(name,networkInterfaces[0].aliasIpRanges[0].ipCidrRange)" --project="${PROJECT_ID}" 2>/dev/null); then
        warn "Failed to fetch instance data from GCP."
        return 1
    fi
    
    local count=0
    # Loop and Clear
    while read -r name alias_ip; do
        if [ -n "$name" ] && [ -n "$alias_ip" ]; then
             log "Clearing Alias IP for $name (was $alias_ip)..."
             run_safe gcloud compute instances network-interfaces update "$name" --zone "$ZONE" --project="${PROJECT_ID}" --aliases ""
             ((count++))
        fi
    done <<< "$gcp_output"
    
    if [ $count -gt 0 ]; then
        log "Reset complete. Pruned aliases from $count nodes."
    else
        log "No aliases found to prune."
    fi
}

# Smart Collision Resolution
resolve_collisions() {
    log "Checking for GCP Alias IP collisions..."

    # Check if native routing is enabled
    if [ "${CILIUM_ROUTING_MODE:-}" != "native" ]; then
        log "Native routing not enabled (CILIUM_ROUTING_MODE=${CILIUM_ROUTING_MODE:-}). Skipping collision check."
        return 0
    fi
    
    # 1. Fetch Name and Alias for ALL nodes in zone + VPC (to catch cross-cluster or stale collisions)
    local gcp_output
    if ! gcp_output=$(gcloud compute instances list --filter="zone:(${ZONE}) AND networkInterfaces.network:(${VPC_NAME})" --format="value(name,networkInterfaces[0].aliasIpRanges[0].ipCidrRange)" --project="${PROJECT_ID}" 2>/dev/null); then
        warn "Failed to fetch instance data. Skipping collision check."
        return 0
    fi

    # 2. Map Alias -> Nodes (Bash 4+ Associative Array)
    declare -A ip_map
    local collision_found=false
    
    while read -r name alias_ip; do
        if [ -n "$alias_ip" ]; then
             # Check if we saw this alias before
             if [ -n "${ip_map[$alias_ip]:-}" ]; then
                 local conflicting_node="${ip_map[$alias_ip]}"
                 warn "COLLISION DETECTED: Alias $alias_ip is used by both '$conflicting_node' and '$name'!"
                 
                 # Resolve: Clear BOTH to allow K8s to re-assign correctly on next sync
                 log "Resolving collision: Clearing alias from BOTH nodes..."
                 run_safe gcloud compute instances network-interfaces update "$conflicting_node" --zone "$ZONE" --project="${PROJECT_ID}" --aliases ""
                 run_safe gcloud compute instances network-interfaces update "$name" --zone "$ZONE" --project="${PROJECT_ID}" --aliases ""
                 
                 collision_found=true
             else
                 ip_map["$alias_ip"]="$name"
             fi
        fi
    done <<< "$gcp_output"
    
    if [ "$collision_found" = true ]; then
        log "Collisions resolved. You may need to run 'fix-aliases' to restore connectivity."
    else
        log "No alias collisions found."
    fi
}
