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

# Connects current cluster and remote cluster via VPC Peering
# Arguments:
#   $1: remote_cluster_name
peer_connect() {
    local remote_cluster="$1"
    local local_vpc="${CLUSTER_NAME}-vpc"
    local remote_vpc="${remote_cluster}-vpc"
    local peering_name="peer-${CLUSTER_NAME}-to-${remote_cluster}"
    local reverse_peering_name="peer-${remote_cluster}-to-${CLUSTER_NAME}"

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
        run_safe gcloud compute networks peerings create "${peering_name}" \
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
        run_safe gcloud compute networks peerings create "${reverse_peering_name}" \
            --network="${remote_vpc}" \
            --peer-network="${local_vpc}" \
            --project="${PROJECT_ID}" \
            --auto-create-routes \
            --quiet
    fi

    # Update Firewalls
    update_peering_firewalls "${remote_cluster}"
}

# Updates Firewall Rules for the accepted peer
# Enforces strictly limited access (Ceph Ports)
update_peering_firewalls() {
    local remote_cluster="$1"
    local local_vpc="${CLUSTER_NAME}-vpc"
    # We need to know the Remote Cluster's CIDRs to allow ingress.
    # Since we don't have access to remote environment variables here easily without complex lookup,
    # we might need to describe the remote subnets.
    
    # Fetch Remote Subnets (Node CIDR)
    local remote_subnet_name="${remote_cluster}-subnet"
    local remote_cidr
    # Attempt to find the subnet in ANY region (Region-Agnostic)
    # We filter by name AND network to ensuring we get the right one
    remote_cidr=$(gcloud compute networks subnets list --filter="name=${remote_subnet_name} AND network=${remote_cluster}-vpc" --format="value(ipCidrRange)" --project="${PROJECT_ID}" | head -n1)
    
    # If standard lookup fails (maybe different region?), try alias IP (Pod CIDR) lookup logic if possible.
    # For native routing, we MUST include the secondary ranges (Pod CIDRs) in the allowed source ranges.
    
    local remote_secondary_cidrs
    remote_secondary_cidrs=$(gcloud compute networks subnets list --filter="name=${remote_subnet_name} AND network=${remote_cluster}-vpc" --format="json(secondaryIpRanges)" --project="${PROJECT_ID}" | jq -r '.[].secondaryIpRanges[].ipCidrRange' 2>/dev/null | tr '\n' ',' | sed 's/,$//')

    if [ -n "$remote_secondary_cidrs" ]; then
        log "  - Found secondary ranges for ${remote_cluster}: ${remote_secondary_cidrs}"
        if [ -n "$remote_cidr" ]; then
            remote_cidr="${remote_cidr},${remote_secondary_cidrs}"
        else
             remote_cidr="${remote_secondary_cidrs}"
        fi
    fi
    
    if [ -z "$remote_cidr" ]; then
        error "Could not determine CIDR for remote cluster '${remote_cluster}'. Is it deployed?"
        return 1
    fi
    
    log "  - Updating Firewalls for remote CIDR: ${remote_cidr}..."

    # Rule 1: Allow Ceph Ports (Mon: 6789, 3300, OSD: 6800-7300) from Remote
    # Direction: INGRESS
    # Target: All instances (or ideally just OSDs/Mons if we had tags, but 'allow' is safe to VPC boundaries)
    local fw_ceph_name="allow-${CLUSTER_NAME}-from-${remote_cluster}-ceph"
    
    if ! gcloud compute firewall-rules describe "${fw_ceph_name}" --project="${PROJECT_ID}" &>/dev/null; then
        log "    - Creating rule '${fw_ceph_name}' (Ports: 6789,3300,6800-7300)..."
        run_safe gcloud compute firewall-rules create "${fw_ceph_name}" \
            --network="${local_vpc}" \
            --action=ALLOW \
            --direction=INGRESS \
            --source-ranges="${remote_cidr}" \
            --rules="tcp:6789,tcp:3300,tcp:6800-7300" \
            --target-tags="${CLUSTER_NAME}-worker" \
            --description="Allow Ceph traffic from peered cluster ${remote_cluster}" \
            --quiet
    else
        log "    - Rule '${fw_ceph_name}' exists."
    fi
    
    # We should also allow ICMP for diagnostics
    local fw_icmp_name="allow-${CLUSTER_NAME}-from-${remote_cluster}-icmp"
    if ! gcloud compute firewall-rules describe "${fw_icmp_name}" --project="${PROJECT_ID}" &>/dev/null; then
         run_safe gcloud compute firewall-rules create "${fw_icmp_name}" \
            --network="${local_vpc}" \
            --action=ALLOW \
            --direction=INGRESS \
            --source-ranges="${remote_cidr}" \
            --rules="icmp" \
            --quiet
    fi
}

# Removes peerings that are NOT in the desired list
remove_stale_peerings() {
    # List all peerings in local VPC starting with 'peer-${CLUSTER_NAME}-to-'
    local desired_peers=("${PEER_WITH[@]}")
    local prefix="peer-${CLUSTER_NAME}-to-"
    
    # Get current peerings
    local current_peerings
    current_peerings=$(gcloud compute networks peerings list --network="${CLUSTER_NAME}-vpc" --project="${PROJECT_ID}" --format="value(name)" 2>/dev/null | grep "^${prefix}")
    
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
        
        if [ "$keep" == "false" ]; then
            log "Found stale peering '${peering}' (Remote: ${remote}). Removing..."
            
            # Delete Local Peering
            run_safe gcloud compute networks peerings delete "${peering}" --network="${CLUSTER_NAME}-vpc" --project="${PROJECT_ID}" --quiet
            
            # Try Delete Reverse Peering
            local reverse_peering="peer-${remote}-to-${CLUSTER_NAME}"
            log "  - Removing reverse peering '${reverse_peering}'..."
            run_safe gcloud compute networks peerings delete "${reverse_peering}" --network="${remote}-vpc" --project="${PROJECT_ID}" --quiet || warn "Could not delete reverse peering (maybe already gone or permission denied)."
            
            # Cleanup Firewalls
            log "  - Cleaning up firewalls..."
            run_safe gcloud compute firewall-rules delete "allow-${CLUSTER_NAME}-from-${remote}-ceph" --project="${PROJECT_ID}" --quiet || true
            run_safe gcloud compute firewall-rules delete "allow-${CLUSTER_NAME}-from-${remote}-icmp" --project="${PROJECT_ID}" --quiet || true
        fi
    done
}
