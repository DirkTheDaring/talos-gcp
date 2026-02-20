#!/bin/bash
# lib/peering.sh - Multi-Cluster Peering & Firewall Management
#
# Usage:
#   source lib/peering.sh
#   reconcile_peering
#
# This script manages VPC Peering and Firewall Rules between clusters.
# It acts as a reconciler:
# 1. READS desired peers from PEER_WITH=("peer1" "peer2") in the current environment.
# 2. CREATES missing peerings.
# 3. DELETES peerings that are active but NOT in PEER_WITH (if managed by this tool).
# 4. ENFORCES strict firewall rules (Ceph Ports: 6789, 3300, 6800-7300).

# Ensure logging functions are available (if running standalone)
if ! command -v log &>/dev/null; then
    # shellcheck source=lib/utils.sh
    source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
    # shellcheck source=lib/config.sh
    source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
fi

# -----------------------------------------------------------------------------
# Core Functions
# -----------------------------------------------------------------------------

# Main Reconciler Function
reconcile_peering() {
    local peers=("${PEER_WITH[@]}")
    
    # If no peers defined, ensure cleanup of managed peerings
    if [ ${#peers[@]} -eq 0 ]; then
        log "No PEER_WITH defined. Checking for stale peerings to remove..."
        remove_stale_peerings
        return 0
    fi

    log "Reconciling Peering Connections for: ${CLUSTER_NAME} -> [${peers[*]}]..."

    for peer in "${peers[@]}"; do
        peer_connect "${peer}"
    done
    
    # After creating desired, check for stale
    remove_stale_peerings
}

# Helper to retry peering creation on "operation in progress"
retry_peering_create() {
    local max_retries=10
    local wait_sec=15
    local count=0

    while [ $count -lt $max_retries ]; do
        if "$@"; then
            return 0
        else
            local exit_code=$?
            # We can't easily capture output here without complicating the "run_safe" pattern.
            # But the error handling logic in the calling script might have already printed it.
            # Actually, let's just retry blindly on failure if it's likely a race condition.
            # A better approach is to capture output.
             warn "  - Peering creation failed. Retrying in ${wait_sec}s (Attempt $((count+1))/${max_retries})..."
             sleep $wait_sec
             count=$((count + 1))
        fi
    done
    
    error "Failed to create peering after ${max_retries} attempts."
    return 1
}

# Connects current cluster and remote cluster via VPC Peering
# Arguments:
#   $1: remote_cluster_name
peer_connect() {
    local remote_cluster="$1"
    local local_vpc="${CLUSTER_NAME}-vpc"
    local remote_vpc="${remote_cluster}-vpc"
    local peering_name="peer-${CLUSTER_NAME}-to-${remote_cluster}"
    local reverse_peering_name="peer-${remote_cluster}-to-${CLUSTER_NAME}"

    # Check if Remote VPC exists (Break Circular Dependency)
    if ! gcloud compute networks describe "${remote_vpc}" --project="${PROJECT_ID}" &>/dev/null; then
        warn "Remote VPC '${remote_vpc}' not found. Skipping peering (will be established when remote cluster acts)..."
        return 0
    fi

    log "Checking peering: ${local_vpc} <-> ${remote_vpc}..."

    # Check existence
    if gcloud compute networks peerings list --network="${local_vpc}" --project="${PROJECT_ID}" --format="value(name)" | grep -q "^${peering_name}$"; then
        log "  - Peering '${peering_name}' already exists. Verifying state..."
        local state
        state=$(gcloud compute networks peerings list --network="${local_vpc}" --project="${PROJECT_ID}" --filter="name=${peering_name}" --format="value(state)")
        if [ "$state" == "ACTIVE" ]; then
             log "  - Peering is ACTIVE."
        else
             warn "  - Peering exists but state is ${state}. Check remote side."
        fi
    else
        log "  - Creating peering '${peering_name}'..."
        retry_peering_create gcloud compute networks peerings create "${peering_name}" \
            --network="${local_vpc}" \
            --peer-network="${remote_vpc}" \
            --project="${PROJECT_ID}" \
            --auto-create-routes \
            --quiet
    fi

    # Create Reverse Peering (Required for ACTIVE state)
    # We must check if we have permission/access to the remote VPC in this project
    # Assuming same project for now.
    if gcloud compute networks peerings list --network="${remote_vpc}" --project="${PROJECT_ID}" --format="value(name)" | grep -q "^${reverse_peering_name}$"; then
        log "  - Reverse peering '${reverse_peering_name}' already exists."
    else
        log "  - Creating reverse peering '${reverse_peering_name}'..."
        retry_peering_create gcloud compute networks peerings create "${reverse_peering_name}" \
            --network="${remote_vpc}" \
            --peer-network="${local_vpc}" \
            --project="${PROJECT_ID}" \
            --auto-create-routes \
            --quiet
    fi

    # Update Firewalls
    # NEW: We now configure the firewall on the REMOTE VPC as well (Client-Side Logic)
    # This allows "clients come and go" without updating the server's config.
    configure_remote_firewall "${remote_cluster}"
}

# Configures Ingress Firewall on the Remote Cluster's VPC to allow traffic from THIS cluster
# Arguments:
#   $1: remote_cluster_name
configure_remote_firewall() {
    local remote_cluster="$1"
    local local_vpc="${CLUSTER_NAME}-vpc"
    local remote_vpc="${remote_cluster}-vpc"
    
    # We need to allow traffic FROM our local subnets TO the remote VPC.
    # The rule must be created in the REMOTE project (assuming same project for now).
    
    local fw_rule_name="allow-${remote_cluster}-from-${CLUSTER_NAME}-custom"
    
    # Determine Local CIDRs to allow
    # We should include SUBNET_RANGE and POD_CIDR
    local source_ranges="${SUBNET_RANGE}"
    if [ -n "${POD_CIDR}" ]; then
        source_ranges="${source_ranges},${POD_CIDR}"
    fi
    
    # Determine Ports
    # 1. Lookup PEER_${NAME}_PORTS
    local safe_name="${remote_cluster//-/_}"
    local port_var="PEER_${safe_name^^}_PORTS"
    # Indirect expansion safely
    local custom_ports="${!port_var:-}"
    # Sanitize: Remove spaces immediately
    custom_ports="${custom_ports// /}"
    
    local rules="icmp" # Safe default
    local desc="Allow ICMP from client cluster ${CLUSTER_NAME}"
    
    if [ -n "$custom_ports" ]; then
        log "  - Found custom ports for ${remote_cluster}: ${custom_ports}"
        
        rules="${custom_ports}"
        # Ensure ICMP is included for diagnostics if not explicitly added
        if [[ ",${rules}," != *",icmp,"* ]]; then
             rules="${rules},icmp"
        fi
        desc="Allow custom traffic (${custom_ports}) from client cluster ${CLUSTER_NAME}"
    elif [[ " ${ROOK_EXTERNAL_CLUSTERS[*]:-} " =~ " ${remote_cluster} " ]]; then
        log "  - Auto-configuring Ceph ports for peer ${remote_cluster}..."
        rules="tcp:6789,tcp:3300,tcp:6800-7300,icmp"
        desc="Allow Ceph traffic from client cluster ${CLUSTER_NAME}"
    else
        log "  - No custom ports defined for ${remote_cluster}. Defaulting to ICMP only."
    fi
    
    log "  - Configuring Remote Firewall on '${remote_vpc}'..."
    log "    > Rule: '${fw_rule_name}'"
    log "    > Allow From: ${source_ranges}"
    log "    > Rules: ${rules}"
    
    if ! gcloud compute firewall-rules describe "${fw_rule_name}" --project="${PROJECT_ID}" &>/dev/null; then
        run_safe gcloud compute firewall-rules create "${fw_rule_name}" \
            --network="${remote_vpc}" \
            --action=ALLOW \
            --direction=INGRESS \
            --source-ranges="${source_ranges}" \
            --rules="${rules}" \
            --target-tags="${remote_cluster}-worker" \
            --description="${desc}" \
            --quiet
    else
        log "    > Rule already exists. Updating..."
        run_safe gcloud compute firewall-rules update "${fw_rule_name}" \
            --source-ranges="${source_ranges}" \
            --rules="${rules}" \
            --target-tags="${remote_cluster}-worker" \
            --description="${desc}" \
            --quiet
    fi
    
    # Clean up old legacy rules if they exist (Renaming happened: -ceph and -icmp merged into -custom)
    local old_ceph="allow-${remote_cluster}-from-${CLUSTER_NAME}-ceph"
    local old_icmp="allow-${remote_cluster}-from-${CLUSTER_NAME}-icmp"
    
    if gcloud compute firewall-rules describe "${old_ceph}" --project="${PROJECT_ID}" &>/dev/null; then
         log "    > Removing legacy rule '${old_ceph}'..."
         run_safe gcloud compute firewall-rules delete "${old_ceph}" --project="${PROJECT_ID}" --quiet
    fi
    if gcloud compute firewall-rules describe "${old_icmp}" --project="${PROJECT_ID}" &>/dev/null; then
         log "    > Removing legacy rule '${old_icmp}'..."
         run_safe gcloud compute firewall-rules delete "${old_icmp}" --project="${PROJECT_ID}" --quiet
    fi
}



# Removes peerings that are NOT in the desired list
remove_stale_peerings() {
    # List all peerings in local VPC starting with 'peer-${CLUSTER_NAME}-to-'
    local desired_peers=("${PEER_WITH[@]}")
    local prefix="peer-${CLUSTER_NAME}-to-"
    
    # Get current peerings
    local current_peerings
    current_peerings=$(gcloud compute networks peerings list --network="${CLUSTER_NAME}-vpc" --project="${PROJECT_ID}" --format="value(name)" 2>/dev/null | grep "^${prefix}" || true)
    
    for peering in $current_peerings; do
        # Extract remote cluster name from peering name
        # peering name: peer-LOCAL-to-REMOTE
        local remote="${peering#${prefix}}"
        
        # Check if 'remote' is in 'desired_peers'
        local keep="false"
        for desired in "${desired_peers[@]}"; do
            if [ "$desired" == "$remote" ]; then
                keep="true"
                break
            fi
        done
        
        # If not logically kept by config, check if it's an active client (Dynamic Cleanup)
        if [ "$keep" == "false" ]; then
            local remote_vpc="${remote}-vpc"
            # Check if Remote VPC exists
            if gcloud compute networks describe "${remote_vpc}" --project="${PROJECT_ID}" &>/dev/null; then
                 log "  - Peering '${peering}' is not in config, but Remote VPC '${remote_vpc}' exists. Preserving as active client."
                 keep="true"
            else
                 log "  - Peering '${peering}' is stale and Remote VPC '${remote_vpc}' is gone. Removing..."
            fi
        fi
        
        if [ "$keep" == "false" ]; then
            # Delete Local Peering
            run_safe gcloud compute networks peerings delete "${peering}" --network="${CLUSTER_NAME}-vpc" --project="${PROJECT_ID}" --quiet
            
            # Try Delete Reverse Peering
            local reverse_peering="peer-${remote}-to-${CLUSTER_NAME}"
            log "  - Removing reverse peering '${reverse_peering}'..."
            run_safe gcloud compute networks peerings delete "${reverse_peering}" --network="${remote}-vpc" --project="${PROJECT_ID}" --quiet || warn "Could not delete reverse peering (maybe already gone or permission denied)."
            
            # Cleanup Firewalls
            log "  - Cleaning up firewalls..."
            run_safe gcloud compute firewall-rules delete "allow-${CLUSTER_NAME}-from-${remote}-custom" --project="${PROJECT_ID}" --quiet || true
            # Cleanup legacy rules if they exist
            run_safe gcloud compute firewall-rules delete "allow-${CLUSTER_NAME}-from-${remote}-ceph" --project="${PROJECT_ID}" --quiet || true
            run_safe gcloud compute firewall-rules delete "allow-${CLUSTER_NAME}-from-${remote}-icmp" --project="${PROJECT_ID}" --quiet || true
        fi
    done
}

list_peers() {
    log "Configured Peers (PEER_WITH) for '${CLUSTER_NAME}':"
    local desired_peers=("${PEER_WITH[@]}")
    if [ ${#desired_peers[@]} -eq 0 ]; then
        echo "  - None"
    else
        for peer in "${desired_peers[@]}"; do
            echo "  - ${peer}"
        done
    fi
    
    echo ""
    log "Active VPC Peerings for '${CLUSTER_NAME}-vpc':"
    
    local peerings_json
    if ! peerings_json=$(gcloud compute networks peerings list --network="${CLUSTER_NAME}-vpc" --project="${PROJECT_ID}" --format="json" 2>/dev/null); then
        warn "Could not fetch VPC peerings (VPC might not exist yet)."
        return 0
    fi
    
    if [ "$peerings_json" == "[]" ] || [ -z "$peerings_json" ]; then
        echo "  - No active peerings found."
    else
        echo "$peerings_json" | jq -r '
        ["PEERING NAME", "REMOTE NETWORK", "STATE", "DETAILS"],
        (.[] | .peerings[]? | [
            .name,
            (.network | split("/") | last),
            .state,
            .stateDetails
        ]) | @tsv' | column -t -s $'\t' | sed 's/^/  /'
    fi
    echo ""
}

