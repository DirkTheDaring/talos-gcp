#!/bin/bash

list_clusters() {
    log "Scanning project ${PROJECT_ID} for Talos clusters..."

    # Check for required tools
    for cmd in jq column; do
        if ! command -v "$cmd" &> /dev/null; then
            error "Command '$cmd' is required for list-clusters but not installed."
            return 1
        fi
    done

    # 1. Fetch Data in Parallel
    # We use temp files to store JSON outputs
    local INSTANCES_FILE=$(mktemp)
    local ADDRESSES_FILE=$(mktemp)
    local FWD_RULES_FILE=$(mktemp)
    local TABLE_FILE=$(mktemp)
    
    # Ensure cleanup
    trap "rm -f '$INSTANCES_FILE' '$ADDRESSES_FILE' '$FWD_RULES_FILE' '$TABLE_FILE'" RETURN

    # Fetch Instances (Cluster Nodes + Bastions)
    # Filter: Has cluster label OR is a bastion (ends in -bastion)
    gcloud compute instances list \
        --filter="labels.cluster:* OR name ~ .*bastion$" \
        --project="${PROJECT_ID}" \
        --format="json(name, zone.basename(), status, labels, networkInterfaces[0].accessConfigs[0].natIP, networkInterfaces[0].networkIP)" > "$INSTANCES_FILE" &
    local PID_INST=$!

    # Fetch External IPs (Reserved Addresses)
    gcloud compute addresses list \
        --filter="name ~ .*ingress-v4-0$" \
        --project="${PROJECT_ID}" \
        --format="json(name, address, region.basename())" > "$ADDRESSES_FILE" &
    local PID_ADDR=$!

    # Fetch Forwarding Rules (Legacy Fallback)
    gcloud compute forwarding-rules list \
        --filter="name ~ .*ingress.*" \
        --project="${PROJECT_ID}" \
        --format="json(name, IPAddress, region.basename())" > "$FWD_RULES_FILE" &
    local PID_FWD=$!

    if ! wait $PID_INST $PID_ADDR $PID_FWD; then
        log "Warning: One or more background gcloud commands failed."
    fi

    
    # 2. Check if we found any clusters (Safe check without jq -e)
    if ! grep -q '"cluster":' "$INSTANCES_FILE"; then
         log "No Talos clusters found in project ${PROJECT_ID}."
         rm -f "$INSTANCES_FILE" "$ADDRESSES_FILE" "$FWD_RULES_FILE" "$TABLE_FILE"
         return
    fi

    jq -r -s '
    (["CLUSTER NAME", "ZONE", "TALOS VERSION", "K8S VERSION", "CILIUM VERSION", "PUBLIC IP", "BASTION IP"] | @tsv),
    (.[1] | map({key: (.name | sub("-ingress-v4-0$"; "")), value: .address}) | from_entries) as $addr_map |
    (.[2] | map({key: (.name | sub("-ingress.*"; "")), value: .IPAddress}) | from_entries) as $fwd_map |
    ($fwd_map + $addr_map) as $ip_map |
    (.[0] | map(select(.name | test("-bastion$"))) | map({key: (.name | sub("-bastion$"; "")), value: ((.networkInterfaces[0].accessConfigs[0].natIP // .networkInterfaces[0].networkIP) // "None")}) | from_entries) as $bastion_map |
    (.[0] | map(select(.labels.cluster != null))) | group_by(.labels.cluster)[] |
    (.[0].labels.cluster) as $cluster |
    (.[0].zone) as $zone |
    (map(select(.labels["talos-version"] != null)) | .[0] // .[0]) as $ver_node |
    ($ver_node.labels["talos-version"] // "unknown" | gsub("-"; ".")) as $talos_ver |
    ($ver_node.labels["k8s-version"] // "unknown" | gsub("-"; ".")) as $k8s_ver |
    ($ver_node.labels["cilium-version"] // "unknown" | gsub("-"; ".")) as $cilium_ver |
    ($ip_map[$cluster] // "Pending/None") as $public_ip |
    ($bastion_map[$cluster] // "None") as $bastion_ip |
    [$cluster, $zone, $talos_ver, $k8s_ver, $cilium_ver, $public_ip, $bastion_ip] | @tsv
    ' "$INSTANCES_FILE" "$ADDRESSES_FILE" "$FWD_RULES_FILE" > "$TABLE_FILE" || true
    
    if [ -s "$TABLE_FILE" ]; then
         column -t -s $'\t' < "$TABLE_FILE" || true
    else
         # Fallback if jq produced nothing but grep found clusters (shouldn't happen)
         warn "Cluster data processed but table is empty. Raw instances found."
    fi
    
    rm -f "$TABLE_FILE"
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
        --format="table(name, metadata.items.talos-image:label=TALOS-IMAGE, zone.basename(), machineType.basename(), networkInterfaces[0].networkIP:label=INTERNAL_IP, networkInterfaces[0].accessConfigs[0].natIP:label=EXTERNAL_IP, status)")

    if [ -z "$OUTPUT" ]; then
        warn "No instances found for cluster '${CLUSTER_NAME}'."
    else
        echo "$OUTPUT"
    fi
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
