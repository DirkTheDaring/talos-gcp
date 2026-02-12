#!/bin/bash

# --- Phase 4: Operational Commands ---

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

get_credentials() {
    log "Fetching credentials for cluster: ${CLUSTER_NAME}..."
    
    # 1. Bucket Check
    if ! gsutil -q stat "${GCS_SECRETS_URI}"; then
        error "Secrets not found at ${GCS_SECRETS_URI}. Is the cluster deployed?"
        exit 1
    fi
    
    # 2. Download Secrets
    mkdir -p "${OUTPUT_DIR}"
    log "Downloading secrets to ${OUTPUT_DIR}..."
    run_safe gsutil cp "${GCS_SECRETS_URI}" "${OUTPUT_DIR}/secrets.yaml"
    chmod 600 "${OUTPUT_DIR}/secrets.yaml"
    
    # 3. Get CP IP
    local CP_ILB_IP
    CP_ILB_IP=$(gcloud compute addresses describe "${ILB_CP_IP_NAME}" --region "${REGION}" --format="value(address)" --project="${PROJECT_ID}" 2>/dev/null)
    
    if [ -z "$CP_ILB_IP" ]; then
        error "Control Plane Internal IP not found. Is the Load Balancer deployed?"
        exit 1
    fi
    
    # 4. Generate Configs
    log "Regenerating Talos config (Endpoint: https://${CP_ILB_IP}:6443)..."
    
    # Clean up existing configs to prevent talosctl errors
    rm -f "${OUTPUT_DIR}/controlplane.yaml" "${OUTPUT_DIR}/worker.yaml" "${OUTPUT_DIR}/talosconfig" "${OUTPUT_DIR}/kubeconfig" "${OUTPUT_DIR}/kubeconfig.local"

    # We can rely on 'talosctl' being available because check_dependencies runs first
    # and installs it if missing.
    # Note: 'gen config' creates talosconfig, controlplane.yaml, worker.yaml
    run_safe "$TALOSCTL" gen config "${CLUSTER_NAME}" "https://${CP_ILB_IP}:6443" --with-secrets "${OUTPUT_DIR}/secrets.yaml" --with-docs=false --with-examples=false --output-dir "${OUTPUT_DIR}"

    # Configure talosconfig endpoint AND node
    run_safe "$TALOSCTL" --talosconfig "${OUTPUT_DIR}/talosconfig" config endpoint "https://${CP_ILB_IP}:6443"
    run_safe "$TALOSCTL" --talosconfig "${OUTPUT_DIR}/talosconfig" config node "${CP_ILB_IP}"
    
    # 5. Fetch Kubeconfig from Bastion
    # We cannot run 'talosctl ... kubeconfig' locally because the API is internal.
    # The Bastion already has a valid ~/.kube/config generated during bootstrap/recreation.
    log "Fetching kubeconfig from Bastion..."
    if ! gcloud compute scp "${BASTION_NAME}:~/.kube/config" "${OUTPUT_DIR}/kubeconfig" --zone "${ZONE}" --project="${PROJECT_ID}" --tunnel-through-iap; then
        error "Failed to fetch kubeconfig from Bastion. Is the Bastion running?"
        exit 1
    fi
     
    # Generate Tunnel-Friendly Configs (localhost + safe ports)
    # Ports match those in 'access-info': K8s=64430, Talos=50005
    
    # Kubeconfig (64430)
    cp "${OUTPUT_DIR}/kubeconfig" "${OUTPUT_DIR}/kubeconfig.local"
    sed -i "s|https://${CP_ILB_IP}:6443|https://127.0.0.1:64430|g" "${OUTPUT_DIR}/kubeconfig.local"

    # Talosconfig (50005)
    cp "${OUTPUT_DIR}/talosconfig" "${OUTPUT_DIR}/talosconfig.local"
    run_safe "$TALOSCTL" --talosconfig "${OUTPUT_DIR}/talosconfig.local" config endpoint "https://127.0.0.1:50005"
    run_safe "$TALOSCTL" --talosconfig "${OUTPUT_DIR}/talosconfig.local" config node "127.0.0.1"

    echo ""
    log "Credentials saved to: ${OUTPUT_DIR}"
    echo "------------------------------------------------"
    echo "NOTE: Control Plane is INTERNAL (${CP_ILB_IP})."
    echo "Files:"
    echo "  - kubeconfig        (Internal IP)"
    echo "  - talosconfig       (Internal IP)"
    echo "  - kubeconfig.local  (Tunnel: 127.0.0.1:64430)"
    echo "  - talosconfig.local (Tunnel: 127.0.0.1:50005)"
    echo ""
    echo "To access from your workstation:"
    echo "  1. Start Tunnel:"
    echo "     ./talos-gcp access-info"
    echo "  2. Use Configs:"
    echo "     export KUBECONFIG=${OUTPUT_DIR}/kubeconfig.local"
    echo "     export TALOSCONFIG=${OUTPUT_DIR}/talosconfig.local"
    echo "     kubectl get nodes"
    echo "     talosctl dashboard"
    echo "------------------------------------------------"
}

update_cilium() {
    set_names
    log "Updating Cilium to version ${CILIUM_VERSION}..."
    
    # 1. Redeploy Helm Chart
    deploy_cilium
    
    # 2. Update Instance Labels
    local CILIUM_LABEL="${CILIUM_VERSION//./-}"
    log "Updating instance labels to cilium-version=${CILIUM_LABEL}..."
    
    # Find all cluster instances
    local INSTANCES
    INSTANCES=$(gcloud compute instances list --filter="labels.cluster=${CLUSTER_NAME} AND zone:(${ZONE})" --format="value(name)" --project="${PROJECT_ID}")
    
    if [ -n "$INSTANCES" ]; then
        for instance in $INSTANCES; do
            log "Updating label for ${instance}..."
            run_safe gcloud compute instances add-labels "${instance}" --labels="cilium-version=${CILIUM_LABEL}" --zone "${ZONE}" --project="${PROJECT_ID}"
        done
        log "Labels updated."
    else
        warn "No instances found to update labels."
    fi
    
    status
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

update_ports() {
    set_names
    log "Updating Ingress Ports for cluster '${CLUSTER_NAME}'..."
    log "Configuration: INGRESS_IPV4_CONFIG='${INGRESS_IPV4_CONFIG}'"
    apply_ingress
    log "Port update complete."
}

ssh_command() {
    set_names
    
    # Check if bastion exists
    if ! gcloud compute instances describe "${BASTION_NAME}" --zone "${ZONE}" --project="${PROJECT_ID}" &> /dev/null; then
        error "Bastion '${BASTION_NAME}' not found in zone '${ZONE}'."
        return 1
    fi
    
    if [ $# -eq 0 ]; then
        log "Opening interactive shell to Bastion '${BASTION_NAME}'..."
    else
        log "Executing command on Bastion '${BASTION_NAME}': $*"
    fi
    
    # SSH into Bastion
    # Using StrictHostKeyChecking=no to avoid issues if bastion is recreated with same name/IP
    # "$@" passes remaining arguments to the ssh command
    # Using 'exec' to replace the current process (cleaner exit signals/codes)
    exec gcloud compute ssh "${BASTION_NAME}" \
        --zone "${ZONE}" \
        --project="${PROJECT_ID}" \
        --tunnel-through-iap \
        -- -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$@"
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
        
        # ANSI Colors for Status
        local COLOR_RESET="\033[0m"
        local COLOR_GREEN="\033[32m"
        local COLOR_RED="\033[31m"
        local COLOR_YELLOW="\033[33m"
        local COLOR_BOLD="\033[1m"
        local COLOR_CYAN="\033[36m"
        
        local PR_CLUSTER="$CLUSTER"
        if [ "$CLUSTER" == "$CLUSTER_NAME" ]; then
            PR_CLUSTER="${COLOR_BOLD}${CLUSTER} (current)${COLOR_RESET}"
        fi
        
        local PR_STAT="$STAT"
        if [ "$STAT" == "Online" ]; then
            PR_STAT="${COLOR_GREEN}${STAT}${COLOR_RESET}"
        elif [ "$STAT" == "Degraded" ]; then
            PR_STAT="${COLOR_YELLOW}${STAT}${COLOR_RESET}"
        else
            PR_STAT="${COLOR_RED}${STAT}${COLOR_RESET}"
        fi
        
        # Schedule Info
        local SCHED="${SCHEDULE_MAP[$CLUSTER]:--}"
        if [ "$SCHED" != "-" ]; then
             SCHED="${COLOR_CYAN}${SCHED}${COLOR_RESET}"
        fi
        
        printf "%-50b %-19b %-26b %-20s %-20s\n" "$PR_CLUSTER" "$PR_STAT" "$SCHED" "$START" "$STOP"
    done <<< "$RESULT"
    echo ""
}


update_labels() {
    log "Updating instance labels based on runtime versions..."
    
    # Prereq: Bastion must be up
    if ! gcloud compute instances describe "${BASTION_NAME}" --zone "${ZONE}" --project="${PROJECT_ID}" &> /dev/null; then
        error "Bastion host '${BASTION_NAME}' not found. Cannot connect to cluster."
        return 1
    fi

    # Retrieve Version Info via Bastion (using kubectl)
    log "Retrieving versions from cluster..."

    # Check for kubeconfig
    if ! (ssh_command "[ -f ~/.kube/config ]"); then
        error "Kubeconfig not found on Bastion (~/.kube/config). Cannot query cluster."
        error "Try running 'verify-storage' or checking if the cluster is bootstrapped."
        return 1
    fi
    
    # 1. Kubernetes Version
    local K8S_VER_ACTUAL
    K8S_VER_ACTUAL=$(ssh_command kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')
    
    if [ -z "$K8S_VER_ACTUAL" ]; then
        error "Failed to retrieve Kubernetes version. Is the cluster API reachable? Check 'verify-storage' or 'diagnose'."
        return 1
    fi
    
    # 2. Talos Version
    local TALOS_VER_ACTUAL
    TALOS_VER_ACTUAL=$(ssh_command kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].status.nodeInfo.osImage}')
    # Clean up: "Talos (v1.12.3)" -> "v1.12.3"
    TALOS_VER_ACTUAL=$(echo "$TALOS_VER_ACTUAL" | awk -F'[()]' '{print $2}')
    
    if [ -z "$TALOS_VER_ACTUAL" ]; then
        warn "Failed to retrieve Talos version. Defaulting to configured version: ${TALOS_VERSION}"
        TALOS_VER_ACTUAL="${TALOS_VERSION}"
    fi

    # 3. Cilium Version
    local CILIUM_VER_ACTUAL
    CILIUM_VER_ACTUAL=$(ssh_command kubectl -n kube-system get deployment cilium-operator -o jsonpath='{.spec.template.spec.containers[0].image}')
    
    if [ -z "$CILIUM_VER_ACTUAL" ]; then
         warn "Cilium operator not found. Defaulting to configured version: ${CILIUM_VERSION}"
         CILIUM_VER_ACTUAL="${CILIUM_VERSION}"
    else
        # Extract version from image (repo/image:tag or repo/image:tag@sha256:...)
        # We assume standard tagging: ...:v1.16.6...
        # 1. Remove everything before the first colon (repo/image:)
        # 2. Remove everything after @ (digest)
        CILIUM_VER_ACTUAL=$(echo "$CILIUM_VER_ACTUAL" | cut -d: -f2 | cut -d@ -f1)
        
        # Remove 'v' prefix if present (e.g. v1.16.6 -> 1.16.6)
        CILIUM_VER_ACTUAL="${CILIUM_VER_ACTUAL#v}"
    fi

    log "Detected Versions:"
    log "  Kubernetes: $K8S_VER_ACTUAL"
    log "  Talos:      $TALOS_VER_ACTUAL"
    log "  Cilium:     $CILIUM_VER_ACTUAL"

    # Sanitize for GCP Labels
    # Rules: lowercase, numbers, hyphens only.
    # We replace any other character (dots, pluses, etc.) with hyphens.
    local L_K8S
    local L_TALOS
    local L_CILIUM
    
    L_K8S=$(echo "${K8S_VER_ACTUAL}" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]' '-')
    L_TALOS=$(echo "${TALOS_VER_ACTUAL}" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]' '-')
    L_CILIUM=$(echo "${CILIUM_VER_ACTUAL}" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]' '-')
    
    # Remove trailing hyphens if any (tr -c adds hyphen for newline too)
    L_K8S="${L_K8S%-}"
    L_TALOS="${L_TALOS%-}"
    L_CILIUM="${L_CILIUM%-}"

    # Update Labels on ALL Cluster Instances (CP + Worker + Bastion)
    local INSTANCES
    INSTANCES=$(gcloud compute instances list --filter="labels.cluster=${CLUSTER_NAME} OR name:${BASTION_NAME}" --format="value(name,zone)" --project="${PROJECT_ID}")
    
    if [ -z "$INSTANCES" ]; then
        warn "No instances found for cluster '${CLUSTER_NAME}'."
        return
    fi
    
    # Loop line by line
    echo "$INSTANCES" | while read -r name zone; do
        if [ -z "$name" ]; then continue; fi
        log "Updating labels for $name ($zone)..."
        run_safe gcloud compute instances add-labels "$name" --zone "$zone" --labels="k8s-version=${L_K8S},talos-version=${L_TALOS},cilium-version=${L_CILIUM}" --project="${PROJECT_ID}"
    done
    
    log "Labels updated successfully."
}



diagnose() {
    set_names
    # check_dependencies - Not needed
    
    echo "========================================="
    echo " Talos GCP Diagnostics"
    echo " Cluster: ${CLUSTER_NAME}"
    echo " Project: ${PROJECT_ID}"
    echo " Zone:    ${ZONE}"
    echo "========================================="
    
    # 1. Check Cloud NAT (Crucial for Bastion Outbound)
    echo ""
    echo "[Network] Checking Cloud NAT..."
    if gcloud compute routers nats list --router="${ROUTER_NAME}" --region="${REGION}" --project="${PROJECT_ID}" | grep -q "${NAT_NAME}"; then
        echo "OK: Cloud NAT '${NAT_NAME}' exists."
    else
        echo "ERROR: Cloud NAT '${NAT_NAME}' not found. Bastion may lack internet access."
    fi

    # 2. Check Bastion Status
    echo ""
    echo "[Compute] Checking Bastion Host..."
    local BASTION_STATUS=$(gcloud compute instances describe "${BASTION_NAME}" --zone "${ZONE}" --project="${PROJECT_ID}" --format="value(status)" 2>/dev/null)
    if [ "$BASTION_STATUS" == "RUNNING" ]; then
        echo "OK: Bastion '${BASTION_NAME}' is RUNNING."
    else
        echo "ERROR: Bastion '${BASTION_NAME}' is in state: ${BASTION_STATUS:-Not Found}"
    fi

    # 3. Check Control Plane Instances
    echo ""
    echo "[Compute] Checking Control Plane Instances..."
    gcloud compute instances list --filter="name~'${CLUSTER_NAME}-cp-.*'" --project="${PROJECT_ID}" --format="table(name,status,networkInterfaces[0].networkIP)"

    # 4. Check Load Balancers (Forwarding Rules)
    echo ""
    echo "[Network] Checking Load Balancers..."
    gcloud compute forwarding-rules list --filter="name~'${CLUSTER_NAME}.*'" --project="${PROJECT_ID}" --format="table(name,IPAddress,IPProtocol,ports,target)"

    # 5. Check Health Checks
    echo ""
    echo "[Network] Checking Health Checks..."
    gcloud compute health-checks list --filter="name~'${CLUSTER_NAME}.*'" --project="${PROJECT_ID}" --format="table(name,type,checkIntervalSec,timeoutSec,healthyThreshold,unhealthyThreshold)"

    echo "========================================="
    echo "Diagnostics Complete."
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

verify_storage() {
    log "Verifying Storage Configuration..."
    
    # 1. Check StorageClasses
    log "Checking StorageClasses..."
    if ! gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl get sc"; then
        error "Failed to list StorageClasses. Is the cluster reachable?"
        return 1
    fi
    
    # 2. Create PVC & Pod
    log "Creating PVC and Test Pod..."
    cat <<EOF > "${OUTPUT_DIR}/storage-test.yaml"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: standard-rwo
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: test-storage-pod
spec:
  containers:
  - name: test-container
    image: busybox
    command: ["/bin/sh", "-c", "echo 'Hello Talos Storage' > /data/test-file && sleep 3600"]
    volumeMounts:
    - mountPath: "/data"
      name: test-volume
  volumes:
  - name: test-volume
    persistentVolumeClaim:
      claimName: test-pvc
  restartPolicy: Never
EOF

    run_safe gcloud compute scp "${OUTPUT_DIR}/storage-test.yaml" "${BASTION_NAME}:~" --zone "${ZONE}" --tunnel-through-iap
    run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl apply -f storage-test.yaml"

    # 3. Wait for Pod
    log "Waiting for Test Pod to be Ready (max 2m)..."
    local POD_STATUS=""
    for i in {1..24}; do
        POD_STATUS=$(gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl get pod test-storage-pod -o jsonpath='{.status.phase}'" 2>/dev/null)
        if [ "$POD_STATUS" == "Running" ]; then
            log "Pod is Running!"
            break
        fi
        echo -n "."
        sleep 5
    done
    echo ""
    
    if [ "$POD_STATUS" != "Running" ]; then
        error "Pod failed to start. Status: $POD_STATUS"
        log "Investigating..."
        gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl describe pod test-storage-pod"
        gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl describe pvc test-pvc"
        gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl get events --sort-by=.metadata.creationTimestamp | tail -n 20"
    else
        # 4. Check Write
        log "Verifying data write..."
        if gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl exec test-storage-pod -- cat /data/test-file" | grep -q "Hello Talos Storage"; then
            log "SUCCESS: Data written and read from PVC."
        else
            error "FAILURE: Could not read data from PVC."
        fi
    fi

    # 5. Cleanup
    log "Cleaning up Test Resources..."
    gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl delete -f storage-test.yaml --grace-period=0 --force"
    rm -f "${OUTPUT_DIR}/storage-test.yaml"
}
