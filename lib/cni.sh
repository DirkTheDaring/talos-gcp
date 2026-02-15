#!/bin/bash

deploy_cilium() {
    local FORCE_UPDATE="${1:-false}"
    log "Deploying Cilium via Helm (Force: ${FORCE_UPDATE})..."
    
    # 0. Ensure Helm is installed on Bastion
    log "Ensuring Helm is installed on Bastion..."
    
    # Check if Cilium is already running to avoid redundant reinstall (unless forced)
    # We use 'timeout 10s' because if the API server (VIP) is down, this check might hang.
    # If it fails/times out, we assume it's NOT installed and proceed to install (which has the Direct IP fix).
    if [ "$FORCE_UPDATE" != "true" ]; then
        if timeout 30s gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl --kubeconfig ~/.kube/config get ds cilium -n kube-system" &> /dev/null; then
             log "Cilium is already installed (DaemonSet found). Skipping installation."
             log "Use './talos-gcp update-cilium' to force an upgrade."
             return
        fi
    fi

    run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "
        set -o pipefail
        if ! command -v helm &>/dev/null; then
            echo 'Helm not found. Installing...'
            curl -f -sL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
        else
            echo 'Helm is already installed.'
        fi
    "

    # Ensure kubeconfig is on Bastion (Critical for standalone execution)
    # We use structured path ~/.kube/config to avoid pollution
    if [ -f "${OUTPUT_DIR}/kubeconfig" ]; then
        if ! gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "test -f ~/.kube/config" &>/dev/null; then
             log "Pushing local kubeconfig to Bastion (~/.kube/config)..."
             run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "mkdir -p ~/.kube"
             run_safe gcloud compute scp "${OUTPUT_DIR}/kubeconfig" "${BASTION_NAME}:~/.kube/config" --zone "${ZONE}" --tunnel-through-iap
             run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "chmod 600 ~/.kube/config"
        fi
    else
        warn "Local kubeconfig not found. Assuming ~/.kube/config exists on Bastion."
    fi
    
    # 1. Add Repo
    run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "helm repo add cilium https://helm.cilium.io/ && helm repo update"
    
    # 2. Generate Values
    # CRITICAL: We MUST use the Internal Load Balancer IP for k8sServiceHost
    # This ensures Cilium on worker nodes can reach the API server even if
    # they are on different subnets or the CP nodes cycle.
    local CP_ILB_IP=""
    
    # Retry loop for ILB IP (it might be provisioning)
    for i in {1..12}; do
         CP_ILB_IP=$(gcloud compute addresses describe "${ILB_CP_IP_NAME}" --region "${REGION}" --format="value(address)" --project="${PROJECT_ID}" 2>/dev/null || echo "")
         if [ -n "$CP_ILB_IP" ]; then
             break
         fi
         log "Waiting for Internal Load Balancer IP... (Attempt $i/12)"
         sleep 5
    done

    if [ -z "$CP_ILB_IP" ]; then
        error "Could not determine Control Plane Internal IP for Cilium configuration."
        exit 1
    fi
    log "Using Control Plane Internal IP: ${CP_ILB_IP}"

    # Get CP-0 Direct IP for Bootstrap Access (Bypass VIP)
    local cp_0_name="${CLUSTER_NAME}-cp-0"
    local CP_0_IP=$(gcloud compute instances describe "${cp_0_name}" --zone "${ZONE}" --format="value(networkInterfaces[0].networkIP)" --project="${PROJECT_ID}")
    log "Using CP-0 Direct IP for Bootstrap: ${CP_0_IP}"

    # Note: We use specific GCP/Talos settings (IPAM kubernetes, VXLAN, KubeProxyReplacement, etc.)
    # We must substitute variables.

    # Configure Routing Mode
    local routing_mode="${CILIUM_ROUTING_MODE:-tunnel}"
    local tunnel_protocol="vxlan"
    local masquerade="true"
    local native_cidr_line=""
    local endpoint_routes=""
    local mtu_line=""
    local auto_direct_node_routes_line=""

    if [ "$routing_mode" == "native" ]; then
        log "Configuring Cilium for NATIVE Routing (GCP Alias IPs) with forced CIDR and MTU..."
        # Reverting to default (empty) as "disabled" caused crash. 
        # We rely on routingMode: native to disable encapsulation implicitly.
        tunnel_protocol_line=""
        masquerade="true"  # Enable BPF masquerade for better BPF datapath integration
        # Correctly format endpointRoutes variable with a newline
        endpoint_routes="endpointRoutes:
  enabled: true"
        mtu_line="mtu: 1460" # Native GCP MTU
        # autoDirectNodeRoutes causes issues on GCP (gateway invalid). VPC handles routing.
        auto_direct_node_routes_line="autoDirectNodeRoutes: false"
        
        # Use Standard GCP Native Routing Configuration
        # gke.enabled: true handles defaults. We just supply the correct Native CIDR.
        local native_cidr="${CILIUM_NATIVE_CIDR:-$POD_CIDR}"
        if [ -n "${native_cidr}" ]; then
            native_cidr_line="ipv4NativeRoutingCIDR: \"${native_cidr}\""
        fi
    else
        log "Configuring Cilium for TUNNEL Routing (VXLAN)..."
        tunnel_protocol_line="tunnelProtocol: vxlan"
        # Tunnel Mode: Leave MTU empty to allow Cilium to auto-detect (usually 1460-50 = 1410)
        # Setting "mtu: 1460" explicitly with VXLAN causes packet drops on GCP.
        mtu_line="" 
    fi

    cat <<EOF > "${OUTPUT_DIR}/cilium-values.yaml"
ipam:
  mode: kubernetes
# gke.enabled: true removed to avoid overriding k8sServiceCIDR
# gke:
#   enabled: true
# Critical: Match Talos Service CIDR so BPF intercepts traffic
# We use extraConfig to force it into the ConfigMap as standard value key seemingly failed
extraConfig:
  k8s-service-cidr: "172.30.0.0/20"
k8sServiceHost: "${CP_ILB_IP}"
k8sServicePort: 6443
kubeProxyReplacement: true
securityContext:
  capabilities:
    ciliumAgent:
    - CHOWN
    - KILL
    - NET_ADMIN
    - NET_RAW
    - IPC_LOCK
    - SYS_ADMIN
    - SYS_RESOURCE
    - DAC_OVERRIDE
    - FOWNER
    - SETGID
    - SETUID
    cleanCiliumState:
    - NET_ADMIN
    - SYS_ADMIN
    - SYS_RESOURCE
cgroup:
  autoMount:
    enabled: false
  hostRoot: /sys/fs/cgroup
routingMode: ${routing_mode}
${tunnel_protocol_line}
${endpoint_routes}
${native_cidr_line}
${mtu_line}
${auto_direct_node_routes_line}
debug:
  enabled: true
bpf:
  masquerade: ${masquerade}
  hostLegacyRouting: true
nodeinit:
  enabled: false
# User Requirements
envoy:
  enabled: false
EOF

    # Hubble Configuration
    if [ "${INSTALL_HUBBLE}" == "true" ]; then
        # Hubble FQDN (Optional, defaults to hubble.<cluster>.example.com if not set, logic handled in values)
        local HUBBLE_HOST="${HUBBLE_FQDN:-hubble.example.com}"
        log "Configuring Hubble UI at: ${HUBBLE_HOST}"

        cat <<EOF >> "${OUTPUT_DIR}/cilium-values.yaml"
hubble:
  enabled: true
  metrics:
    enabled:
    - dns
    - drop
    - tcp
    - flow
    - port-distribution
    - icmp
    - http
  relay:
    enabled: true
  ui:
    enabled: true
    ingress:
      enabled: true
      annotations:
        traefik.ingress.kubernetes.io/router.entrypoints: websecure
        traefik.ingress.kubernetes.io/router.tls: "true"
      className: "traefik"
      hosts:
        - "${HUBBLE_HOST}"
      tls: []
EOF
    else
        log "Hubble is disabled via INSTALL_HUBBLE=false"
        cat <<EOF >> "${OUTPUT_DIR}/cilium-values.yaml"
hubble:
  enabled: false
EOF
    fi

    # Additional Requirements
    cat <<EOF >> "${OUTPUT_DIR}/cilium-values.yaml"
# User Requirements (Additional)
prometheus:
  enabled: true
externalIPs:
  enabled: true
EOF

    # 3. Create Setup Script
    cat <<EOF > "${OUTPUT_DIR}/install_cilium.sh"
#!/bin/bash
set -e
set -o pipefail
export KUBECONFIG=~/.kube/config

# Direct Access Configuration
if [ -n "${CP_0_IP}" ] && [ -n "${CP_ILB_IP}" ]; then
    echo "Configuring direct access to API Server (${CP_0_IP}) to bypass VIP..."
    cp ~/.kube/config ~/.kube/config.direct
    sed -i "s/${CP_ILB_IP}/${CP_0_IP}/g" ~/.kube/config.direct
    export KUBECONFIG=~/.kube/config.direct
fi

# Wait for API Server to be reachable
echo "Waiting for API Server to be reachable..."
for i in {1..20}; do
    if kubectl version &>/dev/null; then
        echo "API Server reachable."
        break
    fi
    echo "API Server not yet reachable. Retrying in 5s... (Attempt \$i/20)"
    sleep 5
done

# Install/Upgrade Cilium
helm upgrade --install cilium cilium/cilium --version ${CILIUM_VERSION} \\
   --namespace kube-system \\
   --values cilium-values.yaml

echo "Cilium installed. Proceeding to CCM deployment to finalize network configuration..."
# Note: We do NOT wait for rollout status here because Cilium needs CCM (next step) to assign PodCIDRs.
EOF
    chmod +x "${OUTPUT_DIR}/install_cilium.sh"

    log "Pushing Cilium artifacts to Bastion..."
    # Copy individually to avoid ambiguity
    run_safe gcloud compute scp "${OUTPUT_DIR}/cilium-values.yaml" "${BASTION_NAME}:~" --zone "${ZONE}" --tunnel-through-iap
    run_safe gcloud compute scp "${OUTPUT_DIR}/install_cilium.sh" "${BASTION_NAME}:~" --zone "${ZONE}" --tunnel-through-iap
    
    log "Executing Helm Install on Bastion..."
    if ! run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "chmod +x install_cilium.sh && ./install_cilium.sh"; then
        error "Cilium Installation Failed!"
        exit 1
    fi
    
    # Verify Installation
    # We use 'timeout 10s' because if the API server (VIP) is down, this check might hang.
    if ! timeout 10s gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl --kubeconfig ~/.kube/config get ds cilium -n kube-system" &>/dev/null; then
         warn "Cilium DaemonSet verification timed out or failed (VIP might be down)."
         warn "Assuming success based on Helm exit code. CCM deployment will proceed."
    else
         log "Cilium DaemonSet verified."
    fi

    # Cleanup (only if successful)
    run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "rm install_cilium.sh"
    # rm -f "${OUTPUT_DIR}/cilium-values.yaml" "${OUTPUT_DIR}/install_cilium.sh"
    log "Cilium values file preserved at: ${OUTPUT_DIR}/cilium-values.yaml"
}

update_cilium() {
    log "Updating/Upgrading Cilium..."
    deploy_cilium "true"
}

deploy_cni() {
    if [ "$INSTALL_CILIUM" == "true" ]; then
        deploy_cilium "false"
    else
        log "Deploying CNI (Flannel)..."
        # Starting with Talos v1.12+, external cloud providers might need explicit CNI
        run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl --kubeconfig ~/.kube/config apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml"
    fi
}
