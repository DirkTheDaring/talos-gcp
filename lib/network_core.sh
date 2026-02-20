#!/bin/bash

# CIDR Validation Helper
validate_cidrs() {
    # If STORAGE_CIDR is not set, nothing to validate
    if [ -z "${STORAGE_CIDR:-}" ]; then
        return 0
    fi

    log "Validating CIDR ranges..."
    
    # Use Python for reliable CIDR overlap checking
    "${PYTHON_CMD}" -c "
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
        log "Firewall Rule '${FW_INTERNAL}' exists. Updating..."
        run_safe gcloud compute firewall-rules update "${FW_INTERNAL}" \
            --allow=tcp,udp,icmp \
            --source-ranges="${SUBNET_RANGE},${POD_CIDR},${SERVICE_CIDR}" \
            --project="${PROJECT_ID}"
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
        log "Firewall Rule '${FW_BASTION}' exists. Updating..."
        run_safe gcloud compute firewall-rules update "${FW_BASTION}" \
            --allow=tcp:22 \
            --source-ranges=35.235.240.0/20 \
            --target-tags=bastion \
            --project="${PROJECT_ID}"
    else
        log "Creating Bastion SSH Firewall Rule..."
        run_safe gcloud compute firewall-rules create "${FW_BASTION}" \
            --network="${VPC_NAME}" \
            --allow=tcp:22 \
            --source-ranges=35.235.240.0/20 \
            --target-tags=bastion \
            --project="${PROJECT_ID}"
    fi

    # Allow Bastion -> Cluster (API & Talos)
    # Explicit rule to ensure Bastion can talk to CP/Workers even if Internal rule is flaky
    if gcloud compute firewall-rules describe "${FW_BASTION_INTERNAL}" --project="${PROJECT_ID}" &>/dev/null; then
        log "Firewall Rule '${FW_BASTION_INTERNAL}' exists. Ensuring correct ports..."
        run_safe gcloud compute firewall-rules update "${FW_BASTION_INTERNAL}" \
            --allow=tcp:6443,tcp:50000,tcp:50001 \
            --source-tags=bastion \
            --project="${PROJECT_ID}"
    else
        log "Creating Bastion->Cluster Firewall Rule..."
        run_safe gcloud compute firewall-rules create "${FW_BASTION_INTERNAL}" \
            --network="${VPC_NAME}" \
            --allow=tcp:6443,tcp:50000,tcp:50001 \
            --source-tags=bastion \
            --project="${PROJECT_ID}"
    fi


    # Allow Health Checks
    # Sanitize input (remove spaces)
    local ranges_sanitized="${HC_SOURCE_RANGES// /}"
    if gcloud compute firewall-rules describe "${FW_HEALTH}" --project="${PROJECT_ID}" &>/dev/null; then
        log "Firewall Rule '${FW_HEALTH}' exists. Ensuring correct ports..."
        run_safe gcloud compute firewall-rules update "${FW_HEALTH}" \
            --allow=tcp:6443,tcp:50000,tcp:50001 \
            --source-ranges="${ranges_sanitized}" \
            --project="${PROJECT_ID}"
    else
        log "Creating Health Check Firewall Rule..."
        run_safe gcloud compute firewall-rules create "${FW_HEALTH}" \
            --network="${VPC_NAME}" \
            --allow=tcp:6443,tcp:50000,tcp:50001 \
            --source-ranges="${ranges_sanitized}" \
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
        if [ -n "$open_tcp" ]; then
            # Split by comma and prepend tcp:
            IFS=',' read -ra TCP_PORTS <<< "$open_tcp"
            for port in "${TCP_PORTS[@]}"; do
                if [ -n "$allowed" ]; then allowed="${allowed},"; fi
                allowed="${allowed}tcp:${port}"
            done
        fi
        if [ -n "$open_udp" ]; then
             IFS=',' read -ra UDP_PORTS <<< "$open_udp"
             for port in "${UDP_PORTS[@]}"; do
                if [ -n "$allowed" ]; then allowed="${allowed},"; fi
                allowed="${allowed}udp:${port}"
            done
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
            log "Storage Firewall '${FW_STORAGE_INTERNAL}' exists. Updating..."
            run_safe gcloud compute firewall-rules update "${FW_STORAGE_INTERNAL}" \
                --allow=tcp,udp,icmp \
                --source-ranges="${STORAGE_CIDR}" \
                --project="${PROJECT_ID}"
        else
            log "Creating Storage Firewall Rule..."
            run_safe gcloud compute firewall-rules create "${FW_STORAGE_INTERNAL}" \
                --network="${VPC_STORAGE_NAME}" \
                --allow=tcp,udp,icmp \
                --source-ranges="${STORAGE_CIDR}" \
                --project="${PROJECT_ID}"
        fi
    fi
    


    # 8. Ingress Resources (IPs, Backends, Forwarding Rules)
    apply_ingress
}
