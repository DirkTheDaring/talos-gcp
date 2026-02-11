#!/bin/bash

# Generate Access Instructions for Developers
access_info() {
    set_names
    check_dependencies
    
    log "Retrieving access information for cluster '${CLUSTER_NAME}'..."
    
    # Get Control Plane IP (Internal Load Balancer)
    local cp_ip
    if ! cp_ip=$(gcloud compute addresses describe "${ILB_CP_IP_NAME}" --region="${REGION}" --project="${PROJECT_ID}" --format="value(address)" 2>/dev/null); then
        error "Could not retrieve Control Plane IP (${ILB_CP_IP_NAME}). Is the cluster deployed?"
        return 1
    fi
    
    echo ""
    echo "================================================================================"
    echo "                   Developer Access Instructions"
    echo "================================================================================"
    echo ""
    echo "Cluster: ${CLUSTER_NAME}"
    echo "Region:  ${REGION}"
    echo "Zone:    ${ZONE}"
    echo "Project: ${PROJECT_ID}"
    echo ""
    echo "To access the PRIVATE Talos/K8s API, you must open a secure tunnel via the Bastion."
    echo ""
    echo "PREREQUISITE: Ensure you have fetched credentials:"
    echo "    ./talos-gcp get-credentials"
    echo ""
    echo "--------------------------------------------------------------------------------"
    echo "STEP 1: Open the Tunnel"
    echo "--------------------------------------------------------------------------------"
    echo "Run the following command in a dedicated terminal window. Keep it open."
    echo ""
    echo "gcloud compute ssh ${BASTION_NAME} \\"
    echo "    --zone ${ZONE} \\"
    echo "    --project ${PROJECT_ID} \\"
    echo "    --tunnel-through-iap \\"
    echo "    -- -L 64430:${cp_ip}:6443 -L 50005:${cp_ip}:50000 -N"
    echo ""
    echo "--------------------------------------------------------------------------------"
    echo "STEP 2: Use Tools (In a new terminal)"
    echo "--------------------------------------------------------------------------------"
    echo ""
    echo ">>> Talos (talosctl)"
    echo "    # Use the generated local config (Port 50005)"
    echo "    talosctl --talosconfig _out/${CLUSTER_NAME}/talosconfig.local dashboard"
    echo ""
    echo ">>> Kubernetes (kubectl)"
    echo "    # Use the generated local config (Port 64430)"
    echo "    export KUBECONFIG=_out/${CLUSTER_NAME}/kubeconfig.local"
    echo "    kubectl get nodes"
    echo ""
    echo "================================================================================"
    echo ""
}

# --- Access Management Commands ---

cmd_grant_admin() {
    set_names
    check_dependencies || return 1
    if [ -z "${1:-}" ]; then
        error "Usage: ./talos-gcp grant-admin <email>"
        error "Example: ./talos-gcp grant-admin user@example.com"
        exit 1
    fi
    local EMAIL="$1"
    log "Granting Admin Access to '${EMAIL}'..."
    
    # 1a. OS Admin Login (Root SSH)
    log "  -> Adding 'roles/compute.osAdminLogin' (Root Access)..."
    run_safe gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="user:${EMAIL}" \
        --role="roles/compute.osAdminLogin" >/dev/null

    # 1b. Infrastructure Admin (Create/Delete Instances) - Needed for recreate-bastion
    log "  -> Adding 'roles/compute.instanceAdmin.v1' (Manage Instances)..."
    run_safe gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="user:${EMAIL}" \
        --role="roles/compute.instanceAdmin.v1" >/dev/null

    # 1c. Network User (Use Shared VPC/Subnets)
    log "  -> Adding 'roles/compute.networkUser' (Use Network)..."
    run_safe gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="user:${EMAIL}" \
        --role="roles/compute.networkUser" >/dev/null

    # 2. IAP Tunnel Access (Often implicitly held by project owners, but explicit is safer)
    log "  -> Adding 'roles/iap.tunnelResourceAccessor' (Tunnel Access)..."
    run_safe gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="user:${EMAIL}" \
        --role="roles/iap.tunnelResourceAccessor" >/dev/null

    # 3. GCS Bucket Access
    log "  -> Granting read access to bucket 'gs://${BUCKET_NAME}'..."
    run_safe gsutil iam ch "user:${EMAIL}:objectViewer" "gs://${BUCKET_NAME}"

    # 4. Service Account User (Required for OS Login on VM with SA)
    log "  -> Granting 'roles/iam.serviceAccountUser' on '${SA_EMAIL}'..."
    run_safe gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
        --member="user:${EMAIL}" \
        --role="roles/iam.serviceAccountUser" >/dev/null

    log "Admin access granted."
}

cmd_grant_access() {
    set_names
    check_dependencies || return 1
    
    if [ -z "${1:-}" ]; then
        error "Usage: ./talos-gcp grant-access <email>"
        error "Example: ./talos-gcp grant-access dev@example.com"
        exit 1
    fi
    local EMAIL="$1"
    log "Granting Developer Access to '${EMAIL}'..."
    
    # 1. OS Login (Non-Admin) - Allows SSH Key management & Instance Get
    log "  -> Adding 'roles/compute.osLogin' (Instance Access)..."
    run_safe gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="user:${EMAIL}" \
        --role="roles/compute.osLogin" >/dev/null

    # 2. IAP Tunnel Access - Required for --tunnel-through-iap
    log "  -> Adding 'roles/iap.tunnelResourceAccessor' (Tunnel Access)..."
    run_safe gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="user:${EMAIL}" \
        --role="roles/iap.tunnelResourceAccessor" >/dev/null
        
    # 3. GCS Bucket Access - Allow fetching credentials
    log "  -> Granting read access to bucket 'gs://${BUCKET_NAME}'..."
    run_safe gsutil iam ch "user:${EMAIL}:objectViewer" "gs://${BUCKET_NAME}"
    
    # 4. Service Account User (Required for OS Login on VM with SA)
    log "  -> Granting 'roles/iam.serviceAccountUser' on '${SA_EMAIL}'..."
    run_safe gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
        --member="user:${EMAIL}" \
        --role="roles/iam.serviceAccountUser" >/dev/null
         log "Developer access granted (SSH + IAP + GCS + SA User)."
    
    log "Ask the user to run:"
    log "  1. ./talos-gcp get-credentials"
    log "  2. ./talos-gcp access-info"
}

cmd_list_access() {
    set_names
    check_dependencies
    log "Listing users by role..."
    
    echo "=== [Admin] roles/compute.osAdminLogin ==="
    gcloud projects get-iam-policy "${PROJECT_ID}" \
        --flatten="bindings[].members" \
        --filter="bindings.role:roles/compute.osAdminLogin" \
        --format="value(bindings.members)" || true

    echo ""
    echo "=== [Developer] roles/compute.osLogin ==="
    gcloud projects get-iam-policy "${PROJECT_ID}" \
        --flatten="bindings[].members" \
        --filter="bindings.role:roles/compute.osLogin" \
        --format="value(bindings.members)" || true
        
    echo ""
    echo "=== [Tunnel] roles/iap.tunnelResourceAccessor ==="
    gcloud projects get-iam-policy "${PROJECT_ID}" \
        --flatten="bindings[].members" \
        --filter="bindings.role:roles/iap.tunnelResourceAccessor" \
        --format="value(bindings.members)" || true
    
    echo ""
    echo "=== [GCS] Storage Object Viewers (${BUCKET_NAME}) ==="
    gsutil iam get "gs://${BUCKET_NAME}" | grep "user:" || echo "No explicit user bindings found on bucket."
    
    echo ""
    echo ""
    echo "=== [SA User] roles/iam.serviceAccountUser (${SA_EMAIL}) ==="
    gcloud iam service-accounts get-iam-policy "${SA_EMAIL}" \
        --flatten="bindings[].members" \
        --filter="bindings.role:roles/iam.serviceAccountUser" \
        --format="value(bindings.members)" || true
}

cmd_revoke_access() {
    set_names
    check_dependencies || return 1
    
    if [ -z "${1:-}" ]; then
        error "Usage: ./talos-gcp revoke-access <email>"
        error "Example: ./talos-gcp revoke-access dev@example.com"
        exit 1
    fi
    local EMAIL="$1"
    log "Revoking access for '${EMAIL}'..."
    
    # Check if user is an Admin first
    if gcloud projects get-iam-policy "${PROJECT_ID}" \
        --flatten="bindings[].members" \
        --filter="bindings.role:roles/compute.osAdminLogin" \
        --format="value(bindings.members)" | grep -q "user:${EMAIL}"; then
        echo ""
        echo -e "${RED}[WARNING] User '${EMAIL}' has Admin Access (roles/compute.osAdminLogin)!${NC}"
        echo "Revoking developer roles will NOT fully remove their access."
        echo "To remove Admin access, you must manually run:"
        echo "  gcloud projects remove-iam-policy-binding ${PROJECT_ID} --member=user:${EMAIL} --role=roles/compute.osAdminLogin"
        echo ""
        echo -n "Continue checking/removing developer roles? [y/N] "
        read -r response
        if [[ ! "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
            log "Aborted."
            exit 0
        fi
    fi

    # 1. OS Login (Non-Admin)
    log "  -> Removing 'roles/compute.osLogin'..."
    run_safe gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
        --member="user:${EMAIL}" \
        --role="roles/compute.osLogin" >/dev/null || warn "Role not found or already removed."

    # 2. IAP Tunnel Access
    log "  -> Removing 'roles/iap.tunnelResourceAccessor'..."
    run_safe gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
        --member="user:${EMAIL}" \
        --role="roles/iap.tunnelResourceAccessor" >/dev/null || warn "Role not found or already removed."

    # 3. GCS Bucket Access
    log "  -> Removing read access from bucket 'gs://${BUCKET_NAME}'..."
    if gsutil iam ch -d "user:${EMAIL}:objectViewer" "gs://${BUCKET_NAME}"; then
         :
    else
         warn "Failed to remove bucket access (or not present)."
    fi
    
    # 4. Service Account User
    log "  -> Removing 'roles/iam.serviceAccountUser' from '${SA_EMAIL}'..."
    run_safe gcloud iam service-accounts remove-iam-policy-binding "${SA_EMAIL}" \
        --member="user:${EMAIL}" \
        --role="roles/iam.serviceAccountUser" >/dev/null || warn "Role not found or already removed."
    
    log "Access revoked."
}
