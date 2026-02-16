#!/bin/bash

# --- Colors ---
RED=$'\e[0;31m'
GREEN=$'\e[0;32m'
YELLOW=$'\e[1;33m'
BLUE=$'\e[0;34m'
NC=$'\e[0m'

log() { echo -e "${GREEN}[INFO] $1${NC}" >&2; }
warn() { echo -e "${YELLOW}[WARN] $1${NC}" >&2; }
error() { echo -e "${RED}[ERROR] $1${NC}" >&2; }
info() { echo -e "${BLUE}[DEBUG] $1${NC}"; }

# Retry Wrapper
retry() {
    local max_attempts=5
    local timeout=1
    local attempt=1
    local exitCode=0

    while (( attempt <= max_attempts ))
    do
        "$@" && return 0
        exitCode=$?

        if (( attempt == max_attempts )); then
            error "Command failed after $max_attempts attempts: $*"
            return $exitCode
        fi

        warn "Command failed (Attempt $attempt/$max_attempts). Retrying in $timeout seconds..."
        sleep $timeout
        (( attempt++ ))
        timeout=$(( timeout * 2 ))
    done
}

# Error Handling Wrapper
run_safe() {
    "$@" || {
        local status=$?
        error "Command failed: $*"
        error "Exit Code: $status"
        echo "Tip: Run './deploy_talos_gcp.sh diagnose' to check the state of your environment." >&2
        return $status
    }
}

check_dependencies() {
    export CLOUDSDK_CORE_DISABLE_PROMPTS=1
    log "Checking dependencies..."
    # strict dependencies (System Tools Only)
    for cmd in gcloud gsutil curl envsubst python3 jq kubectl; do
        if ! command -v "$cmd" &> /dev/null; then
             error "System dependency '$cmd' is required but not installed."
             exit 1
        fi
    done
    export KUBECTL="kubectl"

    # Check for PyYAML
    if ! python3 -c "import yaml" &> /dev/null; then
        error "Python module 'PyYAML' is required but not installed."
        error "Please install it via: pip3 install PyYAML (or sudo apt install python3-yaml)"
        exit 1
    fi
    
    # Check permissions early - REMOVED (Moved to specific phases)
    # check_permissions
    

}

check_permissions() {
    log "Checking GCP Permissions..."
    
    if ! command -v jq &> /dev/null; then
        error "'jq' is required for permission checks but not installed."
        exit 1
    fi

    CURRENT_USER=$(gcloud config get-value account)
    log "Current User: $CURRENT_USER"

    if [ -z "${PROJECT_ID:-}" ]; then
        error "PROJECT_ID is not set. Cannot check permissions."
        exit 1
    fi

    if ! gcloud projects get-iam-policy "${PROJECT_ID}" &> /dev/null; then
        error "Cannot read IAM policy for project ${PROJECT_ID}."
        error "You need 'resourcemanager.projects.getIamPolicy' to verify permissions."
        exit 1
    fi
    
    # Heuristic Check for high-level roles
    POLICY=$(gcloud projects get-iam-policy "${PROJECT_ID}" --format=json)
    
    # Check for Owner
    IS_OWNER=$(echo "$POLICY" | jq -r --arg user "user:$CURRENT_USER" \
        '.bindings[] | select(.role == "roles/owner") | .members[] | select(. == $user)')

    # Check for Editor AND IAM Admin
    IS_EDITOR=$(echo "$POLICY" | jq -r --arg user "user:$CURRENT_USER" \
        '.bindings[] | select(.role == "roles/editor") | .members[] | select(. == $user)')
    IS_IAM_ADMIN=$(echo "$POLICY" | jq -r --arg user "user:$CURRENT_USER" \
        '.bindings[] | select(.role == "roles/resourcemanager.projectIamAdmin") | .members[] | select(. == $user)')

    if [[ -n "$IS_OWNER" ]]; then
        log "User has Owner privileges."
    elif [[ -n "$IS_EDITOR" && -n "$IS_IAM_ADMIN" ]]; then
        log "User has Editor + IAM Admin privileges."
    else
        warn "User $CURRENT_USER does not have sufficient privileges."
        warn "Required: 'roles/owner' OR ('roles/editor' AND 'roles/resourcemanager.projectIamAdmin')."
        warn "Missing 'Project IAM Admin' prevents creating IAM bindings for the Service Account."
        echo -n "Do you want to proceed anyway (might fail)? [y/N] "
        read -r response
        if [[ ! "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
            exit 1
        fi
    fi
}

# Helper to add instance to IG safely
ensure_instance_in_ig() {
    local instance_uri="$1"
    local ig_name="$2"
    
    # Check if instance is already in IG
    local current_members
    current_members=$(gcloud compute instance-groups unmanaged list-instances "${ig_name}" --zone "${ZONE}" --project="${PROJECT_ID}" --format="value(instance)" 2>/dev/null || true)

    # Use grep to check if instance_uri (or just name) is in the list
    local instance_name="${instance_uri##*/}"
    
    if echo "$current_members" | grep -q "${instance_name}$"; then
        log "Instance ${instance_name} is already in ${ig_name}."
    else
        log "Adding ${instance_name} to ${ig_name}..."
        run_safe gcloud compute instance-groups unmanaged add-instances "${ig_name}" --zone "${ZONE}" --instances "${instance_name}" --project="${PROJECT_ID}"
    fi
}

# Run command on Bastion (Tunnel Support)
run_on_bastion() {
    local cmd="$1"
    
    # Execute
    # -q: Quiet
    # -o StrictHostKeyChecking=no: Prevent prompt
    # --tunnel-through-iap: Enable access for private instances
    if ! gcloud compute ssh "${BASTION_NAME}" \
        --zone "${ZONE}" \
        --project="${PROJECT_ID}" \
        --tunnel-through-iap \
        --command "${cmd}" \
        -- -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null; then
        warn "Failed to execute command on bastion. (Bastion might be down or not reachable via IAP)"
        return 1
    fi
}

ensure_service_account() {
    log "Ensuring Service Account exists and has roles..."
    
    if ! gcloud iam service-accounts describe "${SA_EMAIL}" --project="${PROJECT_ID}" &> /dev/null; then
        log "Creating Service Account: ${SA_NAME}..."
        run_safe gcloud iam service-accounts create "${SA_NAME}" --display-name="Talos Cluster Custom SA" --project="${PROJECT_ID}"
        log "Waiting 10s for IAM propagation..."
        sleep 10
    else
        log "Service Account ${SA_EMAIL} exists."
    fi

    # Bind Roles (Least Privilege needed for CCM)
    log "Binding IAM Roles..."
    # compute.storageAdmin: Create/Attach PDs
    local roles=(
        "roles/compute.loadBalancerAdmin"
        "roles/compute.viewer"
        "roles/compute.securityAdmin"
        "roles/compute.networkViewer"
        "roles/compute.storageAdmin"
        "roles/compute.instanceAdmin.v1"
        "roles/iam.serviceAccountUser"
    )

    for ROLE in "${roles[@]}"; do
         run_safe gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
            --member="serviceAccount:${SA_EMAIL}" \
            --role="${ROLE}"
    done
}

check_apis() {
    log "Checking API Enablement..."
    local REQUIRED_APIS=("compute.googleapis.com" "iam.googleapis.com" "cloudresourcemanager.googleapis.com" "storage.googleapis.com" "networkmanagement.googleapis.com" "iap.googleapis.com" "serviceusage.googleapis.com")
    local MISSING_APIS=()
    
    # We check list of enabled services
    ENABLED_APIS=$(gcloud services list --enabled --format="value(config.name)" --project="${PROJECT_ID}")
    
    for api in "${REQUIRED_APIS[@]}"; do
        if ! echo "$ENABLED_APIS" | grep -q "$api"; then
             MISSING_APIS+=("$api")
        fi
    done
    
    if [ ${#MISSING_APIS[@]} -ne 0 ]; then
        warn "The following APIs are NOT enabled: ${MISSING_APIS[*]}"
        log "Enabling them automatically..."
        if ! gcloud services enable "${MISSING_APIS[@]}" --project="${PROJECT_ID}"; then
            error "Failed to enable APIs."
            error "This is most likely because Billing is NOT enabled for project '${PROJECT_ID}'."
            error "Please enable Billing here:"
            error "  👉 https://console.cloud.google.com/billing/linkedaccount?project=${PROJECT_ID}"
            exit 1
        fi
    else
        log "All required APIs are enabled."
    fi
}

check_quotas() {
    log "Checking Quotas in ${REGION}..."
    
    # Helper: Extract vCPU count from machine type string
    get_vcpu_count() {
        local mt="$1"
        if [[ "$mt" =~ custom-([0-9]+)- ]]; then
             echo "${BASH_REMATCH[1]}"
        elif [[ "$mt" =~ standard-([0-9]+) ]]; then
             echo "${BASH_REMATCH[1]}"
        elif [[ "$mt" =~ highmem-([0-9]+) ]]; then
             echo "${BASH_REMATCH[1]}"
        elif [[ "$mt" =~ highcpu-([0-9]+) ]]; then
             echo "${BASH_REMATCH[1]}"
        elif [[ "$mt" =~ (micro|small|medium) ]]; then
             echo "2" # e2-micro/small/medium often report 2 shared vCPUs
        else
             echo "2" # Default fallback
        fi
    }

    # Helper: Determine Quota Metric Family (e.g. N2_CPUS)
    # Returns "CPUS" (Global) or specific family metric (e.g., N2_CPUS)
    get_quota_metric() {
        local mt="$1"
        local family="${2:-}"

        # Explicit Family Override (for custom types or when explicitly set)
        if [[ -n "$family" ]]; then
            case "${family,,}" in
                e2|n1|f1|g1) echo "CPUS" ;;
                *) echo "${family^^}_CPUS" ;;
            esac
            return
        fi

        # Inferred from Standard Type
        case "$mt" in
            n2-*)  echo "N2_CPUS" ;;
            n2d-*) echo "N2D_CPUS" ;;
            c2-*)  echo "C2_CPUS" ;;
            c2d-*) echo "C2D_CPUS" ;;
            t2d-*) echo "T2D_CPUS" ;;
            t2a-*) echo "T2A_CPUS" ;;
            m1-*)  echo "M1_CPUS" ;;
            m2-*)  echo "M2_CPUS" ;;
            a2-*)  echo "A2_CPUS" ;;
            c3-*)  echo "C3_CPUS" ;;
            c3d-*) echo "C3D_CPUS" ;;
            *)     echo "CPUS" ;; # E2, N1, F1, G1 fall under standard/global CPUS usually
        esac
    }

    # Tracking Variables (Associative Array for Family Metrics)
    # We use declare -A if available, otherwise fallback to explicit variables?
    # Bash 4.0+ has associative arrays. Talos scripts assume modern bash environment.
    declare -A REQUIRED_METRICS
    REQUIRED_METRICS["CPUS"]=0

    # --- 1. Bastion ---
    # e2-micro/small ~ 2 vCPU (Standard CPUS)
    REQUIRED_METRICS["CPUS"]=$((REQUIRED_METRICS["CPUS"] + 2))

    # --- 2. Control Plane ---
    local cp_vcpu
    cp_vcpu=$(get_vcpu_count "${CP_MACHINE_TYPE}")
    local cp_metric
    cp_metric=$(get_quota_metric "${CP_MACHINE_TYPE}")
    
    # Add to Total Global CPUS
    REQUIRED_METRICS["CPUS"]=$((REQUIRED_METRICS["CPUS"] + (cp_vcpu * CP_COUNT)))
    
    # Add to Specific Family Metric (if not CPUS)
    if [ "$cp_metric" != "CPUS" ]; then
        if [ -z "${REQUIRED_METRICS[$cp_metric]:-}" ]; then REQUIRED_METRICS["$cp_metric"]=0; fi
        REQUIRED_METRICS["$cp_metric"]=$((REQUIRED_METRICS["$cp_metric"] + (cp_vcpu * CP_COUNT)))
    fi

    # --- 3. Worker Node Pools ---
    local pools=("${NODE_POOLS[@]}")
    [ ${#pools[@]} -eq 0 ] && pools=("worker")

    for pool in "${pools[@]}"; do
        local safe_pool="${pool//-/_}"
        local count_var="POOL_${safe_pool^^}_COUNT"
        local type_var="POOL_${safe_pool^^}_TYPE"
        local family_var="POOL_${safe_pool^^}_FAMILY"
        local vcpu_var="POOL_${safe_pool^^}_VCPU"
        
        local count="${!count_var:-0}"
        if [ "$count" -eq 0 ]; then continue; fi

        local mt="${!type_var:-e2-standard-2}"
        local worker_vcpu
        local worker_metric

        # Handle Custom Type
        if [ "$mt" == "custom" ]; then
             local vcpu="${!vcpu_var:-2}"
             worker_vcpu="$vcpu"
             # Use explicit family variable if set, default to N2 (common for custom) if not.
             local fam="${!family_var:-n2}"
             worker_metric=$(get_quota_metric "" "$fam")
        else
             worker_vcpu=$(get_vcpu_count "${mt}")
             worker_metric=$(get_quota_metric "${mt}")
        fi

        # Add to Totals
        REQUIRED_METRICS["CPUS"]=$((REQUIRED_METRICS["CPUS"] + (worker_vcpu * count)))
        
        if [ "$worker_metric" != "CPUS" ]; then
            if [ -z "${REQUIRED_METRICS[$worker_metric]:-}" ]; then REQUIRED_METRICS["$worker_metric"]=0; fi
            REQUIRED_METRICS["$worker_metric"]=$((REQUIRED_METRICS["$worker_metric"] + (worker_vcpu * count)))
        fi
    done

    # --- 4. Quota Check ---
    log "Required vCPUs Summary:"
    for metric in "${!REQUIRED_METRICS[@]}"; do
        log "  - ${metric}: ${REQUIRED_METRICS[$metric]}"
    done

    if ! command -v jq &> /dev/null; then warn "jq not found, skipping quota check."; return; fi
    
    local REGION_INFO
    REGION_INFO=$(gcloud compute regions describe "${REGION}" --project="${PROJECT_ID}" --format="json" 2>/dev/null || echo "")
    
    if [ -z "$REGION_INFO" ]; then
        warn "Could not read region info. Billing might be disabled or permissions missing."
        return
    fi
    
    # Inner Helper Function to check a specific metric against the fetched JSON
    check_single_metric() {
        local metric_name="$1"
        local required="$2"
        
        local available
        available=$(echo "$REGION_INFO" | jq -r --arg metric "$metric_name" '
            ([.quotas[] | select(.metric == $metric)][0] | .limit // 0) as $limit |
            ([.quotas[] | select(.metric == $metric)][0] | .usage // 0) as $usage |
            ($limit - $usage) | floor
        ')
        
        # Handle cases where metric is not present (jq returns null)
        if [ "$available" == "null" ] || [ -z "$available" ]; then available=0; fi
        
        log "  > Quota '${metric_name}': Available=${available}, Required=${required}"
        
        if [ "$available" -lt "$required" ]; then
            error "Insufficient '${metric_name}' Quota in ${REGION}."
            error "Available: ${available}, Required: ${required}"
            error "Please request a quota increase."
            return 1
        fi
    }

    # Iterate and Check
    for metric in "${!REQUIRED_METRICS[@]}"; do
        local required="${REQUIRED_METRICS[$metric]}"
        if [ "$required" -gt 0 ]; then
             check_single_metric "$metric" "$required" || exit 1
        fi
    done
    
    log "✅ Quota check passed."
}

# Auto-Grant Admin Access
ensure_admin_access() {
    log "Checking Admin Access (OS Login)..."
    
    # Get current user/service-account
    local CURRENT_ACCOUNT
    CURRENT_ACCOUNT=$(gcloud config get-value account 2>/dev/null)
    
    if [ -z "$CURRENT_ACCOUNT" ]; then
        warn "Could not determine current gcloud user. Skipping Admin Grant."
        return
    fi
    
    log "Current User: $CURRENT_ACCOUNT"
    
    # Check if they have the role
    # heuristic: verify if policy contains the binding
    if gcloud projects get-iam-policy "${PROJECT_ID}" --flatten="bindings[].members" --format="table(bindings.role)" --filter="bindings.members:${CURRENT_ACCOUNT}" 2>/dev/null | grep -q "roles/compute.osAdminLogin"; then
        log "✅ User has 'roles/compute.osAdminLogin'. Admin access confirmed."
    else
        warn "User missing 'roles/compute.osAdminLogin'."
        log "Attempting to auto-grant Admin role..."
        if run_safe gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
            --member="user:${CURRENT_ACCOUNT}" \
            --role="roles/compute.osAdminLogin" >/dev/null; then
            log "✅ Successfully granted 'roles/compute.osAdminLogin' to ${CURRENT_ACCOUNT}."
            log "Waiting 15s for IAM propagation..."
            sleep 15
        else
            error "Failed to auto-grant Admin role."
            error "You must manually grant 'Compute OS Admin Login' to ${CURRENT_ACCOUNT}."
            # We don't exit here; let the bastion safety net handle it.
        fi
    fi
}


# Timezone Detection
detect_timezone() {
    local region="$1"
    
    # Prefix Matching
    case "$region" in
        us-central*)      echo "America/Chicago" ;;
        us-east1*|us-east4*) echo "America/New_York" ;;
        us-east5*)        echo "America/Detroit" ;; # Ohio? Usually Eastern.
        us-west1*)        echo "America/Los_Angeles" ;; # Oregon
        us-west2*)        echo "America/Los_Angeles" ;; # Los Angeles
        us-west3*)        echo "America/Denver" ;; # Salt Lake City - MDT
        us-west4*)        echo "America/Phoenix" ;; # Las Vegas
        us-south1*)       echo "America/Chicago" ;; # Dallas
        northamerica-northeast1*) echo "America/Montreal" ;;
        northamerica-northeast2*) echo "America/Toronto" ;;
        southamerica-east1*) echo "America/Sao_Paulo" ;;
        southamerica-west1*) echo "America/Santiago" ;;
        
        europe-west1*)    echo "Europe/Brussels" ;; # Belgium
        europe-west2*)    echo "Europe/London" ;;   # London
        europe-west3*)    echo "Europe/Berlin" ;;   # Frankfurt
        europe-west4*)    echo "Europe/Amsterdam" ;; # Eemshaven
        europe-west6*)    echo "Europe/Zurich" ;;   # Zurich
        europe-west8*)    echo "Europe/Rome" ;;     # Milan
        europe-west9*)    echo "Europe/Paris" ;;    # Paris
        europe-north1*)   echo "Europe/Helsinki" ;; # Finland
        europe-central2*) echo "Europe/Warsaw" ;;   # Warsaw
        europe-southwest1*) echo "Europe/Madrid" ;; # Madrid

        asia-east1*)      echo "Asia/Taipei" ;;
        asia-east2*)      echo "Asia/Hong_Kong" ;;
        asia-northeast1*) echo "Asia/Tokyo" ;;
        asia-northeast2*) echo "Asia/Seoul" ;;
        asia-northeast3*) echo "Asia/Seoul" ;;
        asia-southeast1*) echo "Asia/Singapore" ;;
        asia-southeast2*) echo "Asia/Jakarta" ;;
        asia-south1*)     echo "Asia/Kolkata" ;;
        asia-south2*)     echo "Asia/Kolkata" ;; # Delhi
        
        australia-southeast1*) echo "Australia/Sydney" ;;
        australia-southeast2*) echo "Australia/Melbourne" ;;
        
        me-west1*)        echo "Asia/Jerusalem" ;; # Tel Aviv
        me-central1*)     echo "Asia/Dubai" ;;     # Doha? No, Dubai/Qatar. Usually +3/4. Lets use Dubai.
        me-central2*)     echo "Asia/Riyadh" ;;    # Dammam
        
        *)
            # Fallback to UTC if unknown
            echo "UTC"
            ;;
    esac
}

# Config Validation
validate_talos_config() {
    local config_file="$1"
    local type="${2:-machine}" # machine or client

    log "Validating ${type} config: ${config_file}..."

    if [ ! -s "${config_file}" ]; then
        error "Config file '${config_file}' is missing or empty."
        return 1
    fi

    # Determine validation mode (Local vs Bastion)
    local use_bastion="false"
    if [ -n "${BASTION_NAME:-}" ]; then
        # Check if Bastion is running and reachable (Optimistic check)
        if gcloud compute instances describe "${BASTION_NAME}" --zone "${ZONE}" --project="${PROJECT_ID}" --format="value(status)" 2>/dev/null | grep -q "RUNNING"; then
             use_bastion="true"
        fi
    fi

    if [ "$use_bastion" == "true" ]; then
        log "  > validating on Bastion '${BASTION_NAME}'..."
        
        # Upload config to Bastion temp
        local remote_path="/tmp/$(basename "${config_file}").val"
        
        if ! gcloud compute scp "${config_file}" "${BASTION_NAME}:${remote_path}" --zone "${ZONE}" --project="${PROJECT_ID}" --tunnel-through-iap --quiet &>/dev/null; then
            warn "Failed to upload config to Bastion. Falling back to local validation."
            use_bastion="false"
        else
            # Run validation remotely
            local validate_cmd
            if [ "${type}" == "client" ]; then
                # talosctl config info (client check)
                validate_cmd="talosctl --talosconfig ${remote_path} config info >/dev/null"
            else
                # machine check
                validate_cmd="talosctl validate --config ${remote_path} --mode metal"
            fi
            
            if ! gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --project="${PROJECT_ID}" --tunnel-through-iap --command "${validate_cmd}" -- -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null; then
                 error "Remote validation failed for: ${config_file}"
                 # Cleanup
                 gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --project="${PROJECT_ID}" --tunnel-through-iap --command "rm -f ${remote_path}" -- -q &>/dev/null || true
                 return 1
            fi
            
            # Cleanup
            gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --project="${PROJECT_ID}" --tunnel-through-iap --command "rm -f ${remote_path}" -- -q &>/dev/null || true
            log "✅ Configuration '${config_file}' is valid (Verified on Bastion)."
            return 0
        fi
    fi

    # Fallback to Local Validation (if Bastion not available or upload failed)
    log "  > validating locally..."
    if [ "${type}" == "client" ]; then
        if ! "$TALOSCTL" --talosconfig "${config_file}" config info &>/dev/null; then
             error "Invalid client configuration: ${config_file}"
             return 1
        fi
    else
        if ! "$TALOSCTL" validate --config "${config_file}" --mode metal; then
             error "Invalid machine configuration: ${config_file}"
             return 1
        fi
    fi
    
    log "✅ Configuration '${config_file}' is valid (Verified Locally)."
}

# Verify Node Serial Console for Errors
verify_node_log() {
    local node_name="$1"
    local zone="${2:-$ZONE}"
    
    log "Verifying serial console log for ${node_name}..."
    
    # Wait a bit for logs to populate if called immediately after creation
    sleep 5
    
    local log_output
    if ! log_output=$(gcloud compute instances get-serial-port-output "${node_name}" --zone "${zone}" --project="${PROJECT_ID}" 2>&1); then
        warn "Failed to fetch serial logs for ${node_name}. It might be too early."
        return 0 # Don't block deployment on API failure, but warn
    fi
    
    # Check for specific failure signatures
    local failure_patterns=("Kernel panic" "Call Trace" "segmentation fault" "oom-killer")
    local found_errors=0
    
    for pattern in "${failure_patterns[@]}"; do
        if echo "$log_output" | grep -Fq "$pattern"; then
             error "CRITICAL: Found '$pattern' in ${node_name} logs!"
             found_errors=1
        fi
    done
    
    if [ $found_errors -eq 1 ]; then
        # Dump last 20 lines for context
        error "Last 20 lines of serial console:"
        echo "$log_output" | tail -n 20 | sed 's/^/[CONSOLE] /' >&2
        return 1
    fi
    
    # Check for success signature (optional, but good for confidence)
    if echo "$log_output" | grep -Fq "Talos: boot sequence completed"; then
        log "✅ ${node_name} booted successfully (Log signature found)."
    elif echo "$log_output" | grep -Fq "phase: running"; then
         log "✅ ${node_name} is running (Log signature found)."
    else
        # Not finding success isn't necessarily a failure (e.g. log rotation), but worth noting.
        info "No explicit success signature found yet for ${node_name}, but no errors detected."
    fi
    
    return 0
}
