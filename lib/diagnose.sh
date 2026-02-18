
diagnose_network() {
    log "Running Network Diagnostics..."
    
    # 1. CIDR Information
    log "--- CIDR Configuration ---"
    # Try to get from Cilium ConfigMap first as it's the source of truth for CNI
    if run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl -n kube-system get cm cilium-config -o yaml" > /tmp/cilium_config_dump.yaml 2>/dev/null; then
        local native_cidr=$(grep "ipv4-native-routing-cidr" /tmp/cilium_config_dump.yaml | awk '{print $2}' | tr -d '"')
        local ipam_mode=$(grep "ipam:" -A 1 /tmp/cilium_config_dump.yaml | grep "mode" | awk '{print $2}')
        log "Cilium Native Routing CIDR: ${native_cidr:-Not Set}"
        log "Cilium IPAM Mode: ${ipam_mode}"
    else
        warn "Could not retrieve Cilium ConfigMap."
    fi

    # talosctl config info (Machine Config) - requires a node IP
    local first_node_ip=$(gcloud compute instances list --filter="name~${CLUSTER_NAME}-cp-0" --format="value(networkInterfaces[0].networkIP)" --project="${PROJECT_ID}")
    if [ -n "$first_node_ip" ]; then
        log "Checking Node Configuration on ${first_node_ip}..."
        if run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "talosctl -n ${first_node_ip} get machineconfig -o yaml" > /tmp/mc.yaml 2>/dev/null; then
             local pod_sub=$(grep "podSubnets" -A 1 /tmp/mc.yaml | grep "-" | awk '{print $2}')
             local svc_sub=$(grep "serviceSubnets" -A 1 /tmp/mc.yaml | grep "-" | awk '{print $2}')
             log "Talos Pod Subnets: ${pod_sub}"
             log "Talos Service Subnets: ${svc_sub}"
             
             # 2. VIP Information
             local vip=$(grep "apiServer:" -A 5 /tmp/mc.yaml | grep "certSANs" -A 5 | grep -v "certSANs" | head -n 1 | awk '{print $2}')
             log "Cluster VIP (API CertSANs): ${vip}"
        else
             warn "Could not retrieve MachineConfig from ${first_node_ip}"
        fi
    fi

    # 3. Alias Configuration (GCP)
    log "--- GCP Node Alias Configuration ---"
    gcloud compute instances list --filter="name~${CLUSTER_NAME}-.*" --project="${PROJECT_ID}" --format="table(name,networkInterfaces[0].networkIP,networkInterfaces[0].aliasIpRanges.list():label=ALIAS_RANGES,status)"

    # 4. Routing Table (Sample Node)
    log "--- Host Routing Table (Sample: ${first_node_ip}) ---"
    if [ -n "$first_node_ip" ]; then
        run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "talosctl -n ${first_node_ip} read /proc/net/route" || warn "Failed to read route table"
    fi

    # 5. Cilium Status
    log "--- Cilium Status (Quick Check) ---"
    run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl -n kube-system get ds cilium" || warn "Failed to get Cilium DS"
}

diagnose_ccm() {
    log "Diagnosing GCP Cloud Controller Manager (CCM)..."
    set_names
    
    # 1. Check Pod Status
    log "checking CCM Pod Status..."
    if ! run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl -n kube-system get pods -l k8s-app=gcp-cloud-controller-manager -o wide"; then
        warn "Failed to get CCM pods."
        return 1
    fi
    
    # 2. Fetch Logs (Last 100 lines, looking for errors)
    log "Fetching recent CCM Logs (Errors/Warnings)..."
    # We use a pattern to find the pod name dynamically
    run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "
        POD=\$(kubectl -n kube-system get pods -l k8s-app=gcp-cloud-controller-manager -o jsonpath='{.items[0].metadata.name}')
        if [ -n \"\$POD\" ]; then
            echo \"Logs for \$POD:\"
            kubectl -n kube-system logs \$POD --tail=50 | grep -iE 'error|fail|route|cidr|sync' || echo 'No obvious errors found in recent logs.'
        else
            echo 'CCM Pod not found.'
        fi
    "
}
