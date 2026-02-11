#!/bin/bash

# Generate Access Instructions for Developers
access_info() {
    set_names
    check_dependencies
    
    log "Retrieving access information for cluster '${CLUSTER_NAME}'..."
    
    # Get Control Plane IP (Internal Load Balancer)
    local cp_ip
    if ! cp_ip=$(gcloud compute addresses describe "${ILB_CP_IP_NAME}" --region="${REGION}" --project="${PROJECT_ID}" --format="value(address)" 2>/dev/null); then
        error "Could not retrieve Control Plane IP (${ILB_CP_IP_NAME}). Is the cluster deployed?"
        return 1
    fi
    
    echo ""
    echo "================================================================================"
    echo "                   Developer Access Instructions"
    echo "================================================================================"
    echo ""
    echo "Cluster: ${CLUSTER_NAME}"
    echo "Region:  ${REGION}"
    echo "Zone:    ${ZONE}"
    echo "Project: ${PROJECT_ID}"
    echo ""
    echo "To access the PRIVATE Talos/K8s API, you must open a secure tunnel via the Bastion."
    echo ""
    echo "--------------------------------------------------------------------------------"
    echo "STEP 1: Open the Tunnel"
    echo "--------------------------------------------------------------------------------"
    echo "Run the following command in a dedicated terminal window. Keep it open."
    echo ""
    echo "gcloud compute ssh ${BASTION_NAME} \\"
    echo "    --zone ${ZONE} \\"
    echo "    --project ${PROJECT_ID} \\"
    echo "    --tunnel-through-iap \\"
    echo "    -- -L 64430:${cp_ip}:6443 -L 50005:${cp_ip}:50000 -N"
    echo ""
    echo "--------------------------------------------------------------------------------"
    echo "STEP 2: Use Tools (In a new terminal)"
    echo "--------------------------------------------------------------------------------"
    echo ""
    echo ">>> Talos (talosctl)"
    echo "    # Using local port 50005 -> remote 50000"
    echo "    talosctl -n 127.0.0.1 -e 127.0.0.1:50005 dashboard"
    echo ""
    echo ">>> Kubernetes (kubectl)"
    echo "    # Using local port 64430 -> remote 6443"
    echo "    kubectl --server=https://127.0.0.1:64430 get nodes"
    echo ""
    echo "================================================================================"
    echo ""
}
