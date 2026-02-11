#!/bin/bash

# Check if URL exists
# Check if URL exists (Follow Redirects)
check_url() {
    curl --connect-timeout 10 --location --output /dev/null --silent --head --fail "$1"
}

sanitize_version() {
    local v="$1"
    # remove leading v, replace dots with dashes
    echo "${v//./-}" | tr '[:upper:]' '[:lower:]'
}

# Ensure required global variables are set
check_required_vars() {
    local missing_vars=()
    for var in ARCH PROJECT_ID REGION BUCKET_NAME CP_TALOS_VERSION WORKER_TALOS_VERSION; do
        if [ -z "${!var}" ]; then
            missing_vars+=("$var")
        fi
    done

    if [ ${#missing_vars[@]} -gt 0 ]; then
        error "Missing required environment variables: ${missing_vars[*]}"
        return 1
    fi
}

# Helper to resolve image for a given version (Vanilla / No Extensions)
resolve_vanilla_image() {
    local version="$1"
    local image_sr=""
    
    log "Resolving Vanilla Image for version ${version}..."

    # 1. Check cloud-images.json (GitHub Releases) - Preferred for Vanilla
    local cloud_images_url="https://github.com/siderolabs/talos/releases/download/${version}/cloud-images.json"
    
    if check_url "$cloud_images_url"; then
        # Extract GCP image URL (Platform=gcp or Cloud=gcp)
        # using jq for robustness
        local json_content
        if json_content=$(curl -sL --fail "${cloud_images_url}"); then
             image_sr=$(echo "$json_content" | jq -r --arg arch "$ARCH" '.[] | select((.cloud == "gcp" or .platform == "gcp") and .arch == $arch) | .url' 2>/dev/null || echo "")
        else
             warn "Failed to fetch cloud-images.json from GitHub Releases. Fallback to direct download."
        fi
    fi
    
    if [ -n "$image_sr" ] && [ "$image_sr" != "null" ]; then
        echo "$image_sr"
        return 0
    fi

    # 2. Legacy / Direct URLs
    local possible_urls=(
        "https://github.com/siderolabs/talos/releases/download/${version}/gcp-${ARCH}.tar.gz"
        "https://github.com/siderolabs/talos/releases/download/${version}/gcp-${ARCH}.raw.tar.gz"
        "https://github.com/siderolabs/talos/releases/download/${version}/talos-gcp-${ARCH}.tar.gz"
    )
    
    local url
    for url in "${possible_urls[@]}"; do
        if check_url "$url"; then
            echo "$url"
            return 0
        fi
    done
    
    return 1
}

# Get Schematic ID from Factory
get_schematic_id() {
    local version="$1"
    local extensions="$2" # comma separated
    
    # Construct JSON payload for Factory
    local ext_json
    # Split by comma and filter empty strings
    ext_json=$(echo "$extensions" | jq -R 'split(",") | map(select(length > 0))')
    
    local payload
    payload=$(jq -n --arg ver "$version" --argjson ext "$ext_json" \
        '{customization: {systemExtensions: {officialExtensions: $ext}}}')

    local body_file
    body_file=$(mktemp)
    
    local http_code
    http_code=$(curl --connect-timeout 15 -s -w "%{http_code}" -X POST "https://factory.talos.dev/schematics" \
        -H "Content-Type: application/json" \
        -d "$payload" -o "$body_file")
    
    local factory_response
    factory_response=$(<"$body_file")
    rm -f "$body_file"

    if [ "$http_code" -ne 200 ] && [ "$http_code" -ne 201 ]; then
        error "Factory API failed with HTTP ${http_code}: ${factory_response}"
        return 1
    fi
        
    local schematic_id
    schematic_id=$(echo "$factory_response" | jq -r .id 2>/dev/null)
    
    if [ -z "$schematic_id" ] || [ "$schematic_id" == "null" ]; then
        error "Failed to get Schematic ID from Factory. Response: $factory_response"
        return 1
    fi
    
    echo "$schematic_id"
}

# Get Factory Download URL
get_factory_url() {
    local schematic_id="$1"
    local version="$2"
    
    # Validation check
    if [ -z "$schematic_id" ]; then
        error "Schematic ID is empty in get_factory_url."
        return 1
    fi

    # Factory URL for GCP raw disk
    local factory_url="https://factory.talos.dev/image/$schematic_id/$version/gcp-$ARCH.tar.gz"
    
    # Verify it exists (Factory generates on demand, but head check usually works or triggers generation)
    # Retry loop to allow Factory time to generate the asset
    # Increased to 60 attempts x 10s = 10 minutes due to observed factory sluggishness
    local max_retries=60
    local wait_sec=10
    
    for ((i=1; i<=max_retries; i++)); do
        if check_url "$factory_url"; then
            echo "$factory_url"
            return 0
        fi
        
        warn "Factory URL not ready yet (Attempt $i/$max_retries). Waiting ${wait_sec}s..."
        sleep "$wait_sec"
    done

    warn "Factory URL still not accessible after $((max_retries * wait_sec)) seconds: $factory_url"
    return 1
}

ensure_single_image() {
    local role="$1"       # "cp" or "worker"
    local version="$2"
    local extensions="$3"
    
    if [[ "$role" != "cp" && "$role" != "worker" ]]; then
        error "Invalid role: '$role'. Must be 'cp' or 'worker'."
        return 1
    fi

    local safe_ver
    safe_ver=$(sanitize_version "$version")
    
    # Calculate Suffix (Vanilla vs Extended)
    local suffix
    if [ -z "$extensions" ]; then
        suffix="gcp-${ARCH}"
    else
        local ext_hash
        ext_hash=$(echo "${extensions}" | md5sum | cut -c1-8)
        suffix="${role}-${ext_hash}-${ARCH}"
    fi
    
    local image_name="talos-${safe_ver}-${suffix}"
    local gcs_object="${image_name}.tar.gz"
    
    # Logic to determine Installer Image & Download URL
    local installer_image=""
    local download_url=""
    
    if [ -n "$extensions" ]; then
        log "[${role^^}] Resolving Factory Schematic for Extensions: ${extensions}"
        local schematic_id
        schematic_id=$(get_schematic_id "$version" "$extensions")
        
        if [ -z "$schematic_id" ]; then
             error "Failed to resolve schematic for ${role}."
             return 1
        fi
        
        installer_image="factory.talos.dev/image/${schematic_id}/${version}/installer"
        if ! download_url=$(get_factory_url "${schematic_id}" "${version}"); then
             error "Could not obtain factory download URL for ${role}."
             return 1
        fi
    else
        installer_image="ghcr.io/siderolabs/installer:${version}"
        download_url=$(resolve_vanilla_image "$version")
    fi
    
    # Export variables
    if [ "$role" == "cp" ]; then
        export CP_IMAGE_NAME="$image_name"
        export CP_INSTALLER_IMAGE="$installer_image"
    else
        export WORKER_IMAGE_NAME="$image_name"
        export WORKER_INSTALLER_IMAGE="$installer_image"
    fi
    
    log "[${role^^}] Configured: Image=${image_name}, Installer=${installer_image}"

    # 1. Check if Image exists in GCP
    if gcloud compute images describe "${image_name}" --project="${PROJECT_ID}" &> /dev/null; then
        log "  -> GCP Image '${image_name}' already exists."
        return 0
    fi
    
    # 2. Check if Object exists in GCS (Staging)
    if gsutil -q stat "gs://${BUCKET_NAME}/${gcs_object}"; then
        log "  -> Found in GCS bucket (gs://${BUCKET_NAME}/${gcs_object}). Skipping download."
    else
        # 3. Download
        if [ -z "$download_url" ]; then
            error "Could not resolve download URL for ${role} image."
            return 1
        fi
        
        log "  -> Downloading from: ${download_url}"
        
        (
            local tmp_dir
            tmp_dir=$(mktemp -d)
            trap 'rm -rf "$tmp_dir"' EXIT
            
            run_safe retry curl --http1.1 -L -f -o "${tmp_dir}/image.tar.gz" "${download_url}"
            
            # Verify download is not empty
            if [ ! -s "${tmp_dir}/image.tar.gz" ]; then
                error "Downloaded image is empty."
                exit 1
            fi
            
            log "  -> Uploading to GCS..."
            run_safe retry gsutil cp "${tmp_dir}/image.tar.gz" "gs://${BUCKET_NAME}/${gcs_object}"
        ) || return 1
    fi

    # 4. Create GCP Image
    log "  -> Creating GCP Image resource..."
    if ! gcloud compute images create "${image_name}" \
        --source-uri="gs://${BUCKET_NAME}/${gcs_object}" \
        --guest-os-features=VIRTIO_SCSI_MULTIQUEUE \
        --project="${PROJECT_ID}" 2>/dev/null; then
        
        if gcloud compute images describe "${image_name}" --project="${PROJECT_ID}" &>/dev/null; then
             log "  -> Image created by concurrent process."
        else
             error "Failed to create image '${image_name}'."
             return 1
        fi
    fi
}

ensure_role_images() {
    # Verify environment
    check_required_vars

    # Ensure Bucket Exists First
    if ! gsutil ls -b "gs://${BUCKET_NAME}" &> /dev/null; then
        log "Creating GCS Bucket: gs://${BUCKET_NAME}..."
        run_safe gsutil mb -p "${PROJECT_ID}" -c standard -l "${REGION}" -b on --pap enforced "gs://${BUCKET_NAME}"
    fi

    # Control Plane
    ensure_single_image "cp" "${CP_TALOS_VERSION}" "${CP_EXTENSIONS}" || return 1
    
    # Workers
    ensure_single_image "worker" "${WORKER_TALOS_VERSION}" "${WORKER_EXTENSIONS}" || return 1
}
