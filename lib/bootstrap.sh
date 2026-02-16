
#!/bin/bash

# --- Phase 5: Register/Bootstrap ---

# --- Phase 5: Register/Bootstrap (Split) ---

# 5a. Bootstrap Etcd & Kubeconfig
bootstrap_etcd() {
    log "Phase 7: Bootstrapping Etcd..."
    
    # Ensure variables are set
    set_names
    
    # 1. Get Control Plane IP (Bootstrap Node)
    # CRITICAL: We MUST use the Instance IP directly (e.g. cp-0) for bootstrap.
    # Why?
    #   GCP Internal LBs (VIP) forward packets to the backend instance with Dst=VIP.
    #   The backend instance (Talos) will DROP these packets unless the VIP is configured on an interface (e.g. lo).
    #   But we configure the VIP on 'lo' via a DaemonSet in Phase 8 (provision_k8s_networking).
    #   Phase 7 (Bootstrap) happens BEFORE Phase 8.
    #   Therefore, we cannot access the API via VIP yet. We must bypass the LB.
    
    local CP_ENDPOINT_IP=""
    local cp_0_name="${CLUSTER_NAME}-cp-0"
    
    log "Resolving Bootstrap Endpoint (Instance: ${cp_0_name})..."
    
    # Try fetching Instance IP (Retry logic in case it's not ready)
    for i in {1..10}; do
        CP_ENDPOINT_IP=$(gcloud compute instances describe "${cp_0_name}" --zone "${ZONE}" --format="value(networkInterfaces[0].networkIP)" --project="${PROJECT_ID}" 2>/dev/null || echo "")
        if [ -n "$CP_ENDPOINT_IP" ]; then
            log "DEBUG: Resolved CP_ENDPOINT_IP (Node)=${CP_ENDPOINT_IP}"
            break
        fi
        log "Waiting for Control Plane Node IP... (Attempt $i/10)"
        sleep 3
    done
    
    if [ -z "$CP_ENDPOINT_IP" ]; then
        error "Could not determine Control Plane Node IP."
        exit 1
    fi
    
    log "Bootstrapping against Endpoint: ${CP_ENDPOINT_IP}"
    
    log "Preparing bootstrap script..."
    # Use structured paths to keep HOME clean ($HOME/.talos/config)
    # Phase 4 should have already populated ~/.talos/config
    cat <<EOF > "${OUTPUT_DIR}/bootstrap_cluster.sh"
#!/bin/bash
mkdir -p ~/.talos ~/.kube
TALOSCONFIG=~/.talos/config

if [ ! -f "\$TALOSCONFIG" ]; then
    echo "Error: \$TALOSCONFIG not found. Did Phase 4 fail?"
    # Fallback: check CWD just in case
    if [ -f "talosconfig" ]; then
        echo "Found talosconfig in CWD, moving to \$TALOSCONFIG"
        mv talosconfig "\$TALOSCONFIG"
    else
        exit 1
    fi
fi

talosctl --talosconfig "\$TALOSCONFIG" config endpoint ${CP_ENDPOINT_IP}
talosctl --talosconfig "\$TALOSCONFIG" config node ${CP_ENDPOINT_IP}
echo "Bootstrapping Cluster..."
# Bootstrap can race with node readiness, retry it
for i in {1..60}; do
    OUTPUT=\$(talosctl --talosconfig "\$TALOSCONFIG" bootstrap 2>&1)
    EXIT_CODE=\$?

    if [ \$EXIT_CODE -eq 0 ]; then
        echo "Bootstrap command sent successfully."
        break
    elif echo "\$OUTPUT" | grep -q "AlreadyExists"; then
        echo "Cluster is already bootstrapped (etcd data exists). Proceeding..."
        break
    fi

    echo "Talos API not yet ready for bootstrap (node booting/services starting)... (Attempt \$i/60, max 5m)"
    echo "Last Error: \$OUTPUT"
    sleep 5
done

echo "Waiting for kubeconfig generation (certificate signing)..."
for i in {1..60}; do
    # Save to ~/.kube/config directly (Updated/Verified)
    if talosctl --talosconfig "\$TALOSCONFIG" kubeconfig ~/.kube/config; then
        echo "Kubeconfig retrieved successfully!"
        # Set permissions for security
        chmod 600 ~/.kube/config
        exit 0
    fi
    echo "Waiting for API Server to provide Kubeconfig... (Attempt \$i/60, max 10m)"
    sleep 10
done
echo "Failed to retrieve kubeconfig."
exit 1
EOF
    chmod +x "${OUTPUT_DIR}/bootstrap_cluster.sh"

    log "Pushing configs to Bastion..."
    # Only copy the bootstrap script. configs are handled by phase4.
    run_safe retry gcloud compute scp "${OUTPUT_DIR}/bootstrap_cluster.sh" "${BASTION_NAME}:~" --zone "${ZONE}" --tunnel-through-iap
    
    log "Executing bootstrap on Bastion..."
    run_safe retry gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "./bootstrap_cluster.sh && rm bootstrap_cluster.sh"
    
    log "Retrieving kubeconfig..."
    # Retrieve from structured path
    run_safe gcloud compute scp "${BASTION_NAME}:~/.kube/config" "${OUTPUT_DIR}/kubeconfig" --zone "${ZONE}" --tunnel-through-iap
    
    # Secure the kubeconfig
    chmod 600 "${OUTPUT_DIR}/kubeconfig" "${OUTPUT_DIR}/talosconfig"

    # Export KUBECONFIG for subsequent kubectl commands in THIS shell context
    # Note: Dependent functions must check for KUBECONFIG var or file presence
    export KUBECONFIG="${OUTPUT_DIR}/kubeconfig"
}

# 5b. Provision K8s Networking (CNI & VIP)
provision_k8s_networking() {
    log "Phase 8: K8s Networking (CNI)..."
    
    # Ensure KUBECONFIG is set (redundant check for safety)
    if [ -z "${KUBECONFIG:-}" ]; then
        export KUBECONFIG="${OUTPUT_DIR}/kubeconfig"
    fi

    # Deploy VIP Alias (Fixes Node IP issue by adding VIP to lo via DaemonSet)
    deploy_vip_alias

    # Deploy CNI (Cilium)
    # CRITICAL: We deploy Cilium BEFORE CCM so that:
    # 1. Cilium agents start and register the node.
    # 2. Cilium waiting for PodCIDR is expected.
    # 3. We use the ILB IP for k8sServiceHost which we verified exists.
    deploy_cni || return 1
}

# 5c. Provision K8s Addons (CCM & CSI)
provision_k8s_addons() {
    log "Phase 9: K8s Addons (CCM & CSI)..."
    
    # Ensure KUBECONFIG is set
    if [ -z "${KUBECONFIG:-}" ]; then
        export KUBECONFIG="${OUTPUT_DIR}/kubeconfig"
    fi

    # Deploy CCM (Must be AFTER CNI starts basic networking, but handles IPAM)
    # The CCM will assign PodCIDRs, unblocking Cilium.
    deploy_ccm

    # Deploy CSI
    if [ "${INSTALL_CSI}" == "true" ]; then
        # Wait for Nodes to be Ready before deploying CSI
        # This prevents CSI Controller from being Pending forever if nodes aren't ready
        log "Waiting for nodes to be Ready before deploying CSI..."
        run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl wait --for=condition=Ready nodes --all --timeout=300s || echo 'Warning: Nodes not yet ready, proceeding anyway...'"
        deploy_csi
    fi

    # 4. Verify IPAM Alignment (Split-Brain Check)
    # Ensure source lib/verify.sh is available (it should be via talos-gcp main script, but verify.sh contains the function)
    if command -v verify_gcp_alignment &>/dev/null; then
         verify_gcp_alignment || true
    else
         # Fallback if verify.sh not sourced in this scope (should act as library)
         # We expect verify.sh to be sourced by the main script.
         warn "verify_gcp_alignment function not found. Skipping IPAM check."
    fi
}

# 5d. Finalize Bastion Config
finalize_bastion_config() {
    log "Phase 11: Finalizing Bastion Configs..."
    
    # Final Step: Sync updated configs to /etc/skel for future admins
    # We revert talosconfig endpoint to VIP (ILB) before syncing, so admins use the stable address
    # (Bootstrap used Node IP, but we want VIP for long-term use)
    local CP_ILB_IP=$(gcloud compute addresses describe "${ILB_CP_IP_NAME}" --region "${REGION}" --format="value(address)" --project="${PROJECT_ID}")
    
    if [ -z "$CP_ILB_IP" ]; then
        error "Could not resolve Control Plane VIP (ILB IP). Cannot finalize Bastion config."
        exit 1
    fi
    
    log "Finalizing /etc/skel configuration..."
    run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "
        # 1. Revert talosconfig to use VIP
        talosctl --talosconfig ~/.talos/config config endpoint ${CP_ILB_IP}
        talosctl --talosconfig ~/.talos/config config node ${CP_ILB_IP}

        # 2. Sync to /etc/skel
        sudo mkdir -p /etc/skel/.kube /etc/skel/.talos
        sudo cp ~/.kube/config /etc/skel/.kube/config
        sudo cp ~/.talos/config /etc/skel/.talos/config
        
        # 3. Secure permissions (600 = Owner only)
        sudo chmod -R 755 /etc/skel/.kube /etc/skel/.talos
        sudo chmod 600 /etc/skel/.kube/config /etc/skel/.talos/config ~/.talos/config ~/.kube/config
    "
}
