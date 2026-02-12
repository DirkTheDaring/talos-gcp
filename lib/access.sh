#!/bin/bash

# Generate Access Instructions for Developers
# Verify Access for a specific user
verify_access() {
    set_names
    check_dependencies
    
    if [ -z "${1:-}" ]; then
        error "Usage: ./talos-gcp verify-access <email>"
        exit 1
    fi
    local EMAIL="$1"
    local USER_PROJECT="${PROJECT_ID}"
    
    log "Verifying access for user: ${EMAIL}"
    echo "---------------------------------------------------"
    
    # 1. API Check
    log "1. Checking APIs..."
    local RED_X="${RED}✘${NC}"
    local GREEN_CHECK="${GREEN}✔${NC}"
    
    local REQUIRED_APIS=(
        "serviceusage.googleapis.com"
        "cloudresourcemanager.googleapis.com"
        "compute.googleapis.com"
        "iap.googleapis.com"
        "networkmanagement.googleapis.com"
    )
    
    local FAILED_APIS=0
    # Enable serviceusage first to be able to check others
    if ! gcloud services list --enabled --project="${PROJECT_ID}" --filter="config.name:serviceusage.googleapis.com" --format="value(config.name)" | grep -q "serviceusage.googleapis.com"; then
         echo -e "   [${RED_X}] serviceusage.googleapis.com (Cannot check other APIs without this)"
         warn "User might not have permission to list services."
         FAILED_APIS=1
    else
         local ENABLED_SERVICES
         ENABLED_SERVICES=$(gcloud services list --enabled --project="${PROJECT_ID}" --format="value(config.name)")
         
         for api in "${REQUIRED_APIS[@]}"; do
             if echo "$ENABLED_SERVICES" | grep -q "$api"; then
                 echo -e "   [${GREEN_CHECK}] $api"
             else
                 echo -e "   [${RED_X}] $api"
                 FAILED_APIS=1
             fi
         done
    fi
    
    if [ "$FAILED_APIS" -ne 0 ]; then
        warn "Some required APIs are disabled. Admin must run ./talos-gcp deploy_all to enable them."
    fi
    echo ""

    # 2. IAM Role Check
    log "2. Checking IAM Roles..."
    local MISSING_ROLES=0
    
    # Check Project Level Roles
    local POLICY_JSON
    POLICY_JSON=$(gcloud projects get-iam-policy "${PROJECT_ID}" --format=json)
    
    # Helper to check role
    check_role() {
        local role="$1"
        local label="$2"
        # jq check if the user is in the members list for that role
        if echo "$POLICY_JSON" | jq -e --arg role "$role" --arg user "user:${EMAIL}" \
            '.bindings[] | select(.role == $role) | .members[] | select(. == $user)' >/dev/null; then
             echo -e "   [${GREEN_CHECK}] $label ($role)"
        else
             echo -e "   [${RED_X}] $label ($role)"
             MISSING_ROLES=1
        fi
    }
    
    # Check osLogin (or osAdminLogin)
    if echo "$POLICY_JSON" | jq -e --arg user "user:${EMAIL}" \
        '.bindings[] | select(.role == "roles/compute.osAdminLogin") | .members[] | select(. == $user)' >/dev/null; then
         echo -e "   [${GREEN_CHECK}] Instance Login (roles/compute.osAdminLogin) [Admin]"
    else
         check_role "roles/compute.osLogin" "Instance Login"
    fi
    
    check_role "roles/iap.tunnelResourceAccessor" "IAP Tunnel"
    
    # Check Service Account User (Resource Level or Project Level)
    # We check SA level primarily
    log "   Running SA User Check..."
    local SA_POLICY_JSON
    # Handle case where SA has no policy (returns empty string or 404-like behavior) by defaulting to {}
    SA_POLICY_JSON=$(gcloud iam service-accounts get-iam-policy "${SA_EMAIL}" --format=json 2>/dev/null || echo "{}")
    
    if echo "$SA_POLICY_JSON" | jq -e --arg user "user:${EMAIL}" \
        '.bindings[]? | select(.role == "roles/iam.serviceAccountUser") | .members[]? | select(. == $user)' >/dev/null; then
         echo -e "   [${GREEN_CHECK}] Service Account User ($SA_EMAIL)"
    else
         # Fallback to Project Level check
         if echo "$POLICY_JSON" | jq -e --arg role "roles/iam.serviceAccountUser" --arg user "user:${EMAIL}" \
            '.bindings[] | select(.role == $role) | .members[] | select(. == $user)' >/dev/null; then
             echo -e "   [${GREEN_CHECK}] Service Account User (Project Level)"
         else
             echo -e "   [${RED_X}] Service Account User ($SA_EMAIL)"
             MISSING_ROLES=1
         fi
    fi

    if [ "$MISSING_ROLES" -ne 0 ]; then
        warn "User is missing required roles. Run: ./talos-gcp grant-access ${EMAIL}"
    fi
    echo ""

    # 3. Firewall Check
    log "3. Checking Firewall (IAP)..."
    # Logic: Look for an ingress rule allowing 35.235.240.0/20 on tcp:22
    local FW_RULES
    FW_RULES=$(gcloud compute firewall-rules list --project="${PROJECT_ID}" --format="json" 2>/dev/null || echo "[]")
    
    # We look for ANY rule that:
    # - direction: INGRESS
    # - sourceRanges includes 35.235.240.0/20
    # - allowed includes tcp:22
    # - targetTags matches bastion or is empty (all targets)
    
    # Simplified check: Look for our specific rule or the default allow-ssh
    local IAP_RANGE="35.235.240.0/20"
    if echo "$FW_RULES" | jq -e --arg cidr "$IAP_RANGE" \
        '.[] | select(.direction == "INGRESS") | select(.sourceRanges[]? | contains($cidr)) | select(.allowed[].IPProtocol == "tcp" and (.allowed[].ports[]? | contains("22")))' >/dev/null; then
         echo -e "   [${GREEN_CHECK}] Firewall Rule for IAP ($IAP_RANGE) found."
    else
         echo -e "   [${RED_X}] No Firewall Rule found allowing IAP ($IAP_RANGE) on port 22."
         warn "IAP Tunnel will connect but SSH will timeout."
    fi
    echo ""
    
    # 4. Instance Status
    log "4. Checking Bastion Instance..."
    local STATUS
    STATUS=$(gcloud compute instances describe "${BASTION_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" --format="value(status)" 2>/dev/null || echo "NOT_FOUND")
    
    if [ "$STATUS" == "RUNNING" ]; then
         echo -e "   [${GREEN_CHECK}] Bastion '${BASTION_NAME}' is RUNNING."
    else
         echo -e "   [${RED_X}] Bastion '${BASTION_NAME}' is $STATUS."
    fi
    echo ""
    
    echo "---------------------------------------------------"
    if [ "$FAILED_APIS" -eq 0 ] && [ "$MISSING_ROLES" -eq 0 ] && [ "$STATUS" == "RUNNING" ]; then
        log "✅ Access Verification PASSED for ${EMAIL}"
    else
        error "❌ Access Verification FAILED for ${EMAIL}"
    fi
}

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

    # 5. Network Management Viewer (Connectivity Tests)
    log "  -> Granting 'roles/networkmanagement.viewer' (Connectivity Tests)..."
    run_safe gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="user:${EMAIL}" \
        --role="roles/networkmanagement.viewer" >/dev/null

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

    # 5. Network Management Viewer (Connectivity Tests)
    log "  -> Granting 'roles/networkmanagement.viewer' (Connectivity Tests)..."
    run_safe gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="user:${EMAIL}" \
        --role="roles/networkmanagement.viewer" >/dev/null
    
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
