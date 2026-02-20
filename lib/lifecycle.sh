#!/bin/bash

# --- Phase 4: Lifecycle Management ---


apply() {
    set_names
    check_dependencies || return 1
    check_permissions || return 1
    # check_quotas is optional but recommended
    check_quotas || return 1
    
    # Validation
    check_rook_config || return 1
    
    log "Updating Cluster Configuration..."
    log "Node Pools: ${NODE_POOLS[*]}"
    
    # Ensure Output Directory exists (Critical for generated files)
    mkdir -p "${OUTPUT_DIR}"
    
    # Ensure Images exist (create if missing, skip if present)
    ensure_role_images || return 1
    
    # Ensure Service Account exists
    ensure_service_account || return 1
    check_sa_key_limit || return 1
    
    # Reconcile Control Plane (Networking, Configs, Nodes)
    # This ensures networking is ready, configs are generated, and CP nodes are created/checked.
    provision_controlplane_infra || return 1
    
    # Reconcile Workers (Create missing, Prune extra)
    provision_workers || return 1
    
    # 2b. Apply Node Pool Labels/Taints
    apply_node_pool_labels
    
    # 2c. Rook Ceph (Optional - Automation coverage)
    if [ "${ROOK_ENABLE}" == "true" ]; then
        source "${SCRIPT_DIR}/lib/rook.sh"
        deploy_rook || return 1
    fi

    # Peering
    if type reconcile_peering &>/dev/null; then
         reconcile_peering
    fi

    if [ ${#ROOK_EXTERNAL_CLUSTERS[@]} -gt 0 ]; then
        for EXT_CLUSTER in "${ROOK_EXTERNAL_CLUSTERS[@]:-}"; do
            # Ensure we are peered (optional warning)
            if [[ ! " ${PEER_WITH[@]:-} " =~ " ${EXT_CLUSTER} " ]]; then
                warn "ROOK_EXTERNAL_CLUSTER '${EXT_CLUSTER}' is set, but it is not in PEER_WITH. Network connectivity might fail."
            fi
        done
        source "${SCRIPT_DIR}/lib/rook-external.sh"
        deploy_rook_client || return 1
    fi
    
    # Update Schedule (Work Hours)
    # Update Schedule (Work Hours)
    update_schedule
    
    # 2d. Fix Aliases (Ensure sync)
    if [ "${CILIUM_ROUTING_MODE:-}" == "native" ]; then
        fix_aliases || warn "Alias fix failed, but continuing."
    fi
    
    log "Apply complete. Run 'talos-gcp status' to verify."
    status
}


deploy_all() {
    set_names
    check_dependencies || return 1
    check_permissions || return 1
    check_quotas || return 1
    check_rook_config || return 1

    
    log "Starting Full Deployment for cluster '${CLUSTER_NAME}'..."
    
    # 1. Prerequisites
    ensure_role_images || return 1
    ensure_service_account || return 1
    
    # 2. Core Infrastructure (Network + Control Plane)
    # provision_controlplane_infra handles networking, ILB, Secrets, Configs, and CP Nodes
    provision_controlplane_infra || return 1
    
    # 3. Bastion
    provision_bastion || return 1
    
    # 4. Bootstrap (Wait for API)
    # bootstrap_cluster is in lib/bootstrap.sh
    bootstrap_cluster || return 1
    
    # 5. Configure Bastion (Needs Kubeconfig/Talosconfig)
    configure_bastion || return 1

    # 5.5 K8s Addons (CCM) - Must be before CNI for Native Routing IPAM
    deploy_ccm || return 1
    wait_for_ccm || return 1

    # 5.6 K8s Networking (CNI)
    # provision_k8s_networking is in lib/bootstrap.sh
    provision_k8s_networking || return 1
    
    # 5.7 CSI Driver
    if [ "${INSTALL_CSI:-true}" == "true" ]; then
        deploy_csi || return 1
    fi
    
    # 6. Workers
    # Check for Zombies before provisioning workers (to avoid name collisions or stale nodes)
    check_zombies || warn "Zombie check failed, but proceeding."
    
    provision_workers || return 1
    
    # 7. Peering
    if type reconcile_peering &>/dev/null; then
         reconcile_peering
    fi

    if [ ${#ROOK_EXTERNAL_CLUSTERS[@]} -gt 0 ]; then
        for EXT_CLUSTER in "${ROOK_EXTERNAL_CLUSTERS[@]:-}"; do
            # Ensure we are peered (optional warning)
            if [[ ! " ${PEER_WITH[@]:-} " =~ " ${EXT_CLUSTER} " ]]; then
                warn "ROOK_EXTERNAL_CLUSTER '${EXT_CLUSTER}' is set, but it is not in PEER_WITH. Network connectivity might fail."
            fi
        done
        source "${SCRIPT_DIR}/lib/rook-external.sh"
        deploy_rook_client || return 1
    fi

    # 8. Finalize
    apply_node_pool_labels
    apply_node_pool_labels

    # 8. Rook Ceph (Optional - Automation coverage)
    if [ "${ROOK_ENABLE}" == "true" ]; then
        source "${SCRIPT_DIR}/lib/rook.sh"
        deploy_rook || return 1
    fi

    update_schedule
    
    # 9. Fix Aliases (Ensure sync)
    if [ "${CILIUM_ROUTING_MODE:-}" == "native" ]; then
        fix_aliases || warn "Alias fix failed, but continuing."
    fi
    
    log "Deployment Complete."
    access_info
}
