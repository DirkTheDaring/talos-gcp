#!/bin/bash

# --- Phase 4: Operational Commands ---

update_ports() {
    set_names
    log "Updating Ingress Ports for cluster '${CLUSTER_NAME}'..."
    log "Configuration: INGRESS_IPV4_CONFIG='${INGRESS_IPV4_CONFIG}'"
    apply_ingress
    log "Port update complete."
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
