#!/bin/bash

ensure_backends() {
    # 1. TCP Backend Service
    if ! gcloud compute health-checks describe "${HC_WORKER_NAME}" --region "${REGION}" --project="${PROJECT_ID}" &> /dev/null; then
        run_safe gcloud compute health-checks create tcp "${HC_WORKER_NAME}" --region "${REGION}" --port "${WORKER_HC_PORT}" --project="${PROJECT_ID}"
    fi
     if ! gcloud compute backend-services describe "${BE_WORKER_NAME}" --region "${REGION}" --project="${PROJECT_ID}" &> /dev/null; then
        run_safe gcloud compute backend-services create "${BE_WORKER_NAME}" --region "${REGION}" --load-balancing-scheme=EXTERNAL --protocol=TCP --health-checks-region="${REGION}" --health-checks="${HC_WORKER_NAME}" --project="${PROJECT_ID}"
    fi
    # NOTE: Attachment is handled in provision_workers() to support dynamic pools

    # 2. UDP Backend Service
    if ! gcloud compute health-checks describe "${HC_WORKER_UDP_NAME}" --region "${REGION}" --project="${PROJECT_ID}" &> /dev/null; then
        # Note: We create a TCP health check for the UDP backend.
        # This assumes your UDP service (or Ingress Controller) also exposes a TCP port (e.g. 80) for health checking.
        # Pure UDP services without a TCP sidecar might fail this check.
        run_safe gcloud compute health-checks create tcp "${HC_WORKER_UDP_NAME}" --region "${REGION}" --port "${WORKER_HC_PORT}" --project="${PROJECT_ID}"
    fi
     if ! gcloud compute backend-services describe "${BE_WORKER_UDP_NAME}" --region "${REGION}" --project="${PROJECT_ID}" &> /dev/null; then
        run_safe gcloud compute backend-services create "${BE_WORKER_UDP_NAME}" --region "${REGION}" --load-balancing-scheme=EXTERNAL --protocol=UDP --health-checks-region="${REGION}" --health-checks="${HC_WORKER_UDP_NAME}" --project="${PROJECT_ID}"
    fi
}


apply_ingress() {
    log "Applying Ingress Configuration..."
    ensure_backends
    
    # --- Step 1: IP Provisioning ---
    log "Reconciling Static IPs (Count: ${INGRESS_IP_COUNT})..."
    
    # 1. Create/Verify IPs up to Count
    for (( i=0; i<INGRESS_IP_COUNT; i++ )); do
        local ip_name="${CLUSTER_NAME}-ingress-v4-${i}"
        if ! gcloud compute addresses describe "${ip_name}" --region "${REGION}" --project="${PROJECT_ID}" &> /dev/null; then
             log "Creating IP address '${ip_name}'..."
             run_safe gcloud compute addresses create "${ip_name}" --region "${REGION}" --project="${PROJECT_ID}"
        else
             log "IP address '${ip_name}' exists."
        fi
    done

    # 2. Prune IPs beyond Count (Cleanup)
    # Scan for existing IPs and remove those that exceed the count
    local existing_ips
    existing_ips=$(gcloud compute addresses list --filter="name:${CLUSTER_NAME}-ingress-v4-*" --format="value(name)" --project="${PROJECT_ID}")
    
    for ip_name in $existing_ips; do
        if [[ "$ip_name" =~ ^${CLUSTER_NAME}-ingress-v4-([0-9]+)$ ]]; then
            local idx="${BASH_REMATCH[1]}"
            if [ "$idx" -ge "$INGRESS_IP_COUNT" ]; then
                 log "Removing orphaned IP address '${ip_name}' (Index ${idx} >= Count ${INGRESS_IP_COUNT})..."
                 run_safe gcloud compute addresses delete "${ip_name}" --region "${REGION}" --project="${PROJECT_ID}" -q
            fi
        fi
    done

    # --- Step 2: Rule Reconciliation (Forwarding & Firewall) ---
    log "Reconciling Forwarding & Firewall Rules (Based on INGRESS_IPV4_CONFIG)..."
    
    # Parse Config
    IFS=';' read -ra CONFIG_ADDR <<< "$INGRESS_IPV4_CONFIG"
    
    # Warning for config mismatch
    if [ "${#CONFIG_ADDR[@]}" -gt "$INGRESS_IP_COUNT" ]; then
        warn "INGRESS_IPV4_CONFIG contains ${#CONFIG_ADDR[@]} entries, but INGRESS_IP_COUNT is only ${INGRESS_IP_COUNT}."
        warn "Entries beyond index $((INGRESS_IP_COUNT-1)) will be ignored."
    fi
    
    # Loop through ALL reserved IPs (0 to Count-1)
    # If config exists for index, Apply Rules.
    # If config missing/empty for index, Delete Rules.
    
    for (( i=0; i<INGRESS_IP_COUNT; i++ )); do
         local group_config="${CONFIG_ADDR[$i]:-}" # Get config for this index, default empty
         
         local rule_name_tcp="${CLUSTER_NAME}-ingress-v4-rule-${i}-tcp"
         local rule_name_udp="${CLUSTER_NAME}-ingress-v4-rule-${i}-udp"
         local rule_name_legacy="${CLUSTER_NAME}-ingress-v4-rule-${i}"
         local fw_name="${FW_INGRESS_BASE}-v4-${i}"
         
         # 1. Get allocated IP Address
         local ip_name="${CLUSTER_NAME}-ingress-v4-${i}"
         local ip_addr
         ip_addr=$(gcloud compute addresses describe "${ip_name}" --region "${REGION}" --format="value(address)" --project="${PROJECT_ID}" 2>/dev/null || echo "")
         
         if [ -z "$ip_addr" ]; then
             warn "IP ${ip_name} not found! Skipping rule processing for index $i."
             continue
         fi
         
         if [ -n "$group_config" ]; then
             log "Configuring Rules for IP $i ($ip_addr): Config=[$group_config]..."
             
             # Parse Ports
             local tcp_ports=""
             local udp_ports=""
             
             IFS=',' read -ra ITEMS <<< "$group_config"
             for item in "${ITEMS[@]}"; do
                 if [[ "$item" == */udp ]]; then
                     local port=${item%/udp}
                     udp_ports="${udp_ports},${port}"
                 elif [[ "$item" == */tcp ]]; then
                     local port=${item%/tcp}
                     tcp_ports="${tcp_ports},${port}"
                 else
                     # Default: Both
                     local port="$item"
                     tcp_ports="${tcp_ports},${port}"
                     udp_ports="${udp_ports},${port}"
                 fi
             done
             
             # Sanitization (sort -n | uniq for ranges/numbers)
             if [ -n "$tcp_ports" ]; then
                 tcp_ports=$(echo "${tcp_ports//,/$'\n'}" | sed '/^$/d' | sort -n | uniq | tr '\n' ',' | sed 's/,$//')
             fi
             if [ -n "$udp_ports" ]; then
                 udp_ports=$(echo "${udp_ports//,/$'\n'}" | sed '/^$/d' | sort -n | uniq | tr '\n' ',' | sed 's/,$//')
             fi

             # Remove leading commas
             tcp_ports="${tcp_ports#,}"
             udp_ports="${udp_ports#,}"

             # --- TCP Rule ---
             if [ -n "$tcp_ports" ]; then
                 if ! gcloud compute forwarding-rules describe "${rule_name_tcp}" --region "${REGION}" --project="${PROJECT_ID}" &> /dev/null; then
                      run_safe gcloud compute forwarding-rules create "${rule_name_tcp}" --region "${REGION}" --load-balancing-scheme=EXTERNAL --ip-protocol=TCP --ports="${tcp_ports}" --address="${ip_addr}" --backend-service="${BE_WORKER_NAME}" --project="${PROJECT_ID}"
                 else
                      local current_ports
                      # Sanitization for comparison
                      current_ports=$(gcloud compute forwarding-rules describe "${rule_name_tcp}" --region "${REGION}" --project="${PROJECT_ID}" --format="value(ports)" | tr ';,' '\n' | sort -n | uniq | tr '\n' ',' | sed 's/,$//')
                      local sorted_new_ports
                      sorted_new_ports=$(echo "${tcp_ports//,/$'\n'}" | sort -n | uniq | tr '\n' ',' | sed 's/,$//')
                      
                      if [[ "$current_ports" != "$sorted_new_ports" ]]; then
                          log "Updating TCP rule ${rule_name_tcp} ($current_ports -> $tcp_ports)..."
                          # Attempt update first
                          if ! gcloud compute forwarding-rules update "${rule_name_tcp}" --region "${REGION}" --project="${PROJECT_ID}" --ports="${tcp_ports}" 2>/dev/null; then
                               warn "Update failed, falling back to recreate..."
                               run_safe gcloud compute forwarding-rules delete "${rule_name_tcp}" --region "${REGION}" --project="${PROJECT_ID}" -q
                               run_safe gcloud compute forwarding-rules create "${rule_name_tcp}" --region "${REGION}" --load-balancing-scheme=EXTERNAL --ip-protocol=TCP --ports="${tcp_ports}" --address="${ip_addr}" --backend-service="${BE_WORKER_NAME}" --project="${PROJECT_ID}"
                          fi
                      fi
                 fi
             else
                 # Cleanup if config has no TCP ports
                  if gcloud compute forwarding-rules describe "${rule_name_tcp}" --region "${REGION}" --project="${PROJECT_ID}" &> /dev/null; then
                     run_safe gcloud compute forwarding-rules delete "${rule_name_tcp}" --region "${REGION}" --project="${PROJECT_ID}" -q
                 fi
             fi
             
             # --- UDP Rule ---
             if [ -n "$udp_ports" ]; then
                 if ! gcloud compute forwarding-rules describe "${rule_name_udp}" --region "${REGION}" --project="${PROJECT_ID}" &> /dev/null; then
                      run_safe gcloud compute forwarding-rules create "${rule_name_udp}" --region "${REGION}" --load-balancing-scheme=EXTERNAL --ip-protocol=UDP --ports="${udp_ports}" --address="${ip_addr}" --backend-service="${BE_WORKER_UDP_NAME}" --project="${PROJECT_ID}"
                 else
                      local current_ports
                      current_ports=$(gcloud compute forwarding-rules describe "${rule_name_udp}" --region "${REGION}" --project="${PROJECT_ID}" --format="value(ports)" | tr ';,' '\n' | sort -n | uniq | tr '\n' ',' | sed 's/,$//')
                      local sorted_new_ports
                      sorted_new_ports=$(echo "${udp_ports//,/$'\n'}" | sort -n | uniq | tr '\n' ',' | sed 's/,$//')

                      if [[ "$current_ports" != "$sorted_new_ports" ]]; then
                          log "Updating UDP rule ${rule_name_udp} ($current_ports -> $udp_ports)..."
                          if ! gcloud compute forwarding-rules update "${rule_name_udp}" --region "${REGION}" --project="${PROJECT_ID}" --ports="${udp_ports}" 2>/dev/null; then
                               warn "Update failed, falling back to recreate..."
                               run_safe gcloud compute forwarding-rules delete "${rule_name_udp}" --region "${REGION}" --project="${PROJECT_ID}" -q
                               run_safe gcloud compute forwarding-rules create "${rule_name_udp}" --region "${REGION}" --load-balancing-scheme=EXTERNAL --ip-protocol=UDP --ports="${udp_ports}" --address="${ip_addr}" --backend-service="${BE_WORKER_UDP_NAME}" --project="${PROJECT_ID}"
                          fi
                      fi
                 fi
             else
                  if gcloud compute forwarding-rules describe "${rule_name_udp}" --region "${REGION}" --project="${PROJECT_ID}" &> /dev/null; then
                     run_safe gcloud compute forwarding-rules delete "${rule_name_udp}" --region "${REGION}" --project="${PROJECT_ID}" -q
                 fi
             fi
             
             # --- Firewall Rule ---
             # Construct allowed string correctly: tcp:p1,tcp:p2,udp:p3...
             local allowed=""
             if [ -n "$tcp_ports" ]; then
                IFS=',' read -ra POTS <<< "$tcp_ports"
                for p in "${POTS[@]}"; do
                    allowed="${allowed},tcp:${p}"
                done
             fi
             if [ -n "$udp_ports" ]; then 
                IFS=',' read -ra POTS <<< "$udp_ports"
                for p in "${POTS[@]}"; do
                    allowed="${allowed},udp:${p}"
                done
             fi
             allowed="${allowed#,}"
             
             if [ -n "$allowed" ]; then
                 if ! gcloud compute firewall-rules describe "${fw_name}" --project="${PROJECT_ID}" &> /dev/null; then
                     run_safe gcloud compute firewall-rules create "${fw_name}" --project="${PROJECT_ID}" --network="${VPC_NAME}" --direction=INGRESS --priority=1000 --action=ALLOW --rules="${allowed}" --source-ranges="0.0.0.0/0" --target-tags="talos-worker"
                 else
                     # Update existing rule
                     run_safe gcloud compute firewall-rules update "${fw_name}" --project="${PROJECT_ID}" --rules="${allowed}" --source-ranges="0.0.0.0/0" --target-tags="talos-worker"
                 fi
             else
                  if gcloud compute firewall-rules describe "${fw_name}" --project="${PROJECT_ID}" &> /dev/null; then
                     run_safe gcloud compute firewall-rules delete "${fw_name}" --project="${PROJECT_ID}" -q
                 fi
             fi

         else
             # Config EMPTY/UNSET -> Ensure NO Rules exist for this IP
             if gcloud compute forwarding-rules describe "${rule_name_tcp}" --region "${REGION}" --project="${PROJECT_ID}" &> /dev/null; then
                 log "Removing unused TCP rule ${rule_name_tcp} (No Config)..."
                 run_safe gcloud compute forwarding-rules delete "${rule_name_tcp}" --region "${REGION}" --project="${PROJECT_ID}" -q
             fi
             if gcloud compute forwarding-rules describe "${rule_name_udp}" --region "${REGION}" --project="${PROJECT_ID}" &> /dev/null; then
                 log "Removing unused UDP rule ${rule_name_udp} (No Config)..."
                 run_safe gcloud compute forwarding-rules delete "${rule_name_udp}" --region "${REGION}" --project="${PROJECT_ID}" -q
             fi
             if gcloud compute firewall-rules describe "${fw_name}" --project="${PROJECT_ID}" &> /dev/null; then
                 log "Removing unused Firewall rule ${fw_name} (No Config)..."
                 run_safe gcloud compute firewall-rules delete "${fw_name}" --project="${PROJECT_ID}" -q
             fi
         fi
         
         # Always cleanup Legacy Rule if it exists
         if gcloud compute forwarding-rules describe "${rule_name_legacy}" --region "${REGION}" --project="${PROJECT_ID}" &> /dev/null; then
             log "Removing legacy rule ${rule_name_legacy}..."
             run_safe gcloud compute forwarding-rules delete "${rule_name_legacy}" --region "${REGION}" --project="${PROJECT_ID}" -q
         fi
    done
    
    # --- Step 3: Prune Orphaned Rules (Indices >= Count) ---
    local existing_rules
    # List forwarding rules matching pattern
    existing_rules=$(gcloud compute forwarding-rules list --filter="name:${CLUSTER_NAME}-ingress-v4-rule-*" --format="value(name)" --regions "${REGION}" --project="${PROJECT_ID}")
    for rname in $existing_rules; do
        if [[ "$rname" =~ ^${CLUSTER_NAME}-ingress-v4-rule-([0-9]+)(-tcp|-udp)?$ ]]; then
            local idx="${BASH_REMATCH[1]}"
            if [ "$idx" -ge "$INGRESS_IP_COUNT" ]; then
                log "Removing orphaned forwarding rule '${rname}'..."
                run_safe gcloud compute forwarding-rules delete "${rname}" --region "${REGION}" --project="${PROJECT_ID}" -q
            fi
        # Also catch legacy name exact match
        elif [[ "$rname" =~ ^${CLUSTER_NAME}-ingress-v4-rule-([0-9]+)$ ]]; then
             local idx="${BASH_REMATCH[1]}"
             if [ "$idx" -ge "$INGRESS_IP_COUNT" ]; then
                log "Removing orphaned legacy rule '${rname}'..."
                run_safe gcloud compute forwarding-rules delete "${rname}" --region "${REGION}" --project="${PROJECT_ID}" -q
             fi
        fi
    done
    
    # List firewall rules matching pattern
    local existing_fw
    existing_fw=$(gcloud compute firewall-rules list --filter="name:${FW_INGRESS_BASE}-v4-*" --format="value(name)" --project="${PROJECT_ID}")
    for fname in $existing_fw; do
        if [[ "$fname" =~ ^${FW_INGRESS_BASE}-v4-([0-9]+)$ ]]; then
            local idx="${BASH_REMATCH[1]}"
             if [ "$idx" -ge "$INGRESS_IP_COUNT" ]; then
                log "Removing orphaned firewall rule '${fname}'..."
                run_safe gcloud compute firewall-rules delete "${fname}" --project="${PROJECT_ID}" -q
             fi
        fi
    done
}
