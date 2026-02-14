#!/bin/bash

# CIDR Validation Helper
validate_cidrs() {
    # If STORAGE_CIDR is not set, nothing to validate
    if [ -z "${STORAGE_CIDR:-}" ]; then
        return 0
    fi

    log "Validating CIDR ranges..."
    
    # Use Python for reliable CIDR overlap checking
    python3 -c "
import ipaddress
import sys

def check_overlap(name1, cidr1, name2, cidr2):
    try:
        n1 = ipaddress.ip_network(cidr1)
        n2 = ipaddress.ip_network(cidr2)
        if n1.overlaps(n2):
            print(f'ERROR: {name1} ({cidr1}) overlaps with {name2} ({cidr2})')
            sys.exit(1)
    except ValueError as e:
        print(f'ERROR: Invalid CIDR format: {e}')
        sys.exit(1)

storage = '${STORAGE_CIDR}'
check_overlap('STORAGE_CIDR', storage, 'SUBNET_RANGE', '${SUBNET_RANGE}')
check_overlap('STORAGE_CIDR', storage, 'POD_CIDR', '${POD_CIDR}')
check_overlap('STORAGE_CIDR', storage, 'SERVICE_CIDR', '${SERVICE_CIDR}')
"
    if [ $? -ne 0 ]; then
        error "CIDR validation failed."
        exit 1
    fi
}

provision_networking() {
    log "Phase 2: Network Infrastructure..."
    
    validate_cidrs

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
        
        # Native Routing Check: Ensure 'pods' secondary range exists
        if [ "${CILIUM_ROUTING_MODE:-}" == "native" ]; then
             local secondary_ranges
             secondary_ranges=$(gcloud compute networks subnets describe "${SUBNET_NAME}" --region="${REGION}" --format="json(secondaryIpRanges)" --project="${PROJECT_ID}" | jq -r '.secondaryIpRanges[]?.rangeName' || echo "")
             
             if ! echo "$secondary_ranges" | grep -q "^pods$"; then
                 log "Adding 'pods' secondary range to existing subnet (Native Routing compliance)..."
                 local pod_range="${CILIUM_NATIVE_CIDR:-$POD_CIDR}"
                 run_safe gcloud compute networks subnets update "${SUBNET_NAME}" \
                     --region="${REGION}" \
                     --add-secondary-ranges="pods=${pod_range}" \
                     --project="${PROJECT_ID}"
             else
                 log "Subnet '${SUBNET_NAME}' already has 'pods' secondary range."
             fi
        fi
    else
        log "Creating Subnet '${SUBNET_NAME}'..."
        
        # Prepare Subnet Flags
        local -a SUBNET_FLAGS
        SUBNET_FLAGS=("--network=${VPC_NAME}" "--range=${SUBNET_RANGE}" "--region=${REGION}" "--project=${PROJECT_ID}")
        
        # Native Routing (Alias IPs)
        if [ "${CILIUM_ROUTING_MODE:-}" == "native" ]; then
             log "Enabling Secondary Range for Pods (Native Routing)..."
             # Use CILIUM_NATIVE_CIDR (defaults to POD_CIDR)
             local pod_range="${CILIUM_NATIVE_CIDR:-$POD_CIDR}"
             SUBNET_FLAGS+=("--secondary-range=pods=${pod_range}")
        fi

        run_safe gcloud compute networks subnets create "${SUBNET_NAME}" "${SUBNET_FLAGS[@]}"
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
            --target-tags=bastion \
            --project="${PROJECT_ID}"
    fi

    # Allow Bastion -> Cluster (API & Talos)
    # Explicit rule to ensure Bastion can talk to CP/Workers even if Internal rule is flaky
    if gcloud compute firewall-rules describe "${FW_BASTION_INTERNAL}" --project="${PROJECT_ID}" &>/dev/null; then
        log "Firewall Rule '${FW_BASTION_INTERNAL}' exists."
    else
        log "Creating Bastion->Cluster Firewall Rule..."
        run_safe gcloud compute firewall-rules create "${FW_BASTION_INTERNAL}" \
            --network="${VPC_NAME}" \
            --allow=tcp:6443,tcp:50000,tcp:50001 \
            --source-tags=bastion \
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

    # 5b. Custom Worker Ports (e.g. WebRTC)
    # Sanitize input (remove spaces to prevent gcloud errors)
    local open_tcp="${WORKER_OPEN_TCP_PORTS// /}"
    local open_udp="${WORKER_OPEN_UDP_PORTS// /}"
    local open_source_ranges="${WORKER_OPEN_SOURCE_RANGES// /}"
    
    if [ -n "$open_tcp" ] || [ -n "$open_udp" ]; then
        log "Configuring Custom Worker Firewall Rule (${FW_WORKER_CUSTOM})..."
        local allowed=""
        if [ -n "$open_tcp" ]; then allowed="tcp:${open_tcp}"; fi
        if [ -n "$open_udp" ]; then
            if [ -n "$allowed" ]; then allowed="${allowed},"; fi
            allowed="${allowed}udp:${open_udp}"
        fi
        
        if gcloud compute firewall-rules describe "${FW_WORKER_CUSTOM}" --project="${PROJECT_ID}" &>/dev/null; then
             log "Updating Custom Worker Firewall Rule..."
             run_safe gcloud compute firewall-rules update "${FW_WORKER_CUSTOM}" \
                 --project="${PROJECT_ID}" \
                 --rules="${allowed}" \
                 --source-ranges="${open_source_ranges}" \
                 --target-tags="talos-worker"
        else
             log "Creating Custom Worker Firewall Rule..."
             run_safe gcloud compute firewall-rules create "${FW_WORKER_CUSTOM}" \
                 --project="${PROJECT_ID}" \
                 --network="${VPC_NAME}" \
                 --direction=INGRESS \
                 --priority=1000 \
                 --action=ALLOW \
                 --rules="${allowed}" \
                 --source-ranges="${open_source_ranges}" \
                 --target-tags="talos-worker"
        fi
    else
        # Cleanup if no ports defined
        if gcloud compute firewall-rules describe "${FW_WORKER_CUSTOM}" --project="${PROJECT_ID}" &>/dev/null; then
            log "Removing unused Custom Worker Firewall Rule (${FW_WORKER_CUSTOM})..."
            run_safe gcloud compute firewall-rules delete "${FW_WORKER_CUSTOM}" --project="${PROJECT_ID}" -q
        fi
    fi


    # 6. Storage Network (Multi-NIC)
    if [ -n "${STORAGE_CIDR:-}" ]; then
        log "Multi-NIC: configuring Storage Network..."
        
        # Storage VPC
        if gcloud compute networks describe "${VPC_STORAGE_NAME}" --project="${PROJECT_ID}" &>/dev/null; then
            log "Storage VPC '${VPC_STORAGE_NAME}' exists."
        else
            log "Creating Storage VPC '${VPC_STORAGE_NAME}'..."
            run_safe gcloud compute networks create "${VPC_STORAGE_NAME}" \
                --subnet-mode=custom \
                --project="${PROJECT_ID}"
        fi

        # Storage Subnet
        if gcloud compute networks subnets describe "${SUBNET_STORAGE_NAME}" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
            log "Storage Subnet '${SUBNET_STORAGE_NAME}' exists."
        else
            log "Creating Storage Subnet '${SUBNET_STORAGE_NAME}'..."
            run_safe gcloud compute networks subnets create "${SUBNET_STORAGE_NAME}" \
                --network="${VPC_STORAGE_NAME}" \
                --range="${STORAGE_CIDR}" \
                --region="${REGION}" \
                --project="${PROJECT_ID}"
        fi

        # Storage Firewall (Allow Internal)
        if gcloud compute firewall-rules describe "${FW_STORAGE_INTERNAL}" --project="${PROJECT_ID}" &>/dev/null; then
            log "Storage Firewall '${FW_STORAGE_INTERNAL}' exists."
        else
            log "Creating Storage Firewall Rule..."
            run_safe gcloud compute firewall-rules create "${FW_STORAGE_INTERNAL}" \
                --network="${VPC_STORAGE_NAME}" \
                --allow=tcp,udp,icmp \
                --source-ranges="${STORAGE_CIDR}" \
                --project="${PROJECT_ID}"
        fi
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
    # We check a reasonable range above count (e.g. +10) just in case
    local prune_start=$INGRESS_IP_COUNT
    while true; do
        local ip_name="${CLUSTER_NAME}-ingress-v4-${prune_start}"
        if gcloud compute addresses describe "${ip_name}" --region "${REGION}" --project="${PROJECT_ID}" &> /dev/null; then
             log "Removing orphaned IP address '${ip_name}' (Index ${prune_start} >= Count ${INGRESS_IP_COUNT})..."
             run_safe gcloud compute addresses delete "${ip_name}" --region "${REGION}" --project="${PROJECT_ID}" -q
        else
             # If we don't find one, we assume we've cleaned them all up (contiguous assumption)
             break
        fi
        prune_start=$((prune_start+1))
    done

    # --- Step 2: Rule Reconciliation (Forwarding & Firewall) ---
    log "Reconciling Forwarding & Firewall Rules (Based on INGRESS_IPV4_CONFIG)..."
    
    # Parse Config
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
             
             # Sanitization (sort, unique)
             if [ -n "$tcp_ports" ]; then
                 tcp_ports=$(echo "${tcp_ports//,/$'\n'}" | sed '/^$/d' | sort -nu | tr '\n' ',' | sed 's/,$//')
             fi
             if [ -n "$udp_ports" ]; then
                 udp_ports=$(echo "${udp_ports//,/$'\n'}" | sed '/^$/d' | sort -nu | tr '\n' ',' | sed 's/,$//')
             fi

             # --- TCP Rule ---
             if [ -n "$tcp_ports" ]; then
                 if ! gcloud compute forwarding-rules describe "${rule_name_tcp}" --region "${REGION}" --project="${PROJECT_ID}" &> /dev/null; then
                      run_safe gcloud compute forwarding-rules create "${rule_name_tcp}" --region "${REGION}" --load-balancing-scheme=EXTERNAL --ip-protocol=TCP --ports="${tcp_ports}" --address="${ip_addr}" --backend-service="${BE_WORKER_NAME}" --project="${PROJECT_ID}"
                 else
                      local current_ports
                      current_ports=$(gcloud compute forwarding-rules describe "${rule_name_tcp}" --region "${REGION}" --project="${PROJECT_ID}" --format="value(ports)" | tr ';,' '\n' | sed '/^$/d' | sort -nu | tr '\n' ',' | sed 's/,$//')
                      if [[ "$current_ports" != "$tcp_ports" ]]; then
                          log "Updating TCP rule ${rule_name_tcp} ($current_ports -> $tcp_ports)..."
                          run_safe gcloud compute forwarding-rules delete "${rule_name_tcp}" --region "${REGION}" --project="${PROJECT_ID}" -q
                          run_safe gcloud compute forwarding-rules create "${rule_name_tcp}" --region "${REGION}" --load-balancing-scheme=EXTERNAL --ip-protocol=TCP --ports="${tcp_ports}" --address="${ip_addr}" --backend-service="${BE_WORKER_NAME}" --project="${PROJECT_ID}"
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
                      current_ports=$(gcloud compute forwarding-rules describe "${rule_name_udp}" --region "${REGION}" --project="${PROJECT_ID}" --format="value(ports)" | tr ';,' '\n' | sed '/^$/d' | sort -nu | tr '\n' ',' | sed 's/,$//')
                      if [[ "$current_ports" != "$udp_ports" ]]; then
                          log "Updating UDP rule ${rule_name_udp} ($current_ports -> $udp_ports)..."
                          run_safe gcloud compute forwarding-rules delete "${rule_name_udp}" --region "${REGION}" --project="${PROJECT_ID}" -q
                          run_safe gcloud compute forwarding-rules create "${rule_name_udp}" --region "${REGION}" --load-balancing-scheme=EXTERNAL --ip-protocol=UDP --ports="${udp_ports}" --address="${ip_addr}" --backend-service="${BE_WORKER_UDP_NAME}" --project="${PROJECT_ID}"
                      fi
                 fi
             else
                  if gcloud compute forwarding-rules describe "${rule_name_udp}" --region "${REGION}" --project="${PROJECT_ID}" &> /dev/null; then
                     run_safe gcloud compute forwarding-rules delete "${rule_name_udp}" --region "${REGION}" --project="${PROJECT_ID}" -q
                 fi
             fi
             
             # --- Firewall Rule ---
             local allowed=""
             if [ -n "$tcp_ports" ]; then allowed="tcp:${tcp_ports}"; fi
             if [ -n "$udp_ports" ]; then 
                if [ -n "$allowed" ]; then allowed="${allowed},"; fi
                allowed="${allowed}udp:${udp_ports}"
             fi
             
             if [ -n "$allowed" ]; then
                 if ! gcloud compute firewall-rules describe "${fw_name}" --project="${PROJECT_ID}" &> /dev/null; then
                     run_safe gcloud compute firewall-rules create "${fw_name}" --project="${PROJECT_ID}" --network="${VPC_NAME}" --direction=INGRESS --priority=1000 --action=ALLOW --rules="${allowed}" --source-ranges="0.0.0.0/0" --target-tags="talos-worker"
                 else
                     # Update existing rule, enforcing all properties to ensure consistency
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
    local prune_start=$INGRESS_IP_COUNT
    while true; do
        local rule_name_tcp="${CLUSTER_NAME}-ingress-v4-rule-${prune_start}-tcp"
        local rule_name_udp="${CLUSTER_NAME}-ingress-v4-rule-${prune_start}-udp"
        local rule_name_legacy="${CLUSTER_NAME}-ingress-v4-rule-${prune_start}"
        local fw_name="${FW_INGRESS_BASE}-v4-${prune_start}"
        
        local found=false
        
        if gcloud compute forwarding-rules describe "${rule_name_tcp}" --region "${REGION}" --project="${PROJECT_ID}" &> /dev/null; then
             run_safe gcloud compute forwarding-rules delete "${rule_name_tcp}" --region "${REGION}" --project="${PROJECT_ID}" -q
             found=true
        fi
        if gcloud compute forwarding-rules describe "${rule_name_udp}" --region "${REGION}" --project="${PROJECT_ID}" &> /dev/null; then
             run_safe gcloud compute forwarding-rules delete "${rule_name_udp}" --region "${REGION}" --project="${PROJECT_ID}" -q
             found=true
        fi
        if gcloud compute forwarding-rules describe "${rule_name_legacy}" --region "${REGION}" --project="${PROJECT_ID}" &> /dev/null; then
             run_safe gcloud compute forwarding-rules delete "${rule_name_legacy}" --region "${REGION}" --project="${PROJECT_ID}" -q
             found=true
        fi
        if gcloud compute firewall-rules describe "${fw_name}" --project="${PROJECT_ID}" &> /dev/null; then
             run_safe gcloud compute firewall-rules delete "${fw_name}" --project="${PROJECT_ID}" -q
             found=true
        fi
        
        if [ "$found" = false ]; then
            break
        fi
        prune_start=$((prune_start+1))
    done
}
