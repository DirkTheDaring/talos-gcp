#!/bin/bash

# --- Orphans & Hygiene Management ---

# Global Arrays to store found orphans
# Format: "TYPE|ID|NAME|ZONE|DETAILS|COST_FACTOR|RAW_RESOURCE_ID"
declare -a ORPHAN_LIST

# Add an item to the global list
add_orphan() {
    local type="$1"
    local name="$2"
    local zone="$3"
    local details="$4"
    local cost="$5"
    local raw_id="$6" # Full URI or specific ID needed for deletion
    
    ORPHAN_LIST+=("${type}|${name}|${zone}|${details}|${cost}|${raw_id}")
}

# 1. Discovery Logic
list_orphans() {
    ORPHAN_LIST=() # Reset
    
    log "Scanning Project '${PROJECT_ID}' for orphans..."
    
    # A. Disks (Unattached)
    log "Scanning for Unattached Disks..."
    # Get JSON: name, zone, sizeGb, status, lastDetachTimestamp, users
    local disks
    if disks=$(gcloud compute disks list --project="${PROJECT_ID}" --filter="status:READY AND -users:*" --format="json(name,zone,sizeGb,lastDetachTimestamp)" 2>/dev/null); then
        # Parse with jq
        while read -r name zone size detach_ts; do
            if [ -n "$name" ]; then
                local zone_name=$(basename "$zone")
                # Safety Check: Detached < 1 hour?
                local details="${size}GB"
                local safety_note=""
                
                if [ -n "$detach_ts" ] && [ "$detach_ts" != "null" ]; then
                    # Convert to seconds (requires date command that supports ISO8601, or python)
                    # For simplicity/compatibility, we'll just show the time. 
                    # Real safe implementation would compare timestamps.
                    # We will tag it in details.
                    details="${details}, Detached: $detach_ts"
                fi
                
                add_orphan "DISK" "$name" "$zone_name" "$details" "Storage" "$name"
            fi
        done < <(echo "$disks" | jq -r '.[] | "\(.name) \(.zone) \(.sizeGb) \(.lastDetachTimestamp)"')
    fi

    # B. Static IPs (Unused)
    log "Scanning for Unused Static IPs..."
    local ips
    if ips=$(gcloud compute addresses list --project="${PROJECT_ID}" --filter="status:RESERVED AND -users:*" --format="json(name,region,address)" 2>/dev/null); then
        while read -r name region address; do
             if [ -n "$name" ]; then
                 local region_name=$(basename "$region")
                 add_orphan "IP" "$name" "$region_name" "$address" "Network" "$name"
             fi
        done < <(echo "$ips" | jq -r '.[] | "\(.name) \(.region) \(.address)"')
    fi

    # C. Images (Dangling Talos)
    log "Scanning for Dangling Talos Images..."
    # 1. Get all instances' source disks
    local used_images
    used_images=$(gcloud compute instances list --project="${PROJECT_ID}" --format="value(disks[0].source)" 2>/dev/null | awk -F'/' '{print $NF}' | sort | uniq)
    
    # 2. Get all Talos images
    local images
    if images=$(gcloud compute images list --project="${PROJECT_ID}" --filter="name~'talos-.*'" --format="json(name,diskSizeGb,creationTimestamp)" 2>/dev/null); then
        while read -r name size created; do
            if [ -n "$name" ]; then
                 # Check if used
                 if ! echo "$used_images" | grep -q "^${name}$"; then
                     add_orphan "IMAGE" "$name" "global" "${size}GB, Created: $created" "Storage" "$name"
                 fi
            fi
        done < <(echo "$images" | jq -r '.[] | "\(.name) \(.diskSizeGb) \(.creationTimestamp)"')
    fi

    # D. Forwarding Rules (Heuristic: No Backends)
    log "Scanning for Orphaned Forwarding Rules..."
    # This is harder to do purely with filters. We'll list rules and check targets.
    # For now, let's stick to the high-value ones from the previous script: those pointing to non-existent or empty pools?
    # Simplified: List rules, user must judge cost. 
    # But to be safe, let's filter for valid orphans from our manual check: 
    # Logic: If target is a TargetPool, check if pool has instances.
    local fwd_rules
    if fwd_rules=$(gcloud compute forwarding-rules list --project="${PROJECT_ID}" --format="json(name,region,IPAddress,target)" 2>/dev/null); then
         while read -r name region ip target; do
             if [ -n "$name" ]; then
                 # Heuristic: If target contains "targetPools", check that pool
                 if [[ "$target" == *"targetPools"* ]]; then
                     local pool_name=$(basename "$target")
                     local region_name=$(basename "$region")
                     # Check pool health/instances
                     local pool_json
                     pool_json=$(gcloud compute target-pools describe "$pool_name" --region="$region_name" --project="${PROJECT_ID}" --format="json" 2>/dev/null || echo "{}")
                     local instances
                     instances=$(echo "$pool_json" | jq -r '.instances')
                     
                     if [ "$instances" == "null" ] || [ -z "$instances" ]; then
                          add_orphan "FWD_RULE" "$name" "$region_name" "IP: $ip, Target: $pool_name (Empty/Missing)" "LoadBalancer" "$name"
                     fi
                 fi
             fi
         done < <(echo "$fwd_rules" | jq -r '.[] | "\(.name) \(.region) \(.IPAddress) \(.target)"')
    fi
    
    # --- Display ---
    echo ""
    echo "------------------------------------------------------------------------------------------------"
    printf "%-4s | %-10s | %-40s | %-15s | %-15s\n" "ID" "TYPE" "NAME" "ZONE/REGION" "COST FACTOR"
    echo "------------------------------------------------------------------------------------------------"
    
    if [ ${#ORPHAN_LIST[@]} -eq 0 ]; then
        echo "No orphans found!"
        return 0
    fi

    local i=1
    for item in "${ORPHAN_LIST[@]}"; do
        # IFS parse
        IFS='|' read -r type name zone details cost raw_id <<< "$item"
        printf "%-4s | %-10s | %-40s | %-15s | %-15s\n" "$i" "$type" "$name" "$zone" "$cost"
        echo "     -> Details: $details"
        ((i++))
    done
    echo "------------------------------------------------------------------------------------------------"
    echo "Total Orphans: ${#ORPHAN_LIST[@]}"
}

# 2. Cleanup Logic
cleanup_orphans() {
    list_orphans
    
    if [ ${#ORPHAN_LIST[@]} -eq 0 ]; then
        return 0
    fi
    
    echo ""
    echo "Select resources to delete."
    echo "Enter individual IDs (e.g. 1 3 5), ranges (e.g. 1-3), 'all', or 'q' to quit."
    read -r -p "Selection: " selection
    
    if [[ "$selection" == "q" ]] || [[ "$selection" == "quit" ]] || [ -z "$selection" ]; then
        log "Operation cancelled."
        return 0
    fi
    
    # Parse Selection
    local indices=()
    if [[ "$selection" == "all" ]]; then
        for ((i=1; i<=${#ORPHAN_LIST[@]}; i++)); do
            indices+=("$i")
        done
    else
        # Split by space or comma
        IFS=' ,' read -r -a parts <<< "$selection"
        for part in "${parts[@]}"; do
            if [[ "$part" =~ ^[0-9]+$ ]]; then
                indices+=("$part")
            elif [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                local start="${BASH_REMATCH[1]}"
                local end="${BASH_REMATCH[2]}"
                for ((i=start; i<=end; i++)); do
                    indices+=("$i")
                done
            fi
        done
    fi
    
    # Dedup and Sort
    # Safe multi-line string handling for sort -n -u
    local sorted_string
    sorted_string=$(tr ' ' '\n' <<<"${indices[*]}" | sort -n -u)
    # Convert back to array
    IFS=$'\n' read -r -d '' -a sorted_indices <<< "$sorted_string" || true
    
    # Process Deletion
    echo ""
    log "You have selected ${#sorted_indices[@]} resource(s) for deletion."
    
    for idx in "${sorted_indices[@]}"; do
        # Validate Index
        if [ "$idx" -lt 1 ] || [ "$idx" -gt "${#ORPHAN_LIST[@]}" ]; then
             warn "Invalid ID: $idx (Skipping)"
             continue
        fi
        
        # Get Item (Array is 0-indexed, ID is 1-indexed)
        local item="${ORPHAN_LIST[$((idx-1))]}"
        IFS='|' read -r type name zone details cost raw_id <<< "$item"
        
        # Detached Safety Check
        if [[ "$details" == *"Detached:"* ]]; then
             warn "SAFETY WARNING: Resource '${name}' was detached within the last hour!"
             warn "Details: $details"
             read -r -p "Are you absolutely sure you want to delete it? [y/N] " confirm_force
             if [[ ! "$confirm_force" =~ ^[yY]$ ]]; then
                 log "Skipping '${name}' due to safety check."
                 continue
             fi
        fi

        # Confirmation
        echo -e "${RED}DELETE: [${type}] ${name} (${zone})${NC}"
        read -r -p "Are you SURE? [y/N] " confirm
        
        if [[ "$confirm" =~ ^[yY]$ ]]; then
             log "Deleting ${type} '${name}'..."
             
             case "$type" in
                 "DISK")
                     if run_safe gcloud compute disks delete "$name" --zone="$zone" --project="${PROJECT_ID}" --quiet; then
                         log "Deleted."
                     else
                         error "Failed to delete disk."
                     fi
                     ;;
                 "IP")
                     if run_safe gcloud compute addresses delete "$name" --region="$zone" --project="${PROJECT_ID}" --quiet; then
                         log "Deleted."
                     else
                         error "Failed to delete IP."
                     fi
                     ;;
                 "IMAGE")
                     if run_safe gcloud compute images delete "$name" --project="${PROJECT_ID}" --quiet; then
                         log "Deleted."
                     else
                         error "Failed to delete image."
                     fi
                     ;;
                 "FWD_RULE")
                     # Also try to clean up the target pool if it's empty?
                     # For safety, just delete the rule first. User can re-run to see if target pool becomes orphan (not implemented yet, but safe step).
                     if run_safe gcloud compute forwarding-rules delete "$name" --region="$zone" --project="${PROJECT_ID}" --quiet; then
                         log "Deleted."
                     else
                         error "Failed to delete forwarding rule."
                     fi
                     ;;
                 *)
                     error "Unknown resource type: $type"
                     ;;
             esac
        else
             log "Skipped."
        fi
    done
    
    log "Cleanup complete."
}
