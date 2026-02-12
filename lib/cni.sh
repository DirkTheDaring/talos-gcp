#!/bin/bash

deploy_cilium() {
    log "Deploying Cilium via Helm..."
    
    # 0. Ensure Helm is installed on Bastion
    log "Ensuring Helm is installed on Bastion..."
    
    # Check if Cilium is already running to avoid redundant reinstall
    if gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl --kubeconfig ./kubeconfig get ds cilium -n kube-system" &> /dev/null; then
         log "Cilium is already installed (DaemonSet found). Skipping installation."
         log "Use './talos-gcp update-cilium' to force an upgrade."
         return
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
        # Check if we really need to push it (Phase 4 might have done it)
        # But to be safe for standalone usage:
        # We don't want to overwrite if it exists? 
        # Actually, let's assume ~/.kube/config is the source of truth.
        # But if we are running from local, local might be newer?
        # For consistency with other functions, we rely on ~/.kube/config being present or we push it there.
        # However, scp to ~/.kube/config requires the dir to exist.
        
        # Let's just trust that phase4/bootstrap populated it.
        # But if we run `update-cilium` standalone, we might need it.
        # So we check existence on bastion.
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
    local CP_ILB_IP=$(gcloud compute addresses describe "${ILB_CP_IP_NAME}" --region "${REGION}" --format="value(address)" --project="${PROJECT_ID}")
    if [ -z "$CP_ILB_IP" ]; then
        error "Could not determine Control Plane Internal IP for Cilium configuration."
        exit 1
    fi
    log "Using Control Plane Internal IP: ${CP_ILB_IP}"

    # Note: We use specific GCP/Talos settings (IPAM kubernetes, VXLAN, KubeProxyReplacement, etc.)
    # We must substitute variables.

    # Configure Routing Mode
    local routing_mode="${CILIUM_ROUTING_MODE:-tunnel}"
    local tunnel_protocol="vxlan"
    local masquerade="true"
    local native_cidr_line=""
    local endpoint_routes=""

    if [ "$routing_mode" == "native" ]; then
        log "Configuring Cilium for NATIVE Routing (GCP Alias IPs)..."
        tunnel_protocol=""  # Disable tunneling
        masquerade="false"  # Pods are natively routable
        endpoint_routes="endpointRoutes:\n  enabled: true" # Ensure local delivery
        
        # Explicit CIDR for native routing
        if [ -n "${CILIUM_NATIVE_CIDR}" ]; then
            native_cidr_line="ipv4NativeRoutingCIDR: \"${CILIUM_NATIVE_CIDR}\""
        fi
    else
        log "Configuring Cilium for TUNNEL Routing (VXLAN)..."
    fi

    cat <<EOF > "${OUTPUT_DIR}/cilium-values.yaml"
ipam:
  mode: kubernetes
k8sServiceHost: "localhost"
k8sServicePort: 7445
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
tunnelProtocol: ${tunnel_protocol}
${endpoint_routes}
${native_cidr_line}
mtu: 1460
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

# Install/Upgrade Cilium
helm upgrade --install cilium cilium/cilium --version ${CILIUM_VERSION} \\
   --namespace kube-system \\
   --values cilium-values.yaml

echo "Waiting for Cilium to be ready..."
# Initial wait for pods to be created
sleep 10
kubectl rollout status ds/cilium -n kube-system --timeout=300s
EOF
    chmod +x "${OUTPUT_DIR}/install_cilium.sh"

    log "Pushing Cilium artifacts to Bastion..."
    run_safe gcloud compute scp "${OUTPUT_DIR}/cilium-values.yaml" "${OUTPUT_DIR}/install_cilium.sh" "${BASTION_NAME}:~" --zone "${ZONE}" --tunnel-through-iap
    
    log "Executing Helm Install on Bastion..."
    run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "./install_cilium.sh && rm install_cilium.sh cilium-values.yaml"
    rm -f "${OUTPUT_DIR}/cilium-values.yaml" "${OUTPUT_DIR}/install_cilium.sh"
}

deploy_cni() {
    if [ "$INSTALL_CILIUM" == "true" ]; then
        deploy_cilium
    else
        log "Deploying CNI (Flannel)..."
        # Starting with Talos v1.12+, external cloud providers might need explicit CNI
        run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl --kubeconfig ./kubeconfig apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml"
    fi
}
