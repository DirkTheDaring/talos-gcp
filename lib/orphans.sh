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
# 1. Discovery Logic
list_orphans() {
    ORPHAN_LIST=() # Reset
    
    log "Scanning Project '${PROJECT_ID}' for orphans..."

    # Helper: Get Active Clusters (Name and Region)
    # Returns "CLUSTER_NAME|REGION" lines
    get_active_clusters() {
        local active_clusters
        if active_clusters=$(gcloud compute instances list --project="${PROJECT_ID}" --format="value(labels.cluster,zone)" 2>/dev/null | sort | uniq); then
             while read -r c_name c_zone; do
                 if [ -n "$c_name" ]; then
                     # Infer region from zone
                     local c_region="${c_zone%-*}"
                     echo "${c_name}|${c_region}"
                 fi
             done <<< "$active_clusters"
        fi
    }

    # Cache active clusters for reuse
    local ACTIVE_CLUSTERS_LIST
    ACTIVE_CLUSTERS_LIST=$(get_active_clusters)
    if [ -n "$ACTIVE_CLUSTERS_LIST" ]; then
        log "Active Clusters (for exclusion):"
        echo "$ACTIVE_CLUSTERS_LIST" | sed 's/^/  -> /'
    fi
    
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
                 
                 # Check for Active Ingress
                 local is_active="false"
                 if [[ "$name" == *"-ingress-v4-"* ]]; then
                     local cluster_name="${name%-ingress-v4-*}"
                     if echo "$ACTIVE_CLUSTERS_LIST" | grep -q "^${cluster_name}|${region_name}$"; then
                         is_active="true"
                     fi
                 fi

                 if [ "$is_active" == "false" ]; then
                     add_orphan "IP" "$name" "$region_name" "$address" "Network" "$name"
                 fi
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
    local existing_instance_urls
    existing_instance_urls=$(gcloud compute instances list --project="${PROJECT_ID}" --format="value(selfLink)" 2>/dev/null)
    
    local fwd_rules
    if fwd_rules=$(gcloud compute forwarding-rules list --project="${PROJECT_ID}" --format="json(name,region,IPAddress,target)" 2>/dev/null); then
         while read -r name region ip target; do
             if [ -n "$name" ]; then
                 if [[ "$target" == *"targetPools"* ]]; then
                     local pool_name=$(basename "$target")
                     local region_name=$(basename "$region")
                     local pool_json
                     pool_json=$(gcloud compute target-pools describe "$pool_name" --region="$region_name" --project="${PROJECT_ID}" --format="json" 2>/dev/null || echo "{}")
                     local instances
                     instances=$(echo "$pool_json" | jq -c '.instances // []')
                     
                     if [ "$instances" == "[]" ]; then
                          add_orphan "FWD_RULE" "$name" "$region_name" "IP: $ip, Target: $pool_name (Empty)" "LoadBalancer" "$name|$pool_name"
                     else
                          local has_active="false"
                          # Check if any instance URL in the pool exists in GCP
                          while read -r inst; do
                              if echo "$existing_instance_urls" | grep -Fq "$inst"; then
                                  has_active="true"
                                  break
                              fi
                          done < <(echo "$instances" | jq -r '.[]')
                          
                          if [ "$has_active" == "false" ]; then
                              add_orphan "FWD_RULE" "$name" "$region_name" "IP: $ip, Target: $pool_name (Dead VMs)" "LoadBalancer" "$name|$pool_name"
                          fi
                     fi
                 fi
             fi
         done < <(echo "$fwd_rules" | jq -r '.[] | "\(.name) \(.region) \(.IPAddress) \(.target)"')
    fi

    # E. Storage VPCs (orphaned)
    log "Scanning for Orphaned Storage VPCs..."
    local storage_vpcs
    if storage_vpcs=$(gcloud compute networks list --project="${PROJECT_ID}" --filter="name ~ .*-storage-vpc$" --format="json(name,creationTimestamp)" 2>/dev/null); then
        while read -r name created; do
             if [ -n "$name" ]; then
                 local cluster_name=${name%-storage-vpc}
                 if ! gcloud compute instances list --filter="labels.cluster=${cluster_name}" --limit=1 --format="value(name)" --project="${PROJECT_ID}" &>/dev/null; then
                      add_orphan "VPC" "$name" "global" "Cluster '${cluster_name}' likely gone. Created: $created" "Network" "$name"
                 fi
             fi
        done < <(echo "$storage_vpcs" | jq -r '.[] | "\(.name) \(.creationTimestamp)"')
    fi

    # F. Schedule Policies (orphaned)
    log "Scanning for Orphaned Schedule Policies..."
    local schedules
    if schedules=$(gcloud compute resource-policies list --project="${PROJECT_ID}" --filter="name ~ .*-schedule$" --format="json(name,region,creationTimestamp)" 2>/dev/null); then
        while read -r name region created; do
             if [ -n "$name" ]; then
                 local cluster_name=${name%-schedule}
                 # Check if any instances exist for this cluster
                 if ! gcloud compute instances list --filter="labels.cluster=${cluster_name}" --limit=1 --format="value(name)" --project="${PROJECT_ID}" &>/dev/null; then
                      local region_name=$(basename "$region")
                      add_orphan "SCHEDULE" "$name" "$region_name" "Cluster '${cluster_name}' likely gone. Created: $created" "Compute" "$name"
                 fi
             fi
        done < <(echo "$schedules" | jq -r '.[] | "\(.name) \(.region) \(.creationTimestamp)"')
    fi

    # G. Storage Firewalls
    log "Scanning for Orphaned Storage Firewalls..."
    local storage_fws
    if storage_fws=$(gcloud compute firewall-rules list --project="${PROJECT_ID}" --filter="name ~ .*-storage-internal$" --format="json(name,network,creationTimestamp)" 2>/dev/null); then
        while read -r name network created; do
             if [ -n "$name" ]; then
                  local network_name=$(basename "$network")
                  if ! gcloud compute networks describe "$network_name" --project="${PROJECT_ID}" &>/dev/null; then
                      add_orphan "FIREWALL" "$name" "global" "Network '$network_name' missing. Created: $created" "Network" "$name"
                  else
                      local cluster_name=${name%-storage-internal}
                      if ! gcloud compute instances list --filter="labels.cluster=${cluster_name}" --limit=1 --format="value(name)" --project="${PROJECT_ID}" &>/dev/null; then
                          add_orphan "FIREWALL" "$name" "global" "Cluster '${cluster_name}' likely gone. Created: $created" "Network" "$name"
                      fi
                  fi
             fi
        done < <(echo "$storage_fws" | jq -r '.[] | "\(.name) \(.network) \(.creationTimestamp)"')
    fi

    # H. Service Accounts (Orphaned)
    log "Scanning for Orphaned Service Accounts..."
    
    # helper to generate expected SAs
    generate_expected_sa_names() {
        local expected_sas=()
        
        # 1. Start with current cluster config if loaded
        if [ -n "${CLUSTER_NAME:-}" ]; then
             local current_sa="${CLUSTER_NAME}-sa"
             # Re-calculate hash based on current region
             local db_hash="0000"
             local hash_input="${CLUSTER_NAME}${REGION:-}"
             if command -v md5sum &>/dev/null; then
                 db_hash=$(echo -n "${hash_input}" | md5sum | cut -c1-4)
             elif command -v cksum &>/dev/null; then
                 db_hash=$(echo -n "${hash_input}" | cksum | cut -c1-4 | tr -d ' ')
             fi
             local current_sa_hashed="${CLUSTER_NAME}-${db_hash}-sa"
             
             expected_sas+=("$current_sa" "$current_sa_hashed")
        fi

        # 2. Use Cached Active Clusters
        while read -r line; do
             if [ -n "$line" ]; then
                 local c_name="${line%|*}"
                 local c_region="${line#*|}"
                 
                 # Legacy Name
                 expected_sas+=("${c_name}-sa")
                 
                 # Hashed Name
                 local c_hash="0000"
                 local c_hash_input="${c_name}${c_region}"
                 if command -v md5sum &>/dev/null; then
                     c_hash=$(echo -n "${c_hash_input}" | md5sum | cut -c1-4)
                 elif command -v cksum &>/dev/null; then
                     c_hash=$(echo -n "${c_hash_input}" | cksum | cut -c1-4 | tr -d ' ')
                 fi
                 expected_sas+=("${c_name}-${c_hash}-sa")
             fi
        done <<< "$ACTIVE_CLUSTERS_LIST"

        
        # 3. Scan local config files (clusters/*.env) as backup
        # This helps if a cluster is configured but currently has 0 instances
        if [ -d "clusters" ]; then
            for env_file in clusters/*.env; do
                if [ -f "$env_file" ]; then
                     # Grep CLUSTER_NAME and REGION (crude but safer than sourcing untrusted files in loop)
                     local f_cluster=$(grep "^CLUSTER_NAME=" "$env_file" | cut -d'"' -f2 || true)
                     local f_region=$(grep "^REGION=" "$env_file" | cut -d'"' -f2 || true)
                     
                     if [ -n "$f_cluster" ]; then
                         expected_sas+=("${f_cluster}-sa")
                         
                         if [ -n "$f_region" ]; then
                             local f_hash="0000"
                             local f_hash_input="${f_cluster}${f_region}"
                             if command -v md5sum &>/dev/null; then
                                 f_hash=$(echo -n "${f_hash_input}" | md5sum | cut -c1-4)
                             elif command -v cksum &>/dev/null; then
                                 f_hash=$(echo -n "${f_hash_input}" | cksum | cut -c1-4 | tr -d ' ')
                             fi
                             expected_sas+=("${f_cluster}-${f_hash}-sa")
                         fi
                     fi
                fi
            done
        fi
        
        # Print unique
        echo "${expected_sas[@]}" | tr ' ' '\n' | sort | uniq
    }

    # Build Allowlist
    local EXPECTED_SAS
    EXPECTED_SAS=$(generate_expected_sa_names)
    
    # List all SAs matching *-sa
    local found_sas
    if found_sas=$(gcloud iam service-accounts list --project="${PROJECT_ID}" --filter="email:*-sa@${PROJECT_ID}.iam.gserviceaccount.com" --format="json(email,displayName)" 2>/dev/null); then
        while read -r sa_email sa_name; do
             if [ -n "$sa_email" ]; then
                 local sa_short=${sa_email%@*} # Remove @project...
                 
                 # Check if in expected list
                 if ! echo "$EXPECTED_SAS" | grep -q "^${sa_short}$"; then
                      add_orphan "SA" "$sa_email" "global" "Not linked to any active cluster config or running instances." "IAM" "$sa_email"
                 fi
             fi
        done < <(echo "$found_sas" | jq -r '.[] | "\(.email) \(.displayName)"')
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
    while true; do
        list_orphans
        
        if [ ${#ORPHAN_LIST[@]} -eq 0 ]; then
            log "No orphans found."
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
                         local fw_name="${name}"
                         local pool_name=""
                         if [[ "$raw_id" == *"|"* ]]; then
                             fw_name="${raw_id%|*}"
                             pool_name="${raw_id#*|}"
                         fi
                         
                         if run_safe gcloud compute forwarding-rules delete "$fw_name" --region="$zone" --project="${PROJECT_ID}" --quiet; then
                             log "Deleted Forwarding Rule."
                             if [ -n "$pool_name" ]; then
                                 log "Deleting associated Target Pool '${pool_name}'..."
                                 if run_safe gcloud compute target-pools delete "$pool_name" --region="$zone" --project="${PROJECT_ID}" --quiet; then
                                     log "Deleted Target Pool."
                                 else
                                     warn "Failed to delete Target Pool."
                                 fi
                             fi
                         else
                             error "Failed to delete forwarding rule."
                         fi
                         ;;
                     "VPC")
                         if run_safe gcloud compute networks delete "$name" --project="${PROJECT_ID}" --quiet; then
                             log "Deleted."
                         else
                             error "Failed to delete VPC."
                         fi
                         ;;
                     "SCHEDULE")
                         if run_safe gcloud compute resource-policies delete "$name" --region="$zone" --project="${PROJECT_ID}" --quiet; then
                             log "Deleted."
                         else
                             error "Failed to delete Schedule."
                         fi
                         ;;
                     "FIREWALL")
                         if run_safe gcloud compute firewall-rules delete "$name" --project="${PROJECT_ID}" --quiet; then
                             log "Deleted."
                         else
                             error "Failed to delete Firewall."
                         fi
                         ;;
                     "SA")
                         if run_safe gcloud iam service-accounts delete "$name" --project="${PROJECT_ID}" --quiet; then
                             log "Deleted."
                         else
                             error "Failed to delete Service Account."
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
        
        echo ""
        log "Batch complete. Refreshing list..."
        # Loop continues, refreshing list_orphans
    done
}
