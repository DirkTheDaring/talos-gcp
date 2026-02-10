#!/bin/bash

phase2_networking() {
    log "Phase 2a: Network Infrastructure..."

    # 1. VPC
    if gcloud compute networks describe "${VPC_NAME}" --project="${PROJECT_ID}" &>/dev/null; then
        log "VPC '${VPC_NAME}' exists."
    else
        log "Creating VPC '${VPC_NAME}'..."
        run_safe gcloud compute networks create "${VPC_NAME}" \
            --subnet-mode=custom \
            --project="${PROJECT_ID}"
    fi

    # 2. Subnet
    if gcloud compute networks subnets describe "${SUBNET_NAME}" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
        log "Subnet '${SUBNET_NAME}' exists."
    else
        log "Creating Subnet '${SUBNET_NAME}'..."
        run_safe gcloud compute networks subnets create "${SUBNET_NAME}" \
            --network="${VPC_NAME}" \
            --range="${SUBNET_RANGE}" \
            --region="${REGION}" \
            --project="${PROJECT_ID}"
    fi

    # 3. Router
    if gcloud compute routers describe "${ROUTER_NAME}" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
        log "Router '${ROUTER_NAME}' exists."
    else
        log "Creating Router '${ROUTER_NAME}'..."
        run_safe gcloud compute routers create "${ROUTER_NAME}" \
            --network="${VPC_NAME}" \
            --region="${REGION}" \
            --project="${PROJECT_ID}"
    fi

    # 4. NAT
    if gcloud compute routers nats describe "${NAT_NAME}" --router="${ROUTER_NAME}" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
        log "NAT '${NAT_NAME}' exists."
    else
        log "Creating Cloud NAT '${NAT_NAME}'..."
        run_safe gcloud compute routers nats create "${NAT_NAME}" \
            --router="${ROUTER_NAME}" \
            --region="${REGION}" \
            --auto-allocate-nat-external-ips \
            --nat-all-subnet-ip-ranges \
            --project="${PROJECT_ID}"
    fi

    # 5. Firewall Rules
    # Allow Internal Traffic
    if gcloud compute firewall-rules describe "${FW_INTERNAL}" --project="${PROJECT_ID}" &>/dev/null; then
        log "Firewall Rule '${FW_INTERNAL}' exists."
    else
        log "Creating Internal Firewall Rule..."
        run_safe gcloud compute firewall-rules create "${FW_INTERNAL}" \
            --network="${VPC_NAME}" \
            --allow=tcp,udp,icmp \
            --source-ranges="${SUBNET_RANGE},${POD_CIDR},${SERVICE_CIDR}" \
            --project="${PROJECT_ID}"
    fi

    # Allow IAP/SSH for Bastion
    if gcloud compute firewall-rules describe "${FW_BASTION}" --project="${PROJECT_ID}" &>/dev/null; then
        log "Firewall Rule '${FW_BASTION}' exists."
    else
        log "Creating Bastion SSH Firewall Rule..."
        run_safe gcloud compute firewall-rules create "${FW_BASTION}" \
            --network="${VPC_NAME}" \
            --allow=tcp:22 \
            --source-ranges=35.235.240.0/20 \
            --target-tags=bastion \
            --project="${PROJECT_ID}"
    fi

    # Allow Health Checks
    if gcloud compute firewall-rules describe "${FW_HEALTH}" --project="${PROJECT_ID}" &>/dev/null; then
        log "Firewall Rule '${FW_HEALTH}' exists."
    else
        log "Creating Health Check Firewall Rule..."
        run_safe gcloud compute firewall-rules create "${FW_HEALTH}" \
            --network="${VPC_NAME}" \
            --allow=tcp:6443,tcp:50000,tcp:50001 \
            --source-ranges=35.191.0.0/16,130.211.0.0/22 \
            --project="${PROJECT_ID}"
    fi
}

ensure_backends() {
    # 1. TCP Backend Service
    if ! gcloud compute health-checks describe "${HC_WORKER_NAME}" --region "${REGION}" --project="${PROJECT_ID}" &> /dev/null; then
        run_safe gcloud compute health-checks create tcp "${HC_WORKER_NAME}" --region "${REGION}" --port 80 --project="${PROJECT_ID}"
    fi
     if ! gcloud compute backend-services describe "${BE_WORKER_NAME}" --region "${REGION}" --project="${PROJECT_ID}" &> /dev/null; then
        run_safe gcloud compute backend-services create "${BE_WORKER_NAME}" --region "${REGION}" --load-balancing-scheme=EXTERNAL --protocol=TCP --health-checks-region="${REGION}" --health-checks="${HC_WORKER_NAME}" --project="${PROJECT_ID}"
    fi
    if ! gcloud compute backend-services describe "${BE_WORKER_NAME}" --region "${REGION}" --project="${PROJECT_ID}" | grep -q "group: .*${IG_WORKER_NAME}"; then
         run_safe gcloud compute backend-services add-backend "${BE_WORKER_NAME}" --region "${REGION}" --instance-group "${IG_WORKER_NAME}" --instance-group-zone "${ZONE}" --project="${PROJECT_ID}" || true
    fi

    # 2. UDP Backend Service
    if ! gcloud compute health-checks describe "${HC_WORKER_UDP_NAME}" --region "${REGION}" --project="${PROJECT_ID}" &> /dev/null; then
        # Note: We create a TCP health check for the UDP backend.
        # This assumes your UDP service (or Ingress Controller) also exposes a TCP port (e.g. 80) for health checking.
        # Pure UDP services without a TCP sidecar might fail this check.
        run_safe gcloud compute health-checks create tcp "${HC_WORKER_UDP_NAME}" --region "${REGION}" --port 80 --project="${PROJECT_ID}"
    fi
     if ! gcloud compute backend-services describe "${BE_WORKER_UDP_NAME}" --region "${REGION}" --project="${PROJECT_ID}" &> /dev/null; then
        run_safe gcloud compute backend-services create "${BE_WORKER_UDP_NAME}" --region "${REGION}" --load-balancing-scheme=EXTERNAL --protocol=UDP --health-checks-region="${REGION}" --health-checks="${HC_WORKER_UDP_NAME}" --project="${PROJECT_ID}"
    fi
    if ! gcloud compute backend-services describe "${BE_WORKER_UDP_NAME}" --region "${REGION}" --project="${PROJECT_ID}" | grep -q "group: .*${IG_WORKER_NAME}"; then
         run_safe gcloud compute backend-services add-backend "${BE_WORKER_UDP_NAME}" --region "${REGION}" --instance-group "${IG_WORKER_NAME}" --instance-group-zone "${ZONE}" --project="${PROJECT_ID}" || true
    fi
}


apply_ingress() {
    log "Applying Ingress Configuration (TCP/UDP)..."
    ensure_backends
    
    IFS=';' read -ra ADDR <<< "$INGRESS_IPV4_CONFIG"
    local idx=0
    for group_config in "${ADDR[@]}"; do
         local ip_name="${CLUSTER_NAME}-ingress-v4-${idx}"
         
         log "Configuring Ingress IPv4 Group $idx: Config=[$group_config]..."
         
         # 1. Reserve/Get IP
         if ! gcloud compute addresses describe "${ip_name}" --region "${REGION}" --project="${PROJECT_ID}" &> /dev/null; then
             run_safe gcloud compute addresses create "${ip_name}" --region "${REGION}" --project="${PROJECT_ID}"
         fi
         local ip_addr=$(gcloud compute addresses describe "${ip_name}" --region "${REGION}" --format="value(address)" --project="${PROJECT_ID}")
         log "  -> IP Allocated: ${ip_addr}"
         
         # 2. Parse Ports (TCP vs UDP)
         local tcp_ports=""
         local udp_ports=""
         
         IFS=',' read -ra ITEMS <<< "$group_config"
         for item in "${ITEMS[@]}"; do
             if [[ "$item" == */udp ]]; then
                 # UDP Only: "53/udp" -> UDP:53
                 local port=${item%/udp}
                 udp_ports="${udp_ports},${port}"
             elif [[ "$item" == */tcp ]]; then
                 # TCP Only: "80/tcp" -> TCP:80
                 local port=${item%/tcp}
                 tcp_ports="${tcp_ports},${port}"
             else
                 # Default: "80" -> TCP:80 AND UDP:80 (Both)
                 local port="$item"
                 tcp_ports="${tcp_ports},${port}"
                 udp_ports="${udp_ports},${port}"
             fi
         done
         
         # Deduplicate & Sort (Robust Logic)
         if [ -n "$tcp_ports" ]; then
             # Replace commas with newlines, sort unique numeric, join with commas
             # handle potentially empty elements from leading/trailing commas
             tcp_ports=$(echo "${tcp_ports//,/$'\n'}" | sed '/^$/d' | sort -nu | tr '\n' ',' | sed 's/,$//')
         fi
         if [ -n "$udp_ports" ]; then
             udp_ports=$(echo "${udp_ports//,/$'\n'}" | sed '/^$/d' | sort -nu | tr '\n' ',' | sed 's/,$//')
         fi
         
         # 3. Apply TCP Forwarding Rule
         # Cleanup legacy rule (without -tcp suffix) if exists
         local rule_name_legacy="${CLUSTER_NAME}-ingress-v4-rule-${idx}"
         if gcloud compute forwarding-rules describe "${rule_name_legacy}" --region "${REGION}" --project="${PROJECT_ID}" &> /dev/null; then
             log "Removing legacy forwarding rule ${rule_name_legacy}..."
             run_safe gcloud compute forwarding-rules delete "${rule_name_legacy}" --region "${REGION}" --project="${PROJECT_ID}" -q
         fi

         local rule_name_tcp="${CLUSTER_NAME}-ingress-v4-rule-${idx}-tcp"
         if [ -n "$tcp_ports" ]; then
             if ! gcloud compute forwarding-rules describe "${rule_name_tcp}" --region "${REGION}" --project="${PROJECT_ID}" &> /dev/null; then
                  # Create
                  run_safe gcloud compute forwarding-rules create "${rule_name_tcp}" --region "${REGION}" --load-balancing-scheme=EXTERNAL --ip-protocol=TCP --ports="${tcp_ports}" --address="${ip_addr}" --backend-service="${BE_WORKER_NAME}" --project="${PROJECT_ID}"
             else
                  # Optimization: Check if ports match
                  local current_ports
                  # Get ports, replace commas/semicolons with newlines, sort numeric unique, join with comma
                  current_ports=$(gcloud compute forwarding-rules describe "${rule_name_tcp}" --region "${REGION}" --project="${PROJECT_ID}" --format="value(ports)" | tr ';,' '\n' | sed '/^$/d' | sort -nu | tr '\n' ',' | sed 's/,$//')
                  
                  if [[ "$current_ports" == "$tcp_ports" ]]; then
                      log "TCP rule ${rule_name_tcp} is up to date."
                  else
                      log "Updating TCP rule ${rule_name_tcp} (Ports: $current_ports -> $tcp_ports)..."
                      run_safe gcloud compute forwarding-rules delete "${rule_name_tcp}" --region "${REGION}" --project="${PROJECT_ID}" -q
                      run_safe gcloud compute forwarding-rules create "${rule_name_tcp}" --region "${REGION}" --load-balancing-scheme=EXTERNAL --ip-protocol=TCP --ports="${tcp_ports}" --address="${ip_addr}" --backend-service="${BE_WORKER_NAME}" --project="${PROJECT_ID}"
                  fi
             fi
         else
             # Cleanup if empty
             if gcloud compute forwarding-rules describe "${rule_name_tcp}" --region "${REGION}" --project="${PROJECT_ID}" &> /dev/null; then
                 log "Removing unused TCP rule ${rule_name_tcp}..."
                 run_safe gcloud compute forwarding-rules delete "${rule_name_tcp}" --region "${REGION}" --project="${PROJECT_ID}" -q
             fi
         fi
         
         # 4. Apply UDP Forwarding Rule
         local rule_name_udp="${CLUSTER_NAME}-ingress-v4-rule-${idx}-udp"
         if [ -n "$udp_ports" ]; then
             if ! gcloud compute forwarding-rules describe "${rule_name_udp}" --region "${REGION}" --project="${PROJECT_ID}" &> /dev/null; then
                  run_safe gcloud compute forwarding-rules create "${rule_name_udp}" --region "${REGION}" --load-balancing-scheme=EXTERNAL --ip-protocol=UDP --ports="${udp_ports}" --address="${ip_addr}" --backend-service="${BE_WORKER_UDP_NAME}" --project="${PROJECT_ID}"
             else
                  local current_ports
                  # Get ports, sort numeric unique, join with comma
                  current_ports=$(gcloud compute forwarding-rules describe "${rule_name_udp}" --region "${REGION}" --project="${PROJECT_ID}" --format="value(ports)" | tr ';,' '\n' | sed '/^$/d' | sort -nu | tr '\n' ',' | sed 's/,$//')
                  
                  if [[ "$current_ports" == "$udp_ports" ]]; then
                      log "UDP rule ${rule_name_udp} is up to date."
                  else
                      log "Updating UDP rule ${rule_name_udp} (Ports: $current_ports -> $udp_ports)..."
                      run_safe gcloud compute forwarding-rules delete "${rule_name_udp}" --region "${REGION}" --project="${PROJECT_ID}" -q
                      run_safe gcloud compute forwarding-rules create "${rule_name_udp}" --region "${REGION}" --load-balancing-scheme=EXTERNAL --ip-protocol=UDP --ports="${udp_ports}" --address="${ip_addr}" --backend-service="${BE_WORKER_UDP_NAME}" --project="${PROJECT_ID}"
                  fi
             fi
         else
             # Cleanup if empty
             if gcloud compute forwarding-rules describe "${rule_name_udp}" --region "${REGION}" --project="${PROJECT_ID}" &> /dev/null; then
                 log "Removing unused UDP rule ${rule_name_udp}..."
                 run_safe gcloud compute forwarding-rules delete "${rule_name_udp}" --region "${REGION}" --project="${PROJECT_ID}" -q
             fi
         fi
         
         # 5. Apply Firewall Rule (Combined)
         local fw_name="${FW_INGRESS_BASE}-v4-${idx}"
         local allowed=""
         if [ -n "$tcp_ports" ]; then allowed="tcp:${tcp_ports//,/,tcp:}"; fi
         if [ -n "$udp_ports" ]; then 
            if [ -n "$allowed" ]; then allowed="${allowed},"; fi
            allowed="${allowed}udp:${udp_ports//,/,udp:}"
         fi

         # Update or Create Firewall
         if [ -n "$allowed" ]; then
             if ! gcloud compute firewall-rules describe "${fw_name}" --project="${PROJECT_ID}" &> /dev/null; then
                 run_safe gcloud compute firewall-rules create "${fw_name}" --project="${PROJECT_ID}" --network="${VPC_NAME}" --direction=INGRESS --priority=1000 --action=ALLOW --rules="${allowed}" --source-ranges="0.0.0.0/0" --target-tags="talos-worker"
             else
                 # Update existing rule to match config
                 run_safe gcloud compute firewall-rules update "${fw_name}" --project="${PROJECT_ID}" --rules="${allowed}"
             fi
         else
             # Cleanup if empty
             if gcloud compute firewall-rules describe "${fw_name}" --project="${PROJECT_ID}" &> /dev/null; then
                 log "Removing unused Firewall rule ${fw_name}..."
                 run_safe gcloud compute firewall-rules delete "${fw_name}" --project="${PROJECT_ID}" -q
             fi
         fi
         
         
         idx=$((idx+1))
    done

    # Cleanup Orphaned Groups (if config shrank)
    # Check for higher indices and remove resources
    while true; do
        local ip_name="${CLUSTER_NAME}-ingress-v4-${idx}"
        local rule_name_tcp="${CLUSTER_NAME}-ingress-v4-rule-${idx}-tcp"
        local rule_name_udp="${CLUSTER_NAME}-ingress-v4-rule-${idx}-udp"
        local rule_name_legacy="${CLUSTER_NAME}-ingress-v4-rule-${idx}"
        local fw_name="${FW_INGRESS_BASE}-v4-${idx}"
        
        # Heuristic: Check if IP exists. If not, assume end of sequence.
        # But safer to check ALL resources just in case.
        local found=false
        
        if gcloud compute forwarding-rules describe "${rule_name_tcp}" --region "${REGION}" --project="${PROJECT_ID}" &> /dev/null; then
             log "Removing orphaned TCP rule ${rule_name_tcp}..."
             run_safe gcloud compute forwarding-rules delete "${rule_name_tcp}" --region "${REGION}" --project="${PROJECT_ID}" -q
             found=true
        fi
        if gcloud compute forwarding-rules describe "${rule_name_legacy}" --region "${REGION}" --project="${PROJECT_ID}" &> /dev/null; then
             log "Removing orphaned legacy rule ${rule_name_legacy}..."
             run_safe gcloud compute forwarding-rules delete "${rule_name_legacy}" --region "${REGION}" --project="${PROJECT_ID}" -q
             found=true
        fi
        if gcloud compute forwarding-rules describe "${rule_name_udp}" --region "${REGION}" --project="${PROJECT_ID}" &> /dev/null; then
             log "Removing orphaned UDP rule ${rule_name_udp}..."
             run_safe gcloud compute forwarding-rules delete "${rule_name_udp}" --region "${REGION}" --project="${PROJECT_ID}" -q
             found=true
        fi
        if gcloud compute firewall-rules describe "${fw_name}" --project="${PROJECT_ID}" &> /dev/null; then
             log "Removing orphaned Firewall rule ${fw_name}..."
             run_safe gcloud compute firewall-rules delete "${fw_name}" --project="${PROJECT_ID}" -q
             found=true
        fi
        if gcloud compute addresses describe "${ip_name}" --region "${REGION}" --project="${PROJECT_ID}" &> /dev/null; then
             log "Removing orphaned IP address ${ip_name}..."
             run_safe gcloud compute addresses delete "${ip_name}" --region "${REGION}" --project="${PROJECT_ID}" -q
             found=true
        fi
        
        if [ "$found" = false ]; then
            break
        fi
        
        idx=$((idx+1))
    done
}
