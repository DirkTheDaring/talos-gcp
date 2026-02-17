#!/bin/bash

get_credentials() {
    log "Fetching credentials for cluster: ${CLUSTER_NAME}..."
    
    # 1. Bucket Check
    if ! gsutil -q stat "${GCS_SECRETS_URI}"; then
        error "Secrets not found at ${GCS_SECRETS_URI}. Is the cluster deployed?"
        exit 1
    fi
    
    # 2. Download Secrets
    mkdir -p "${OUTPUT_DIR}"
    log "Downloading secrets to ${OUTPUT_DIR}..."
    run_safe gsutil cp "${GCS_SECRETS_URI}" "${OUTPUT_DIR}/secrets.yaml"
    chmod 600 "${OUTPUT_DIR}/secrets.yaml"
    
    # 3. Get CP IP
    local CP_ILB_IP
    CP_ILB_IP=$(gcloud compute addresses describe "${ILB_CP_IP_NAME}" --region "${REGION}" --format="value(address)" --project="${PROJECT_ID}" 2>/dev/null)
    
    if [ -z "$CP_ILB_IP" ]; then
        error "Control Plane Internal IP not found. Is the Load Balancer deployed?"
        exit 1
    fi
    
    # 4. Generate Configs
    log "Regenerating Talos config (Endpoint: https://${CP_ILB_IP}:6443)..."
    
    # Clean up existing configs to prevent talosctl errors
    rm -f "${OUTPUT_DIR}/controlplane.yaml" "${OUTPUT_DIR}/worker.yaml" "${OUTPUT_DIR}/talosconfig" "${OUTPUT_DIR}/kubeconfig" "${OUTPUT_DIR}/kubeconfig.local"

    # We can rely on 'talosctl' being available because check_dependencies runs first
    # and installs it if missing.
    # Note: 'gen config' creates talosconfig, controlplane.yaml, worker.yaml
    run_safe "$TALOSCTL" gen config "${CLUSTER_NAME}" "https://${CP_ILB_IP}:6443" --with-secrets "${OUTPUT_DIR}/secrets.yaml" --with-docs=false --with-examples=false --output-dir "${OUTPUT_DIR}"

    # Configure talosconfig endpoint AND node
    run_safe "$TALOSCTL" --talosconfig "${OUTPUT_DIR}/talosconfig" config endpoint "https://${CP_ILB_IP}:6443"
    run_safe "$TALOSCTL" --talosconfig "${OUTPUT_DIR}/talosconfig" config node "${CP_ILB_IP}"
    
    # 5. Fetch Kubeconfig from Bastion
    # We cannot run 'talosctl ... kubeconfig' locally because the API is internal.
    # The Bastion already has a valid ~/.kube/config generated during bootstrap/recreation.
    log "Fetching kubeconfig from Bastion..."
    if ! gcloud compute scp "${BASTION_NAME}:~/.kube/config" "${OUTPUT_DIR}/kubeconfig" --zone "${ZONE}" --project="${PROJECT_ID}" --tunnel-through-iap; then
        error "Failed to fetch kubeconfig from Bastion. Is the Bastion running?"
        exit 1
    fi
     
    # Generate Tunnel-Friendly Configs (localhost + safe ports)
    # Ports match those in 'access-info': K8s=64430, Talos=50005
    
    # Kubeconfig (64430)
    cp "${OUTPUT_DIR}/kubeconfig" "${OUTPUT_DIR}/kubeconfig.local"
    sed -i "s|https://${CP_ILB_IP}:6443|https://127.0.0.1:64430|g" "${OUTPUT_DIR}/kubeconfig.local"

    # Talosconfig (50005)
    cp "${OUTPUT_DIR}/talosconfig" "${OUTPUT_DIR}/talosconfig.local"
    run_safe "$TALOSCTL" --talosconfig "${OUTPUT_DIR}/talosconfig.local" config endpoint "https://127.0.0.1:50005"
    run_safe "$TALOSCTL" --talosconfig "${OUTPUT_DIR}/talosconfig.local" config node "127.0.0.1"

    echo ""
    log "Credentials saved to: ${OUTPUT_DIR}"
    echo "------------------------------------------------"
    echo "NOTE: Control Plane is INTERNAL (${CP_ILB_IP})."
    echo "Files:"
    echo "  - kubeconfig        (Internal IP)"
    echo "  - talosconfig       (Internal IP)"
    echo "  - kubeconfig.local  (Tunnel: 127.0.0.1:64430)"
    echo "  - talosconfig.local (Tunnel: 127.0.0.1:50005)"
    echo ""
    echo "To access from your workstation:"
    echo "  1. Start Tunnel:"
    echo "     ./talos-gcp access-info"
    echo "  2. Use Configs:"
    echo "     export KUBECONFIG=${OUTPUT_DIR}/kubeconfig.local"
    echo "     export TALOSCONFIG=${OUTPUT_DIR}/talosconfig.local"
    echo "     kubectl get nodes"
    echo "     talosctl dashboard"
    echo "------------------------------------------------"
}

ssh_command() {
    set_names
    
    # Check if bastion exists
    if ! gcloud compute instances describe "${BASTION_NAME}" --zone "${ZONE}" --project="${PROJECT_ID}" &> /dev/null; then
        error "Bastion '${BASTION_NAME}' not found in zone '${ZONE}'."
        return 1
    fi
    
    if [ $# -eq 0 ]; then
        log "Opening interactive shell to Bastion '${BASTION_NAME}'..."
    else
        log "Executing command on Bastion '${BASTION_NAME}': $*"
    fi
    
    # SSH into Bastion
    # Using StrictHostKeyChecking=no to avoid issues if bastion is recreated with same name/IP
    # "$@" passes remaining arguments to the ssh command
    
    if [ $# -eq 0 ]; then
        # Interactive Mode: exec is fine/preferred here
        exec gcloud compute ssh "${BASTION_NAME}" \
            --zone "${ZONE}" \
            --project="${PROJECT_ID}" \
            --tunnel-through-iap \
            -- -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
    else
        # Command Mode: DO NOT use exec, or the script will exit!
        gcloud compute ssh "${BASTION_NAME}" \
            --zone "${ZONE}" \
            --project="${PROJECT_ID}" \
            --tunnel-through-iap \
            -- -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$@"
    fi
}

wait_for_api_reachability() {
    local vip="$1"
    local port="${2:-6443}"
    local timeout_sec="${3:-300}" # 5 minutes default
    
    log "Waiting for API Server Reachability at https://${vip}:${port}..."
    
    # We run this ON THE BASTION because it has the correct routing context (VIP via ILB or alias).
    # We use a small script embedded in the command.
    
    local cmd="
        end=\$((SECONDS + ${timeout_sec}))
        success_count=0
        required_success=3
        
        echo 'Probing API Server at https://${vip}:${port}...'
        
        while [ \$SECONDS -lt \$end ]; do
            # curl -k: Insecure (skip cert check)
            # -s: Silent
            # -o /dev/null: Discard output
            # -w %{http_code}: Print status code
            # --max-time 5: Timeout for probe
            
            code=\$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 5 'https://${vip}:${port}/healthz' || echo '000')
            
            if [[ \"\$code\" == \"200\" ]] || [[ \"\$code\" == \"401\" ]] || [[ \"\$code\" == \"403\" ]]; then
                # 200: OK
                # 401/403: Unauthenticated/Forbidden (means API is UP and handling requests, even if we don't have auth token here)
                success_count=\$((success_count + 1))
                echo -n \".\"
                if [ \$success_count -ge \$required_success ]; then
                    echo ''
                    echo 'API Server is Reachable and Stable.'
                    exit 0
                fi
            else
                success_count=0 # Reset on failure to ensure contiguous stability
                echo -n \"x\"
            fi
            sleep 2
        done
        
        echo ''
        echo 'Timeout waiting for API Server.'
        exit 1
    "
    
    if run_on_bastion "$cmd"; then
        log "✅ API Server is reachable."
        return 0
    else
        error "API Server failed to become reachable within ${timeout_sec} seconds."
        return 1
    fi
}
