#!/bin/bash

phase2_bastion() {
    log "Phase 2b: Bastion..."
    if ! gcloud compute instances describe "${BASTION_NAME}" --zone "${ZONE}" --project="${PROJECT_ID}" &> /dev/null; then
        log "Creating Bastion..."
        cat <<EOF > "${OUTPUT_DIR}/bastion_startup.sh"
#! /bin/bash
set -ex

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
retry curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Install Cilium CLI
CILIUM_CLI_VERSION=\$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/master/stable.txt)
retry curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/\${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz
tar xzbxf cilium-linux-amd64.tar.gz -C /usr/local/bin
rm cilium-linux-amd64.tar.gz
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
}
