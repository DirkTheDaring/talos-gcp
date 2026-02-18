#!/bin/bash

# --- Traefik Management ---

update_traefik() {
    log "Updating Traefik Ingress Controller..."
    
    # 1. Resolve Target IP (First External IP)
    local ip_name="${CLUSTER_NAME}-ingress-v4-0"
    local traefik_ip=""
    
    if ! gcloud compute addresses describe "${ip_name}" --region "${REGION}" --project="${PROJECT_ID}" &> /dev/null; then
        error "IP Address '${ip_name}' not found. Please run 'create' or 'apply-ingress' first to allocate IPs."
        return 1
    fi
    
    traefik_ip=$(gcloud compute addresses describe "${ip_name}" --region "${REGION}" --format="value(address)" --project="${PROJECT_ID}")
    log "Target IP for Traefik LoadBalancer: ${traefik_ip}"

    # 2. Conflict Resolution (The Handoff)
    # Delete manual Forwarding Rules that might conflict with CCM
    log "Checking for conflicting Forwarding Rules (Handoff to CCM)..."
    
    local rule_tcp="${CLUSTER_NAME}-ingress-v4-rule-0-tcp"
    local rule_udp="${CLUSTER_NAME}-ingress-v4-rule-0-udp"
    local rule_legacy="${CLUSTER_NAME}-ingress-v4-rule-0"
    
    local deleted_any=false
    for rule in "${rule_tcp}" "${rule_udp}" "${rule_legacy}"; do
        if gcloud compute forwarding-rules describe "${rule}" --region "${REGION}" --project="${PROJECT_ID}" &> /dev/null; then
            log "Deleting conflicting rule '${rule}' to free IP for Traefik..."
            run_safe gcloud compute forwarding-rules delete "${rule}" --region "${REGION}" --project="${PROJECT_ID}" -q
            deleted_any=true
        fi
    done
    
    if [ "$deleted_any" == "true" ]; then
        log "Waiting 15s for GCP Forwarding Rule deletion propagation..."
        sleep 15
    fi

    # 3. Prepare Helm Values
    log "Generating Traefik Configuration..."
    
    # System Values (Enforce IP)
    # Note: we use strict heredoc to avoid expanding accidental variables if any, but we NEED to expand ${traefik_ip}
    cat <<EOF > "${OUTPUT_DIR}/traefik-values.system.yaml"
service:
  spec:
    loadBalancerIP: ${traefik_ip}
logs:
  access:
    enabled: true
    fields:
      headers:
        defaultmode: keep
EOF

    # Copy to Bastion
    run_safe gcloud compute scp "${OUTPUT_DIR}/traefik-values.system.yaml" "${BASTION_NAME}:~" --zone "${ZONE}" --tunnel-through-iap
    
    # Ensure Kubeconfig (Critical for Helm)
    # Prefer Bastion's existing config (Source of Truth) to avoid overwriting with stale local config
    if gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --project="${PROJECT_ID}" --tunnel-through-iap --command "test -s .kube/config" -- -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null &>/dev/null; then
        log "Pulling latest kubeconfig from Bastion..."
        run_safe gcloud compute scp "${BASTION_NAME}:~/.kube/config" "${OUTPUT_DIR}/kubeconfig" --zone "${ZONE}" --project="${PROJECT_ID}" --tunnel-through-iap
    fi

    if [ -f "${OUTPUT_DIR}/kubeconfig" ]; then
        log "Ensuring Bastion has latest kubeconfig..."
        run_safe gcloud compute scp "${OUTPUT_DIR}/kubeconfig" "${BASTION_NAME}:~/.kube/config" --zone "${ZONE}" --project="${PROJECT_ID}" --tunnel-through-iap
    else
        warn "Kubeconfig not found locally at ${OUTPUT_DIR}/kubeconfig. Helm might fail if not already configured on Bastion."
    fi

    # User Values (Optional Override)
    local user_values_flag=""
    if [ -f "traefik-values.yaml" ]; then
        log "Found user overrides in 'traefik-values.yaml'. Applying..."
        run_safe gcloud compute scp "traefik-values.yaml" "${BASTION_NAME}:~" --zone "${ZONE}" --tunnel-through-iap
        user_values_flag="-f traefik-values.yaml"
    fi

    # 4. Deploy via Helm
    log "Deploying Traefik via Helm on Bastion..."
    
    # We use a script on bastion to ensure set -e catches helm errors
    run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "
        set -e
        # Ensure Repo
        helm repo add traefik https://helm.traefik.io/traefik
        helm repo update
        
        # Install/Upgrade
        echo 'Installing Traefik...'
        helm upgrade --install traefik traefik/traefik \
            --version "${TRAEFIK_VERSION}" \
            --namespace traefik \
            --create-namespace \
            -f traefik-values.system.yaml \
            ${user_values_flag} \
            --wait --timeout 10m
    "
    
    # 5. Verification
    log "Verifying Traefik LoadBalancer IP assignment..."
    local svc_ip=""
    for i in {1..30}; do
        svc_ip=$(gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null" || echo "")
        
        if [ "$svc_ip" == "$traefik_ip" ]; then
            log "SUCCESS: Traefik is active on External IP: ${svc_ip}"
            
            # Advice
            log ""
            log "IMPORTANT: To prevent 'apply-ingress' from re-creating conflicting forwarding rules,"
            log "please remove ports 80 and 443 (or the entire group 0) from INGRESS_IPV4_CONFIG in cluster.env."
            log ""
            
            return 0
        fi
        
        if [ -n "$svc_ip" ] && [ "$svc_ip" != "''" ]; then
             log "WARNING: Traefik got a DIFFERENT IP ($svc_ip) than expected ($traefik_ip). Check GCP Quotas or Conflicts."
             return 0
        fi
        
        echo -n "."
        sleep 10
    done
    
    error "Timed out waiting for Traefik to acquire IP ${traefik_ip}. Check 'kubectl describe svc -n traefik traefik' on Bastion."
    return 1
}
