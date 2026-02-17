#!/bin/bash

install_maintenance() {
    log "DEBUG: install_maintenance function invoked"
    log "Installing Maintenance Services on Bastion..."
    
    # Ensure Output Directory exists
    mkdir -p "${OUTPUT_DIR}"

    # 1. Generate ensure-aliases.sh
    local script_file="${OUTPUT_DIR}/ensure-aliases.sh"
    log "Generating ${script_file}..."
    
    cat <<EOF > "${script_file}"
#!/bin/bash
set -euo pipefail

# Configuration
CLUSTER_NAME="${CLUSTER_NAME}"
ZONE="${ZONE}"
PROJECT_ID="${PROJECT_ID}"
VPC_NAME="${VPC_NAME}"
LOG_FILE="/var/log/ensure-aliases.log"
export KUBECONFIG="/etc/kubernetes/kubeconfig"

# Helper for logging to file + systemd/journal
log() {
    local msg="[\$(date '+%Y-%m-%d %H:%M:%S')] \$1"
    echo "\$msg" | tee -a "\$LOG_FILE"
    # Also log to syslog/journald with tag
    logger -t ensure-aliases "\$1"
}

log "Starting Alias IP Synchronization..."

# 0. Dependency Checks
command -v kubectl >/dev/null || { log "CRITICAL: kubectl not found."; exit 1; }
command -v gcloud >/dev/null || { log "CRITICAL: gcloud not found."; exit 1; }

# 1. Fetch K8s Data (Native Routing PodCIDRs)
log "Fetching PodCIDRs from Kubernetes..."
# Verify Kubeconfig validity
if ! kubectl get nodes --request-timeout=5s >/dev/null 2>&1; then
     log "ERROR: Unable to connect to Kubernetes API. Check kubeconfig or API reachability."
     exit 1
fi

if ! k8s_output=\$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name} {.spec.podCIDR}{"\n"}{end}' --request-timeout=10s); then
    log "ERROR: Failed to fetch Kubernetes node data."
    exit 1
fi

# 2. Fetch GCP Data (Current Aliases)
log "Fetching current GCP Instance Aliases..."
if ! gcp_output=\$(gcloud compute instances list --filter="name:(\${CLUSTER_NAME}-*) AND zone:(\${ZONE}) AND networkInterfaces.network:(\${VPC_NAME})" --format="value(name,networkInterfaces[0].aliasIpRanges[0].ipCidrRange)" --project="\${PROJECT_ID}"); then
    log "ERROR: Failed to fetch GCP instance data."
    exit 1
fi

# 3. Process and Sync
declare -A k8s_cidrs
declare -A gcp_aliases

# Parse K8s
while read -r name cidr; do
    if [ -n "\$name" ]; then k8s_cidrs["\$name"]="\$cidr"; fi
done <<< "\$k8s_output"

# Parse GCP
while read -r name alias_ip; do
    if [ -n "\$name" ]; then gcp_aliases["\$name"]="\$alias_ip"; fi
done <<< "\$gcp_output"

changes_made=0

# Loop through all K8s nodes we found
for node in "\${!k8s_cidrs[@]}"; do
    target="\${k8s_cidrs[\$node]}"
    current="\${gcp_aliases[\$node]:-}"

    # Skip if target is empty or <none>
    if [ -z "\$target" ] || [ "\$target" == "<none>" ]; then
        continue
    fi

    if [ "\$current" != "\$target" ]; then
        log "Mismatch for \$node: Current='\${current:-none}', Target='\$target'. Updating..."
        if gcloud compute instances network-interfaces update "\$node" --zone "\$ZONE" --project="\$PROJECT_ID" --aliases "pods:\$target" >> "\$LOG_FILE" 2>&1; then
            log "SUCCESS: Updated alias for \$node."
            ((changes_made++))
        else
            log "ERROR: Failed to update alias for \$node."
        fi
    fi
done

if [ \$changes_made -eq 0 ]; then
    log "All aliases are in sync."
else
    log "Sync complete. Updated \$changes_made nodes."
fi
EOF
    chmod +x "${script_file}"

    # 2. Generate Systemd Units
    local service_file="${OUTPUT_DIR}/ensure-aliases.service"
    cat <<EOF > "${service_file}"
[Unit]
Description=Ensure GCP Alias IPs match Kubernetes PodCIDRs
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ensure-aliases.sh
User=root
EOF

    local timer_file="${OUTPUT_DIR}/ensure-aliases.timer"
    cat <<EOF > "${timer_file}"
[Unit]
Description=Timer for Ensure Aliases Service

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min

[Install]
WantedBy=timers.target
EOF

    # 3. Upload and Install on Bastion
    log "Deploying services to Bastion (${BASTION_NAME})..."
    
    # Check for local kubeconfig
    local kubeconfig_file="${OUTPUT_DIR}/kubeconfig"
    local upload_kubeconfig="false"
    
    if [ -f "${kubeconfig_file}" ]; then
         upload_kubeconfig="true"
    else
         log "Local kubeconfig not found via standard path. Will attempt to generate on Bastion."
    fi
    
    # Upload files (conditionally include kubeconfig)
    local files_to_upload=("${script_file}" "${service_file}" "${timer_file}")
    if [ "${upload_kubeconfig}" == "true" ]; then
         files_to_upload+=("${kubeconfig_file}")
    fi
    
    run_safe gcloud compute scp "${files_to_upload[@]}" "${BASTION_NAME}:~" --zone "${ZONE}" --tunnel-through-iap --quiet

    # Install on Bastion
    log "Configuring Bastion..."
    run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "
        sudo mv ensure-aliases.sh /usr/local/bin/
        sudo chmod +x /usr/local/bin/ensure-aliases.sh
        
        sudo mkdir -p /etc/kubernetes
        
        # Handle Kubeconfig
        if [ -f ~/kubeconfig ]; then
             echo 'Using uploaded kubeconfig...'
             sudo mv ~/kubeconfig /etc/kubernetes/kubeconfig
        else
             echo 'Uploaded kubeconfig not found. Generating from talosctl...'
             # Try to generate if not present
             if command -v talosctl >/dev/null; then
                 # Ensure .talos/config is valid (should be handled by bastion.sh)
                 if talosctl kubeconfig /tmp/kubeconfig_gen --force; then
                      echo 'Successfully generated kubeconfig.'
                      sudo mv /tmp/kubeconfig_gen /etc/kubernetes/kubeconfig
                 else
                      echo 'WARNING: Failed to generate kubeconfig via talosctl. Service may fail.'
                 fi
             else
                 echo 'WARNING: talosctl not found. Cannot generate kubeconfig.'
             fi
        fi
        
        sudo chmod 600 /etc/kubernetes/kubeconfig
        
        sudo mv ensure-aliases.service /etc/systemd/system/
        sudo mv ensure-aliases.timer /etc/systemd/system/
        
        sudo systemctl daemon-reload
        sudo systemctl enable --now ensure-aliases.timer
        
        echo 'Maintenance service installed and timer started.'
        
        # Run once to verify
        sudo /usr/local/bin/ensure-aliases.sh
    " --quiet
    
    log "Maintenance service installed successfully."
}
