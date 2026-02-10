#!/bin/bash

# Default Configuration (Can be overridden by cluster.env or env vars)
CLUSTER_NAME="${CLUSTER_NAME:-talos-gcp-cluster}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-${REGION}-b}"
ARCH="${ARCH:-amd64}"

# Versions
TALOS_VERSION="${TALOS_VERSION:-v1.12.3}"
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.32.0}"
HELM_VERSION="${HELM_VERSION:-v3.16.2}"
CILIUM_VERSION="${CILIUM_VERSION:-1.18.6}"

# Network
VPC_NAME="${VPC_NAME:-${CLUSTER_NAME}-vpc}"
SUBNET_NAME="${SUBNET_NAME:-${CLUSTER_NAME}-subnet}"
SUBNET_RANGE="${SUBNET_RANGE:-10.0.0.0/24}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"

# Compute
CP_MACHINE_TYPE="${CP_MACHINE_TYPE:-e2-standard-2}"
WORKER_MACHINE_TYPE="${WORKER_MACHINE_TYPE:-e2-standard-2}"
CP_DISK_SIZE="${CP_DISK_SIZE:-200GB}"
WORKER_DISK_SIZE="${WORKER_DISK_SIZE:-200GB}"
CP_COUNT="${CP_COUNT:-1}"
WORKER_COUNT="${WORKER_COUNT:-1}"

# Features
INSTALL_CILIUM="${INSTALL_CILIUM:-true}"
INSTALL_HUBBLE="${INSTALL_HUBBLE:-true}"
INSTALL_CSI="${INSTALL_CSI:-true}"

# Ingress
# Default: Empty (Use update-traefik / CCM. If utilizing HostPort/DaemonSet, set to "80,443")
INGRESS_IPV4_CONFIG="${INGRESS_IPV4_CONFIG:-}"

# Labels (Default: Empty)
LABELS="${LABELS:-}"


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
    
    # Instance Group
    IG_CP_NAME="${CLUSTER_NAME}-ig-cp"
    IG_WORKER_NAME="${CLUSTER_NAME}-ig-worker"

    # Bastion Image
    BASTION_IMAGE_FAMILY="${BASTION_IMAGE_FAMILY:-ubuntu-2204-lts}"
    BASTION_IMAGE_PROJECT="${BASTION_IMAGE_PROJECT:-ubuntu-os-cloud}"
    
    # Firewall Rules
    FW_BASTION="${CLUSTER_NAME}-bastion-ssh"
    FW_INTERNAL="${CLUSTER_NAME}-internal"
    FW_HEALTH="${CLUSTER_NAME}-healthcheck"
    FW_INGRESS_BASE="${CLUSTER_NAME}-ingress"
    
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
    SA_NAME="${CLUSTER_NAME}-sa"
    SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
    
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
