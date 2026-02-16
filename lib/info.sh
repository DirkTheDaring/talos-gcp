#!/bin/bash

list_clusters() {
    log "Scanning project ${PROJECT_ID} for Talos clusters..."

    # 1. Get Unique Cluster Names
    # Filter by instances having the talos-version label (indicates new structure)
    # OR we can fallback to just cluster label for broader discovery.
    # Using 'labels.cluster:*' covers both.
    local CLUSTER_NAMES
    CLUSTER_NAMES=$(gcloud compute instances list \
        --filter="labels.cluster:*" \
        --format="value(labels.cluster)" \
        --project="${PROJECT_ID}" | sort | uniq)
    
    if [ -z "$CLUSTER_NAMES" ]; then
        echo "No Talos clusters found in project ${PROJECT_ID}."
        return
    fi
    
    # 2. Print Header
    printf "%-30s %-15s %-15s %-15s %-15s %-20s %-20s\n" "CLUSTER NAME" "ZONE" "TALOS VERSION" "K8S VERSION" "CILIUM VERSION" "PUBLIC IP" "BASTION IP"

    
    for cluster in $CLUSTER_NAMES; do
        # Get Version Info (Take first instance's version)
        local VER_INFO
        VER_INFO=$(gcloud compute instances list --filter="labels.cluster=${cluster} AND labels.talos-version:*" --limit=1 --format="value(zone.basename(), labels.talos-version, labels.k8s-version, labels.cilium-version)" --project="${PROJECT_ID}")
        
        # Read into variables (tab separated by default gcloud value format? distinct args?)
        # value(a,b) output is tab-separated.
        local CLUSTER_ZONE
        local TALOS_VER
        local K8S_VER
        local CILIUM_VER
        read -r CLUSTER_ZONE TALOS_VER K8S_VER CILIUM_VER <<< "$VER_INFO"
        
        # Restore versions (hyphen to dot)
        TALOS_VER="${TALOS_VER//-/.}"
        K8S_VER="${K8S_VER//-/.}"
        CILIUM_VER="${CILIUM_VER//-/.}"
        
        if [ -z "$TALOS_VER" ]; then TALOS_VER="unknown"; fi
        if [ -z "$K8S_VER" ]; then K8S_VER="unknown"; fi
        if [ -z "$CILIUM_VER" ]; then CILIUM_VER="unknown"; fi
        
        # Determine Region
        local CLUSTER_REGION="${CLUSTER_ZONE%-*}"

        # Get Public IP
        # 1. Try to fetch the Reserved Static IP (Preferred for CCM/Traefik)
        local IP=""
        local IP_NAME="${cluster}-ingress-v4-0"
        
        if gcloud compute addresses describe "${IP_NAME}" --region "${CLUSTER_REGION}" --project="${PROJECT_ID}" &> /dev/null; then
             IP=$(gcloud compute addresses describe "${IP_NAME}" --region "${CLUSTER_REGION}" --format="value(address)" --project="${PROJECT_ID}")
        fi
        
        # 2. Fallback: Check for Manual Forwarding Rules (Legacy / HostPort)
        if [ -z "$IP" ]; then
             IP=$(gcloud compute forwarding-rules list --filter="name~'^${cluster}-ingress.*'" --limit=1 --format="value(IPAddress)" --project="${PROJECT_ID}" 2>/dev/null || echo "")
        fi

        if [ -z "$IP" ]; then IP="Pending/None"; fi

        # Get Bastion IP (Internal preferred for IAP)
        local BASTION_IPS
        BASTION_IPS=$(gcloud compute instances list --filter="name=${cluster}-bastion" --limit=1 --format="value(networkInterfaces[0].networkIP,networkInterfaces[0].accessConfigs[0].natIP)" --project="${PROJECT_ID}" 2>/dev/null)
        local BASTION_INT BASTION_EXT
        read -r BASTION_INT BASTION_EXT <<< "$BASTION_IPS"
        
        local BASTION_DISPLAY="${BASTION_INT:-$BASTION_EXT}"
        if [ -z "$BASTION_DISPLAY" ]; then BASTION_DISPLAY="None"; fi
        
        printf "%-30s %-15s %-15s %-15s %-15s %-20s %-20s\n" "$cluster" "$CLUSTER_ZONE" "$TALOS_VER" "$K8S_VER" "$CILIUM_VER" "$IP" "$BASTION_DISPLAY"
    done
    echo ""
}

list_instances() {
    log "Listing instances for cluster '${CLUSTER_NAME}' (Project: ${PROJECT_ID})..."
    
    # List Instances with custom columns
    # NAME, ZONE, MACHINE_TYPE, INTERNAL_IP, EXTERNAL_IP, STATUS
    # We capture output to check for emptiness without a second call.
    local OUTPUT
    OUTPUT=$(gcloud compute instances list \
        --filter="labels.cluster=${CLUSTER_NAME}" \
        --project="${PROJECT_ID}" \
        --sort-by=name \
        --format="table(name, zone.basename(), machineType.basename(), networkInterfaces[0].networkIP:label=INTERNAL_IP, networkInterfaces[0].accessConfigs[0].natIP:label=EXTERNAL_IP, status)")

    if [ -z "$OUTPUT" ]; then
        warn "No instances found for cluster '${CLUSTER_NAME}'."
    else
        echo "$OUTPUT"
    fi
    echo ""
}

list_ports() {
    set_names
    
    # Check for required tools
    for cmd in jq column; do
        if ! command -v "$cmd" &> /dev/null; then
            error "Command '$cmd' is required for list-ports but not installed."
            return 1
        fi
    done

    log "Listing Public Forwarding Rules (Ports) for cluster '${CLUSTER_NAME}' (Project: ${PROJECT_ID})..."
    
    # Check if any rules exist first to avoid empty table headers
    if ! gcloud compute forwarding-rules list --filter="name:${CLUSTER_NAME}*" --project="${PROJECT_ID}" --limit=1 &> /dev/null; then
            warn "No forwarding rules found matching '${CLUSTER_NAME}*'."
            return
    fi
        
    # Fetch JSON and process with jq to flatten ports
    # We normalize 'ports' (list) and 'portRange' (string) into a single stream of rows
    gcloud compute forwarding-rules list \
        --filter="name:${CLUSTER_NAME}*" \
        --project="${PROJECT_ID}" \
        --format="json" | \
    jq -r '
        ["NAME", "REGION", "IP_ADDRESS", "PROTOCOL", "PORT", "TARGET"],
        (.[] | 
            # Determine Region basename or Global
            (.region | if . then (split("/") | last) else "global" end) as $region |
            # Determine Target basename
            (.target | if . then (split("/") | last) else "-" end) as $target |
            # Handle ports (list) vs portRange (string)
            # If ports exists and not empty, iterate. Else use portRange or "-" as single item.
            ((.ports | if . == null or length == 0 then null else . end) // [.portRange // "-"])[] as $port |
            [.name, $region, .IPAddress, .IPProtocol, $port, $target]
        ) | @tsv' | \
    column -t
        
    echo ""
}

get_ips() {
    set_names
    check_dependencies
    
    log "Retrieving Public IPs for cluster '${CLUSTER_NAME}' (Project: ${PROJECT_ID}, Region: ${REGION})..."
    echo ""
    
    # Initialize Table Data
    # Format: TYPE | NAME | IP_ADDRESS | DESCRIPTION
    local TABLE_DATA="TYPE\tNAME\tIP_ADDRESS\tDESCRIPTION\n"
    
    # 1. Ingress IPs (Forwarding Rules)
    log "  -> Fetching Ingress IPs..."
    local INGRESS_IPS
    INGRESS_IPS=$(gcloud compute addresses list \
        --filter="name~'${CLUSTER_NAME}-ingress.*' AND region:(${REGION})" \
        --project="${PROJECT_ID}" \
        --format="value(name, address)")
        
    if [ -n "$INGRESS_IPS" ]; then
        while read -r name ip; do
            TABLE_DATA+="${GREEN}Ingress${NC}\t${name}\t${ip}\tLoadBalancer IP\n"
        done <<< "$INGRESS_IPS"
    else
         TABLE_DATA+="${YELLOW}Ingress${NC}\t-\t-\tNo Ingress IPs found\n"
    fi

    # 2. Bastion IP
    log "  -> Fetching Bastion IP..."
    local BASTION_INFO
    BASTION_INFO=$(gcloud compute instances describe "${CLUSTER_NAME}-bastion" \
        --zone "${ZONE}" \
        --project="${PROJECT_ID}" \
        --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null)
        
    if [ -n "$BASTION_INFO" ]; then
        TABLE_DATA+="${GREEN}Bastion${NC}\t${CLUSTER_NAME}-bastion\t${BASTION_INFO}\tSSH Jump Host\n"
    else
        TABLE_DATA+="${YELLOW}Bastion${NC}\t${CLUSTER_NAME}-bastion\t-\tNo External IP / Instance not found\n"
    fi
     
    # 3. Cloud NAT IPs
    log "  -> Fetching Cloud NAT IPs..."
    # First, find the router. Usually named ${CLUSTER_NAME}-router
    local ROUTER_NAME="${CLUSTER_NAME}-router"
    
    # Check if router exists
    if gcloud compute routers describe "${ROUTER_NAME}" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
        # Get NAT Status
        local NAT_IPS
        NAT_IPS=$(gcloud compute routers get-status "${ROUTER_NAME}" \
            --region="${REGION}" \
            --project="${PROJECT_ID}" \
            --format="value(result.natStatus[].autoAllocatedNatIps, result.natStatus[].userAllocatedNatIps)" 2>/dev/null)
            
        # Clean up output (gcloud returns list as semicolon or comma separated depending on version/format)
        # We replace delimiters with spaces
        NAT_IPS=$(echo "$NAT_IPS" | tr ';,' ' ')
        
        if [ -n "$NAT_IPS" ]; then
            for ip in $NAT_IPS; do
                TABLE_DATA+="${GREEN}Cloud NAT${NC}\t${ROUTER_NAME}\t${ip}\tOutbound Traffic IP\n"
            done
        else
             TABLE_DATA+="${YELLOW}Cloud NAT${NC}\t${ROUTER_NAME}\t-\tNo Active NAT IPs found\n"
        fi
    else
        TABLE_DATA+="${YELLOW}Cloud NAT${NC}\t-\t-\tRouter '${ROUTER_NAME}' not found\n"
    fi

    echo ""
    # Print Table using column
    echo -e "$TABLE_DATA" | column -t -s $'\t'
    echo ""
}

status() {
    set_names
    
    # Check for required tools
    for cmd in jq; do
        if ! command -v "$cmd" &> /dev/null; then
            error "Command '$cmd' is required for status but not installed."
            return 1
        fi
    done

    # 1. Fetch Resource Policies (Schedules) - Global
    # We use this to map Cluster -> Schedule
    local POLICY_JSON
    # Use || echo "[]" to handle permissions/empty states
    POLICY_JSON=$(gcloud compute resource-policies list --project="${PROJECT_ID}" --filter="name~'-schedule$'" --format="json(name,instanceSchedulePolicy)" 2>/dev/null || echo "[]")

    declare -A SCHEDULE_MAP
    if [ "$POLICY_JSON" != "[]" ]; then
        # Parse JSON into Bash Map
        while IFS=$'\t' read -r pol_name start_cron stop_cron tz; do
             # Derive Cluster Name (remove -schedule suffix)
             local cluster="${pol_name%-schedule}"
             
             # Simple Cron Parsing (Min Hour ...)
             # e.g., "0 8 * * 1-5" -> mm=0, hh=8
             local start_mm start_hh extra_start
             local stop_mm stop_hh extra_stop
             
             read -r start_mm start_hh extra_start <<< "$start_cron"
             read -r stop_mm stop_hh extra_stop <<< "$stop_cron"
             
             # Format time with leading zeros if needed (printf)
             local fmt_start fmt_stop
             printf -v fmt_start "%02d:%02d" "$start_hh" "$start_mm" 2>/dev/null || fmt_start="$start_hh:$start_mm"
             printf -v fmt_stop "%02d:%02d" "$stop_hh" "$stop_mm" 2>/dev/null || fmt_stop="$stop_hh:$stop_mm"
             
             SCHEDULE_MAP["$cluster"]="${fmt_start}-${fmt_stop}"
        done < <(echo "$POLICY_JSON" | jq -r '.[] | [.name, .instanceSchedulePolicy.vmStartSchedule.schedule, .instanceSchedulePolicy.vmStopSchedule.schedule, .instanceSchedulePolicy.timeZone] | @tsv')
    fi

    # 2. Fetch Instance Data (Global Scan)
    # Get details for ALL Talos clusters in the project
    local INSTANCE_DATA
    # Use || echo "[]" to prevent set -e from killing the script if gcloud returns non-zero
    INSTANCE_DATA=$(gcloud compute instances list \
        --filter="labels.cluster:*" \
        --project="${PROJECT_ID}" \
        --format="json(name, status, lastStartTimestamp, lastStopTimestamp, labels.cluster)" 2>/dev/null || echo "[]")
    
    if [ -z "$INSTANCE_DATA" ] || [ "$INSTANCE_DATA" == "[]" ]; then
        warn "No Talos clusters found in project '${PROJECT_ID}'."
        return
    fi
    
    # 3. Process Data using jq (Group by Cluster)
    local RESULT
    RESULT=$(echo "$INSTANCE_DATA" | jq -r '
        group_by(.labels.cluster)[] |
        (.[0].labels.cluster) as $cluster |
        
        # Calculate counts for THIS cluster
        length as $total |
        map(select(.status == "RUNNING")) | length as $running |
        ($total - $running) as $not_running |
        
        # Determine Overall Status
        (if $running == $total and $total > 0 then "Online"
         elif $running > 0 then "Degraded"
         elif $total > 0 then "Offline"
         else "Unknown" end) as $status |
         
        # Find latest Start Time (from currently RUNNING nodes in this cluster)
        (map(select(.status == "RUNNING" and .lastStartTimestamp != null).lastStartTimestamp) | sort | last) as $started |
        
        # Find latest Stop Time (from currently STOPPED nodes in this cluster)
        (try (map(select(.status != "RUNNING" and .lastStopTimestamp != null).lastStopTimestamp) | sort | last) catch null) as $stopped |
        
        # Format Timestamps
        def fmt(ts): if ts then (ts | split(".")[0] | sub("T"; " ")) else "-" end;

        [$cluster, $status, fmt($started), fmt($stopped)] | @tsv
    ')
    
    # 4. Display Table
    echo "Project: ${PROJECT_ID}"
    printf "%-40s %-10s %-15s %-20s %-20s\n" "CLUSTER" "STATUS" "SCHEDULE" "STARTED AT" "STOPPED AT"
    
    while IFS=$'\t' read -r CLUSTER STAT START STOP; do
        if [ -z "$CLUSTER" ]; then continue; fi
        
        # ANSI Colors
        local COLOR_RESET="\033[0m"
        local COLOR_GREEN="\033[32m"
        local COLOR_RED="\033[31m"
        local COLOR_YELLOW="\033[33m"
        local COLOR_BOLD="\033[1m"
        local COLOR_CYAN="\033[36m"
        
        # 1. Cluster Name
        local DISP_CLUSTER="$CLUSTER"
        local IS_CURRENT="false"
        if [ "$CLUSTER" == "$CLUSTER_NAME" ]; then
             DISP_CLUSTER="${CLUSTER} (current)"
             IS_CURRENT="true"
        fi
        # Pad to 40
        printf -v DISP_CLUSTER "%-40s" "$DISP_CLUSTER"
        # Colorize
        if [ "$IS_CURRENT" == "true" ]; then
             DISP_CLUSTER="${COLOR_BOLD}${DISP_CLUSTER}${COLOR_RESET}"
        fi
        
        # 2. Status
        local DISP_STAT="$STAT"
        # Pad to 10
        printf -v DISP_STAT "%-10s" "$DISP_STAT"
        # Colorize
        if [ "$STAT" == "Online" ]; then
            DISP_STAT="${COLOR_GREEN}${DISP_STAT}${COLOR_RESET}"
        elif [ "$STAT" == "Degraded" ]; then
            DISP_STAT="${COLOR_YELLOW}${DISP_STAT}${COLOR_RESET}"
        else
            DISP_STAT="${COLOR_RED}${DISP_STAT}${COLOR_RESET}"
        fi
        
        # 3. Schedule
        local SCHED_VAL="${SCHEDULE_MAP[$CLUSTER]:--}"
        local DISP_SCHED="$SCHED_VAL"
        # Pad to 15
        printf -v DISP_SCHED "%-15s" "$DISP_SCHED"
        # Colorize
        if [ "$SCHED_VAL" != "-" ]; then
             DISP_SCHED="${COLOR_CYAN}${DISP_SCHED}${COLOR_RESET}"
        fi

        # Print Row (Use %b for colors, %s for timestamps which are already simple strings)
        # Note: We use %s for DISP_* vars because the colors are embedded in the variable string itself.
        printf "%b %b %b %-20s %-20s\n" "$DISP_CLUSTER" "$DISP_STAT" "$DISP_SCHED" "$START" "$STOP"
    done <<< "$RESULT"
    echo ""
}

public_ip() {
    set_names
    check_dependencies
    log "Retrieving Public IP for cluster ${CLUSTER_NAME}..."
    local IP=$(gcloud compute forwarding-rules list --filter="name~'${CLUSTER_NAME}-ingress.*'" --limit=1 --format="value(IPAddress)" --project="${PROJECT_ID}")
    
    if [ -n "$IP" ]; then
        echo "$IP"
    else
        error "No Public IP found (Ingress not deployed?)"
        exit 1
    fi
}
