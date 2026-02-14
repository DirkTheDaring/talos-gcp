#!/bin/bash

# Default Configuration (Can be overridden by cluster.env or env vars)
CLUSTER_NAME="${CLUSTER_NAME:-talos-gcp-cluster}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-${REGION}-b}"
ARCH="${ARCH:-amd64}"

# Versions
TALOS_VERSION="${TALOS_VERSION:-v1.12.3}"
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.35.0}"
# Strict jq checking is in lib/utils.sh - make sure to install jq!
# Global Variables
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then ARCH="amd64"; fi
if [[ "$ARCH" == "aarch64" ]]; then ARCH="arm64"; fi
export ARCH

HELM_VERSION="${HELM_VERSION:-v3.16.2}"
CILIUM_VERSION="${CILIUM_VERSION:-1.18.6}"
TRAEFIK_VERSION="${TRAEFIK_VERSION:-38.0.2}"

# Rook Ceph Defaults
ROOK_ENABLE="${ROOK_ENABLE:-false}"
ROOK_CHART_VERSION="${ROOK_CHART_VERSION:-v1.18.9}"
ROOK_MDS_CPU="${ROOK_MDS_CPU:-3}"           # Default: Production (Recommended)
ROOK_MDS_MEMORY="${ROOK_MDS_MEMORY:-4Gi}"   # Default: Production (Recommended)
ROOK_OSD_CPU="${ROOK_OSD_CPU:-1}"           # Default: 1 vCPU per OSD
ROOK_OSD_MEMORY="${ROOK_OSD_MEMORY:-2Gi}"   # Default: 2Gi per OSD

# Mixed Role Versions (Default to global TALOS_VERSION)
CP_TALOS_VERSION="${CP_TALOS_VERSION:-$TALOS_VERSION}"
WORKER_TALOS_VERSION="${WORKER_TALOS_VERSION:-$TALOS_VERSION}"

# Extensions (Comma-separated, e.g. "siderolabs/gvisor,siderolabs/nvidia-container-toolkit")
# Extensions (Comma-separated, e.g. "siderolabs/gvisor,siderolabs/nvidia-container-toolkit")
CP_EXTENSIONS="${CP_EXTENSIONS:-}"
WORKER_EXTENSIONS="${WORKER_EXTENSIONS:-}"
POOL_EXTENSIONS="${POOL_EXTENSIONS:-$WORKER_EXTENSIONS}"

# Kernel Args (Comma-separated or space-separated, e.g. "console=ttyS0,115200")
CP_KERNEL_ARGS="${CP_KERNEL_ARGS:-}"
WORKER_KERNEL_ARGS="${WORKER_KERNEL_ARGS:-}"
POOL_KERNEL_ARGS="${POOL_KERNEL_ARGS:-$WORKER_KERNEL_ARGS}"

# Network
VPC_NAME="${VPC_NAME:-${CLUSTER_NAME}-vpc}"
SUBNET_NAME="${SUBNET_NAME:-${CLUSTER_NAME}-subnet}"
SUBNET_RANGE="${SUBNET_RANGE:-10.100.0.0/20}"  # Default: Nodes
POD_CIDR="${POD_CIDR:-10.200.0.0/14}"          # Default: Pods (Alias IPs)
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/20}"   # Default: Services
# Storage CIDR (Multi-NIC) - Default Empty (Opt-in)
STORAGE_CIDR="${STORAGE_CIDR:-}"

# Compute
CP_MACHINE_TYPE="${CP_MACHINE_TYPE:-e2-standard-2}"
CP_USE_STORAGE_NETWORK="${CP_USE_STORAGE_NETWORK:-false}"

# Worker Configuration
CP_DISK_SIZE="${CP_DISK_SIZE:-200GB}"
CP_COUNT="${CP_COUNT:-1}"
# Worker defaults are now handled per-pool in workers.sh or via POOL_* vars

# Default to single "worker" pool if NODE_POOLS is unset (Implicit Default)
if [ -z "${NODE_POOLS:-}" ]; then
    NODE_POOLS=("worker")
fi


# Features
INSTALL_CILIUM="${INSTALL_CILIUM:-true}"
INSTALL_HUBBLE="${INSTALL_HUBBLE:-true}"
INSTALL_CSI="${INSTALL_CSI:-true}"

# Cilium Configuration (tunnel vs native)
CILIUM_ROUTING_MODE="${CILIUM_ROUTING_MODE:-native}"
CILIUM_NATIVE_CIDR="${CILIUM_NATIVE_CIDR:-$POD_CIDR}"

# Ingress
# Default: Empty
# Ingress Defaults
INGRESS_IP_COUNT="${INGRESS_IP_COUNT:-1}"
INGRESS_IPV4_CONFIG="${INGRESS_IPV4_CONFIG:-}"

# Custom Worker Ports (e.g. for WebRTC or other external services)
WORKER_OPEN_TCP_PORTS="${WORKER_OPEN_TCP_PORTS:-}"     # e.g. "30000-32767"
WORKER_OPEN_UDP_PORTS="${WORKER_OPEN_UDP_PORTS:-}"     # e.g. "30000-32767"
WORKER_OPEN_SOURCE_RANGES="${WORKER_OPEN_SOURCE_RANGES:-0.0.0.0/0}"

# Labels (Default: Empty)
LABELS="${LABELS:-}"

# Work Hours Schedule
# Uses GCP Resource Policies (Instance Schedules)
# WORK_HOURS_START/STOP format: HH:MM (24h)
WORK_HOURS_START="${WORK_HOURS_START:-}"       # e.g. "08:00"
WORK_HOURS_STOP="${WORK_HOURS_STOP:-}"         # e.g. "18:00"
WORK_HOURS_DAYS="${WORK_HOURS_DAYS:-Mon-Fri}"  # e.g. "Mon-Fri", "Mon-Sat", "Mon,Wed,Fri"

# Timezone (Auto-detect if unset)
if [ -z "${WORK_HOURS_TIMEZONE:-}" ]; then
    # We call detect_timezone from utils.sh, but we must ensure utils.sh is sourced.
    # config.sh is usually sourced AFTER utils.sh in talos-gcp, but safer to check.
    if command -v detect_timezone &>/dev/null; then
        WORK_HOURS_TIMEZONE=$(detect_timezone "${REGION}")
    else
        # Fallback if utils.sh not loaded yet (shouldn't happen in main script)
        WORK_HOURS_TIMEZONE="UTC"
    fi
fi
export WORK_HOURS_TIMEZONE

# Peering Configuration (Default: Empty)
PEER_WITH=()


# Check & Default CLUSTER_NAME
check_cluster_name() {
    if [ -z "${CLUSTER_NAME:-}" ]; then
        warn "CLUSTER_NAME is not set. Defaulting to 'talos-gcp-cluster'."
        warn "To deploy a separate cluster, run: export CLUSTER_NAME='my-cluster'"
        export CLUSTER_NAME="talos-gcp-cluster"
    fi

    # Validate Length (Max 20 chars to allow suffixes like -bastion-ssh, -sa without hitting GCP limits)
    if [ ${#CLUSTER_NAME} -gt 20 ]; then
        error "CLUSTER_NAME '${CLUSTER_NAME}' is too long (${#CLUSTER_NAME} chars). Max 20 characters allowed."
        error "This allows appending suffixes for Service Accounts (max 30 chars)."
        exit 1
    fi
}

# Calculate Resource Names based on CLUSTER_NAME
set_names() {
    check_cluster_name
    
    # Ensure BUCKET_NAME is set (defaults to project-id-talos-images if not provided)
    if [ -z "${BUCKET_NAME:-}" ]; then
         BUCKET_NAME="${PROJECT_ID}-talos-images"
    fi

    # Network Resources
    VPC_NAME="${CLUSTER_NAME}-vpc"
    SUBNET_NAME="${CLUSTER_NAME}-subnet"
    ROUTER_NAME="${CLUSTER_NAME}-router"
    NAT_NAME="${CLUSTER_NAME}-nat"
    
    # Storage Network (Multi-NIC)
    # Only set if STORAGE_CIDR is active
    if [ -n "${STORAGE_CIDR:-}" ]; then
        VPC_STORAGE_NAME="${CLUSTER_NAME}-storage-vpc"
        SUBNET_STORAGE_NAME="${CLUSTER_NAME}-storage-subnet"
        FW_STORAGE_INTERNAL="${CLUSTER_NAME}-storage-internal"
    fi
    
    # Instance Group
    IG_CP_NAME="${CLUSTER_NAME}-ig-cp"
    IG_WORKER_NAME="${CLUSTER_NAME}-ig-worker"

    # Bastion Image
    BASTION_IMAGE_FAMILY="${BASTION_IMAGE_FAMILY:-ubuntu-2404-lts-amd64}"
    BASTION_IMAGE_PROJECT="${BASTION_IMAGE_PROJECT:-ubuntu-os-cloud}"
    
    # Firewall Rules
    FW_BASTION="${CLUSTER_NAME}-bastion-ssh"
    FW_INTERNAL="${CLUSTER_NAME}-internal"
    FW_HEALTH="${CLUSTER_NAME}-healthcheck"
    FW_INGRESS_BASE="${CLUSTER_NAME}-ingress"
    FW_BASTION_INTERNAL="${CLUSTER_NAME}-bastion-internal"
    FW_WORKER_CUSTOM="${CLUSTER_NAME}-worker-custom"
    
    # Load Balancer Resources
    HC_CP_NAME="${CLUSTER_NAME}-cp-hc"
    BE_CP_NAME="${CLUSTER_NAME}-cp-be"
    ILB_CP_IP_NAME="${CLUSTER_NAME}-cp-ilb-ip"
    ILB_CP_RULE="${CLUSTER_NAME}-cp-ilb-rule"
    HC_WORKER_NAME="${CLUSTER_NAME}-worker-hc"
    BE_WORKER_NAME="${CLUSTER_NAME}-worker-be"
    HC_WORKER_UDP_NAME="${CLUSTER_NAME}-worker-udp-hc"
    BE_WORKER_UDP_NAME="${CLUSTER_NAME}-worker-udp-be"
    
    # Instances
    BASTION_NAME="${CLUSTER_NAME}-bastion"
    # Control/Worker prefixes are dynamic in loops, but we can define base
    # e.g. talos-controlplane-N -> ${CLUSTER_NAME}-cp-N
    
    # Service Account (Truncate if needed, but check_cluster_name enforces <20 so -sa is safe)
    # -------------------------------------------------------------------------
    # SA Name Generation Strategy:
    # 0. Allow explicit override via export SA_NAME="..."
    # 1. Legacy: CLUSTER_NAME-sa
    # 2. Resilient: CLUSTER_NAME-REGION_HASH-sa (Avoids conflicts)
    
    if [ -z "${SA_NAME:-}" ]; then
        local LEGACY_SA_NAME="${CLUSTER_NAME}-sa"
        local HAS_LEGACY=""

        # Check if Legacy SA exists (Only if PROJECT_ID is available)
        if [ -n "${PROJECT_ID:-}" ]; then
            if gcloud iam service-accounts list --filter="email:${LEGACY_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" --format="value(email)" --project="${PROJECT_ID}" 2>/dev/null | grep -q "${LEGACY_SA_NAME}"; then
                HAS_LEGACY="true"
            fi
        fi

        if [ "$HAS_LEGACY" == "true" ]; then
             SA_NAME="${LEGACY_SA_NAME}"
        else
             # Generate short hash of region
             local R_HASH="0000" # Safe default
             if command -v md5sum &>/dev/null; then
                 R_HASH=$(echo -n "${REGION}" | md5sum | cut -c1-4)
             elif command -v cksum &>/dev/null; then
                 R_HASH=$(echo -n "${REGION}" | cksum | cut -c1-4 | tr -d ' ')
             fi
             
             # Ensure R_HASH didn't end up empty due to pipe failure
             if [ -z "$R_HASH" ]; then R_HASH="0000"; fi
             
             SA_NAME="${CLUSTER_NAME}-${R_HASH}-sa"
        fi
    fi

    SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
    
    # Role-specific Service Accounts (Default to the main cluster SA)
    CP_SERVICE_ACCOUNT="${CP_SERVICE_ACCOUNT:-$SA_EMAIL}"
    WORKER_SERVICE_ACCOUNT="${WORKER_SERVICE_ACCOUNT:-$SA_EMAIL}"
    
    # Schedulers
    # Instance Schedule Policy (Zonal/Regional)
    # Note: Resource Policies are Regional or Zonal. Instance Schedules are Regional in API but attached Zonally?
    # Actually, `gcloud compute resource-policies create instance-schedule` requires --region.
    SCHEDULE_POLICY_NAME="${CLUSTER_NAME}-schedule"    
    # Directory Isolation
    OUTPUT_DIR="$(pwd)/_out/${CLUSTER_NAME}"
    export OUTPUT_DIR
    mkdir -p "${OUTPUT_DIR}"
    
    # Namespaced GCS Paths
    GCS_SECRETS_URI="gs://${BUCKET_NAME}/${CLUSTER_NAME}/secrets.yaml"

    # Legacy cleanup variables (To prevent 'unbound variable' errors in cleanup)
    FWD_RULE="${CLUSTER_NAME}-fwd-rule"
    LB_IP_NAME="${CLUSTER_NAME}-lb-ip"
    PROXY_NAME="${CLUSTER_NAME}-proxy"
    BE_NAME="${CLUSTER_NAME}-be"
    HC_NAME="${CLUSTER_NAME}-hc"

    IG_NAME="${CLUSTER_NAME}-ig"

    # Talos Image Name (Global)
    # Replaces dots with dashes for GCP Image Name compatibility (e.g. v1.12.3 -> talos-v1-12-3-amd64)
    local safe_version="${TALOS_VERSION//./-}"
    TALOS_IMAGE_NAME="talos-${safe_version}-gcp-${ARCH}"
}
