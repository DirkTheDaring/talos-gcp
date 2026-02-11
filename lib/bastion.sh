#!/bin/bash

phase2_bastion() {
    log "Phase 2b: Bastion..."
    if ! gcloud compute instances describe "${BASTION_NAME}" --zone "${ZONE}" --project="${PROJECT_ID}" &> /dev/null; then
        log "Creating Bastion..."
        cat <<EOF > "${OUTPUT_DIR}/bastion_startup.sh"
#! /bin/bash
set -ex
set -o pipefail

# Retry wrapper
retry() {
  local retries=5
  local count=0
  until "\$@"; do
    exit="\$?"
    wait=\$((2 ** count))
    count=\$((count + 1))
    if [ \$count -lt \$retries ]; then
      echo "Retry \$count/\$retries exited \$exit, retrying in \$wait seconds..."
      sleep \$wait
    else
      echo "Retry \$count/\$retries exited \$exit, no more retries left."
      return \$exit
    fi
  done
  return 0
}

# Install Talosctl
retry curl -LO "https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/talosctl-linux-amd64"
mv talosctl-linux-amd64 talosctl
chmod +x talosctl
mv talosctl /usr/local/bin/

# Install Kubectl
retry curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
chmod +x kubectl
mv kubectl /usr/local/bin/

# Install Helm
retry curl -f -L https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Install Cilium CLI
CILIUM_CLI_VERSION=\$(curl -sL https://raw.githubusercontent.com/cilium/cilium-cli/master/stable.txt)
retry curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/\${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz
tar xzf cilium-linux-amd64.tar.gz -C /usr/local/bin
rm cilium-linux-amd64.tar.gz

# Setup Bash Completion
cat <<'BZ' > /etc/profile.d/talos-completion.sh
if [ -n "\$BASH_VERSION" ]; then
    if command -v kubectl >/dev/null 2>&1; then
        source <(kubectl completion bash)
        alias k=kubectl
        complete -o default -F __start_kubectl k
    fi
    if command -v helm >/dev/null 2>&1; then
        source <(helm completion bash)
    fi
    if command -v talosctl >/dev/null 2>&1; then
        source <(talosctl completion bash)
    fi
fi
BZ

# --- Create Restricted Login Script ---
cat <<'RLS' > /usr/local/bin/bastion-restrict-login
#!/bin/bash
# Wrapper Script to enforce "Pure IAM" access control.
# Logic:
# 1. Root -> Allow
# 2. Admin (google-sudoers) -> Allow
# 3. Others -> Restrict (Port Forwarding Only)

# Helper to execute original command or shell
run_original() {
    if [ -n "\$SSH_ORIGINAL_COMMAND" ]; then
        exec /bin/bash -c "\$SSH_ORIGINAL_COMMAND"
    else
        exec /bin/bash -l
    fi
}

# 1. ROOT CHECK
if [ "\$(id -u)" -eq 0 ]; then
    run_original
fi

# 2. CAPABILITY CHECK (Sudo = Admin)
# If the user can run sudo without a password (granted by roles/compute.osAdminLogin),
# they are an Admin and get a shell.
if sudo -n true 2>/dev/null; then
    run_original
fi

# 3. RESTRICTED USER
echo "========================================================================"
echo "  ACCESS RESTRICTED: Port Forwarding Only"
echo "  Interactive shell is disabled for security."
echo "  User: \$(whoami)"
echo "  Your SSH tunnel is ACTIVE. Do not close this terminal."
echo "========================================================================"

# Sleep forever to keep the tunnel open
sleep infinity
RLS
chmod +x /usr/local/bin/bastion-restrict-login

# --- Security Hardening ---
# 1. Configure SSHD for Restricted Access (Idempotent & Safe)
# SAFETY NET: Check if google-sudoers exists (populated by OS Login for Admins)
# We wait a bit for OS Login to sync groups
sleep 5

# --- Security Hardening ---
# 1. Configure SSHD for Restricted Access (Idempotent & Safe)
# SAFETY NET: We apply this unconditionally now, as we rely on the wrapper script
# to distinguish admins (sudoers) from regular users.

# Only append if the custom block doesn't exist
if ! grep -q "Pure IAM Model" /etc/ssh/sshd_config; then
    echo "Applying SSHD Hardening with Verification..."
    
    # 1. Backup existing config
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
    
    # 2. Append Proposed Changes (Quoted heredoc to prevent expansion of !)
    cat <<'EOSSH' >> /etc/ssh/sshd_config

# --- Restricted K8s Access (Pure IAM Model) ---

# Global ForceCommand delegates access control to the wrapper script.
ForceCommand /usr/local/bin/bastion-restrict-login
AllowTcpForwarding yes
X11Forwarding no
AllowAgentForwarding no
EOSSH

    # 3. Verify Syntax (with retries for NSS/OS Login availability)
    echo "Verifying SSHD syntax..."
    for k in {1..5}; do
        if /usr/sbin/sshd -t 2>/tmp/sshd_validate_err; then
            echo "✅ SSHD Config Syntax Verification PASSED."
            systemctl restart ssh
            break
        else
            echo "⚠️ Attempt \$k: SSHD Validation failed."
            cat /tmp/sshd_validate_err
            if [ \$k -eq 5 ]; then
                echo "❌ SSHD Config Syntax Verification FAILED after 5 attempts!"
                echo "Saving failed config to /etc/ssh/sshd_config.failed for debugging..."
                cp /etc/ssh/sshd_config /etc/ssh/sshd_config.failed
                echo "Reverting changes to prevent lockout..."
                cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
                systemctl restart ssh
            else
                sleep 2
            fi
        fi
    done
else
    echo "SSHD configuration for k8s-users already exists."
fi


EOF

        run_safe gcloud compute instances create "${BASTION_NAME}" \
            --zone="${ZONE}" \
            --machine-type=e2-micro \
            --network="${VPC_NAME}" \
            --subnet="${SUBNET_NAME}" \
            --tags=bastion \
            --image-family="${BASTION_IMAGE_FAMILY}" \
            --image-project="${BASTION_IMAGE_PROJECT}" \
            --metadata-from-file=startup-script="${OUTPUT_DIR}/bastion_startup.sh" \
            --metadata=enable-oslogin=TRUE \
            --service-account="${SA_EMAIL}" \
            --scopes=cloud-platform \
            --labels="cluster=${CLUSTER_NAME},talos-version=${TALOS_VERSION//./-},k8s-version=${KUBECTL_VERSION//./-},cilium-version=${CILIUM_VERSION//./-}" \
            --project="${PROJECT_ID}"
            
        rm "${OUTPUT_DIR}/bastion_startup.sh"
        log "Bastion created."
    else
        log "Bastion '${BASTION_NAME}' exists."
    fi
}

phase4_bastion() {
    log "Phase 4: Setting up Bastion..."
    
    # Retrieve Control Plane IP for config (Needed for talosctl config node)
    local CP_ILB_IP
    CP_ILB_IP=$(gcloud compute addresses describe "${ILB_CP_IP_NAME}" --region "${REGION}" --format="value(address)" --project="${PROJECT_ID}" 2>/dev/null)
    if [ -z "$CP_ILB_IP" ]; then
        warn "Could not retrieve Control Plane IP. talosconfig on bastion might need manual update."
    fi

    log "Waiting for Bastion SSH to become available (vm booting + sshd start, max 5m)..."
    # Increase timeout to 5 minutes (60 * 5s)
    local MAX_RETRIES=60
    local COUNT=0
    
    # Wait for SSH and talosctl installation by startup script
    while ! gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "talosctl version --client" &> /dev/null; do
        log "Bastion SSH/talosctl not yet ready (installing tools?)... (Attempt $((COUNT+1))/$MAX_RETRIES, elapsed: $((COUNT*5))s)"
        sleep 5
        COUNT=$((COUNT+1))
        if [ $COUNT -ge $MAX_RETRIES ]; then
            error "Bastion unreachable via IAP or talosctl missing after 5 minutes."
            diagnose
            exit 1
        fi
    done
    
    log "Bastion SSH is reachable and talosctl is installed."

    # Copy talosconfig and kubeconfig to bastion
    log "Pushing cluster configurations to Bastion..."
    
    # 0. Create config directories first
    run_safe retry gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "mkdir -p ~/.kube ~/.talos"

    # 1. talosconfig
    if [ -f "${OUTPUT_DIR}/talosconfig" ]; then
        run_safe retry gcloud compute scp "${OUTPUT_DIR}/talosconfig" "${BASTION_NAME}:~/.talos/config" --zone "${ZONE}" --tunnel-through-iap
        # Ensure the bastion config points to the VIP (for stability)
        if [ -n "${CP_ILB_IP}" ]; then
            run_safe retry gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "talosctl --talosconfig ~/.talos/config config node ${CP_ILB_IP} && talosctl --talosconfig ~/.talos/config config endpoint ${CP_ILB_IP}"
        fi
    else
        warn "Local talosconfig not found. Bastion cannot manage Talos nodes."
    fi

    # 2. kubeconfig
    if [ -f "${OUTPUT_DIR}/kubeconfig" ]; then
        run_safe retry gcloud compute scp "${OUTPUT_DIR}/kubeconfig" "${BASTION_NAME}:~/.kube/config" --zone "${ZONE}" --tunnel-through-iap
    else
        warn "Local kubeconfig not found. Bastion cannot manage K8s."
    fi
    
    # 3. Configure /etc/skel for future Admins (Multi-Admin Support)
    log "Configuring /etc/skel for future Admins..."
    # SECURITY: Use 600 permissions to prevent non-root users from reading templates
    run_safe retry gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "
        sudo mkdir -p /etc/skel/.kube /etc/skel/.talos
        [ -f ~/.kube/config ] && sudo cp ~/.kube/config /etc/skel/.kube/config
        [ -f ~/.talos/config ] && sudo cp ~/.talos/config /etc/skel/.talos/config
        sudo chmod -R 755 /etc/skel/.kube /etc/skel/.talos
        sudo chmod 600 /etc/skel/.kube/config /etc/skel/.talos/config ~/.talos/config ~/.kube/config 2>/dev/null || true
    "
    
    log "Bastion provisioning complete."
}
