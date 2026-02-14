#!/bin/bash
set -euo pipefail

# SCRIPT_DIR is the directory where this script resides (lib/)
SCRIPT_DIR="$(dirname "$0")"
# Root dir is one level up
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

source "${SCRIPT_DIR}/utils.sh"
# We need config to know vars
CONFIG_FILE="${1:-}"
if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# Ensure variables
CLUSTER_NAME="${CLUSTER_NAME:-talos-gcp-cluster}"
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project)}"
ZONE="${ZONE:-}"

log "Fixing IPAM Split-Brain for Cluster '${CLUSTER_NAME}'..."

# 1. Fetch GCP Alias IPs
log "Fetching GCP Alias IPs..."
# Output format: NAME IP_CIDR
GCP_MAP=$(gcloud compute instances list --filter="name:${CLUSTER_NAME}-*" --project="${PROJECT_ID}" --format="value(name,networkInterfaces[0].aliasIpRanges[0].ipCidrRange)")

# 2. Iterate and Patch
echo "$GCP_MAP" | while read -r name cidr; do
    if [ -z "$network_name" ] || [ -z "$cidr" ]; then continue; fi
    # gcloud returns name, but we need to match K8s node name.
    # Usually they match exactly.
    
    log "Processing Node: $name (GCP IP: $cidr)"
    
    # Get current K8s CIDR
    current_cidr=$("$ROOT_DIR/talos-gcp" ssh -c "$CONFIG_FILE" "kubectl get node $name -o jsonpath='{.spec.podCIDR}'" 2>/dev/null || echo "")
    
    if [ "$current_cidr" != "$cidr" ]; then
        warn "  Mismatch! K8s: '$current_cidr' != GCP: '$cidr'"
        log "  Patching Node $name..."
        
        # Patch podCIDR and podCIDRs
        # We execute this inside the bastion to avoid local auth issues
        "$ROOT_DIR/talos-gcp" ssh -c "$CONFIG_FILE" "kubectl patch node $name -p '{\"spec\":{\"podCIDR\":\"$cidr\",\"podCIDRs\":[\"$cidr\"]}}'"
        
        log "  Restarting Cilium on $name..."
        "$ROOT_DIR/talos-gcp" ssh -c "$CONFIG_FILE" "kubectl -n kube-system delete pod -l k8s-app=cilium --field-selector spec.nodeName=$name"
    else
        log "  Match. No action needed."
    fi
done

log "IPAM Fix Complete. Verifying..."
"$ROOT_DIR/talos-gcp" ssh -c "$CONFIG_FILE" "kubectl get nodes -o custom-columns=NAME:.metadata.name,PODCIDR:.spec.podCIDR"
