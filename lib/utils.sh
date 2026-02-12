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
    log "Checking dependencies..."
    # strict dependencies
    for cmd in gcloud gsutil curl envsubst python3 jq; do
        if ! command -v "$cmd" &> /dev/null; then
             error "$cmd is required but not installed."
             exit 1
        fi
    done

    # Check for PyYAML
    if ! python3 -c "import yaml" &> /dev/null; then
        error "Python module 'PyYAML' is required but not installed."
        error "Please install it via: pip3 install PyYAML (or sudo apt install python3-yaml)"
        exit 1
    fi

    # Shared Tools Directory (Scoped to Cluster)
    # Use _out/${CLUSTER_NAME}/tools to allow parallel execution with different versions
    export TOOLS_DIR="$(pwd)/_out/${CLUSTER_NAME}/tools"
    mkdir -p "${TOOLS_DIR}"
    export PATH="${TOOLS_DIR}:$PATH"

    # Talosctl Check & Auto-Install
    if ! command -v talosctl &> /dev/null || ! talosctl version --client --short 2>&1 | grep -q "${TALOS_VERSION}"; then
        if [ -f "${TOOLS_DIR}/talosctl" ] && "${TOOLS_DIR}/talosctl" version --client --short 2>&1 | grep -q "${TALOS_VERSION}"; then
             log "Using cached talosctl from ${TOOLS_DIR}"
        else
            warn "Local talosctl version mismatch or missing."
            log "Downloading talosctl ${TALOS_VERSION}..."
            
            # Download Talosctl
            local OS=$(uname -s | tr '[:upper:]' '[:lower:]')
            if ! curl -L -o "${TOOLS_DIR}/talosctl" "https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/talosctl-${OS}-${ARCH}"; then
                 error "Failed to download talosctl."
                 exit 1
            fi
            chmod +x "${TOOLS_DIR}/talosctl"
        fi
        
        # Verify
        if ! talosctl version --client --short 2>&1 | grep -q "${TALOS_VERSION}"; then
             error "Failed to setup correct talosctl version."
             exit 1
        fi
        log "Using talosctl ${TALOS_VERSION} from $(which talosctl)"
    else
        log "Using local talosctl ${TALOS_VERSION}"
    fi

    # Kubectl Version Check
    if ! command -v kubectl &> /dev/null || [[ "$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion')" != "${KUBECTL_VERSION}" ]]; then
        if [ -f "${TOOLS_DIR}/kubectl" ] && [[ "$("${TOOLS_DIR}/kubectl" version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion')" == "${KUBECTL_VERSION}" ]]; then
             log "Using cached kubectl from ${TOOLS_DIR}"
        else
            log "kubectl not found or warning: version mismatch (Want ${KUBECTL_VERSION}). Downloading..."
            
            local OS=$(uname -s | tr '[:upper:]' '[:lower:]')

            if ! curl -Lo "${TOOLS_DIR}/kubectl" "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${OS}/${ARCH}/kubectl"; then
                 warn "Failed to download kubectl ${KUBECTL_VERSION}. Continuing with existing version if any."
            else
                 chmod +x "${TOOLS_DIR}/kubectl"
                 log "Downloaded kubectl to ${TOOLS_DIR}"
            fi
        fi
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
    
    # 1. Calculate Required CPUs
    local REQUIRED_CPUS_TOTAL=0
    local REQUIRED_N2_CPUS=0
    
    # Bastion (e2-micro/small ~ 2 vCPU safe estimate)
    REQUIRED_CPUS_TOTAL=$((REQUIRED_CPUS_TOTAL + 2))

    # Control Plane
    # helper to extract vcpu count from machine type string
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
        else
             # Default fallback for unknown standard types (e.g. e2-medium=2)
             echo "2" 
        fi
    }

    local cp_vcpu
    cp_vcpu=$(get_vcpu_count "${CP_MACHINE_TYPE}")
    REQUIRED_CPUS_TOTAL=$((REQUIRED_CPUS_TOTAL + (cp_vcpu * CP_COUNT)))
    
    # Check if CP is N2
    if [[ "${CP_MACHINE_TYPE}" == n2-* ]]; then
        REQUIRED_N2_CPUS=$((REQUIRED_N2_CPUS + (cp_vcpu * CP_COUNT)))
    fi

    # Workers
    local worker_vcpu
    worker_vcpu=$(get_vcpu_count "${WORKER_MACHINE_TYPE}")
    REQUIRED_CPUS_TOTAL=$((REQUIRED_CPUS_TOTAL + (worker_vcpu * WORKER_COUNT)))

    # Check if Worker is N2
    if [[ "${WORKER_MACHINE_TYPE}" == n2-* ]]; then
        REQUIRED_N2_CPUS=$((REQUIRED_N2_CPUS + (worker_vcpu * WORKER_COUNT)))
    fi
    
    log "Required vCPUs: Total=${REQUIRED_CPUS_TOTAL}, N2=${REQUIRED_N2_CPUS}"

    # 2. Get Quota using jq
    if ! command -v jq &> /dev/null; then warn "jq not found, skipping quota check."; return; fi
    
    local REGION_INFO
    REGION_INFO=$(gcloud compute regions describe "${REGION}" --project="${PROJECT_ID}" --format="json" 2>/dev/null || echo "")
    
    if [ -z "$REGION_INFO" ]; then
        warn "Could not read region info. Billing might be disabled or permissions missing."
        return
    fi

    # Helper to check a specific metric
    check_metric() {
        local metric_name="$1"
        local required="$2"
        
        [ "$required" -eq 0 ] && return 0

        local available
        available=$(echo "$REGION_INFO" | jq -r --arg metric "$metric_name" '
            ([.quotas[] | select(.metric == $metric)][0] | .limit // 0) as $limit |
            ([.quotas[] | select(.metric == $metric)][0] | .usage // 0) as $usage |
            ($limit - $usage) | floor
        ')
        
        log "Quota '${metric_name}': Available=${available}, Required=${required}"
        
        if [ "$available" -lt "$required" ]; then
            error "Insufficient '${metric_name}' Quota in ${REGION}."
            error "Available: ${available}, Required: ${required}"
            error "Please request a quota increase."
            return 1
        fi
    }

    # Check Global CPUS (Standard)
    check_metric "CPUS" "$REQUIRED_CPUS_TOTAL" || exit 1
    
    # Check N2 CPUS if needed
    if [ "$REQUIRED_N2_CPUS" -gt 0 ]; then
         check_metric "N2_CPUS" "$REQUIRED_N2_CPUS" || exit 1
    fi
    
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
