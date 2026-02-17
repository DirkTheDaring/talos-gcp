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
    local kernel_args="$3" # comma separated or space separated (we will parse)
    
    # Construct JSON payload for Factory
    local ext_json
    # Split by comma, trim whitespace, and filter empty strings
    ext_json=$(echo "$extensions" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)) | sort')

    # Parse Kernel Args to JSON array
    local kargs_json="[]"
    if [ -n "$kernel_args" ]; then
        # Handle space separation. Convert to array.
        # Use scan to extract non-separator tokens (space delimiter only)
        kargs_json=$(echo "$kernel_args" | jq -R '[scan("[^ ]+")]')
    fi
    
    local payload
    payload=$(jq -n --arg ver "$version" --argjson ext "$ext_json" --argjson kargs "$kargs_json" \
        '{customization: {systemExtensions: {officialExtensions: $ext}, extraKernelArgs: $kargs}}')

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
    # Note: Factory uses .raw.tar.gz for GCP images
    local factory_url="https://factory.talos.dev/image/$schematic_id/$version/gcp-$ARCH.raw.tar.gz"
    
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
    local kernel_args="$4"
    local nested_virt="${5:-false}" # Default: false
    
    if [[ "$role" != "cp" && "$role" != "worker" ]]; then
        error "Invalid role: '$role'. Must be 'cp' or 'worker'."
        return 1
    fi

    local safe_ver
    safe_ver=$(sanitize_version "$version")
    
    # Calculate Suffix (Vanilla vs Extended vs Nested)
    local suffix
    if [ -z "$extensions" ] && [ -z "$kernel_args" ]; then
        suffix="gcp-${ARCH}"
    else
        # Deterministic hashing: Sort extensions to avoid 'a,b' vs 'b,a' diffs
        # Trim whitespace and remove empty entries to match jq logic
        local normalized_ext
        normalized_ext=$(echo "${extensions}" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | sort | tr '\n' ',' | sed 's/,$//')
        
        local normalized_kargs
        normalized_kargs=$(echo "${kernel_args}" | tr ' ' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | sort | tr '\n' ',' | sed 's/,$//')

        local ext_hash
        ext_hash=$(echo "${normalized_ext}|${normalized_kargs}" | md5sum | cut -c1-8)
        suffix="${role}-${ext_hash}-${ARCH}"
    fi

    # Append 'nv' suffix for Nested Virtualization
    if [ "$nested_virt" == "true" ]; then
        suffix="${suffix}-nv"
    fi
    
    local image_name="talos-${safe_ver}-${suffix}"
    local gcs_object="${image_name}.tar.gz"
    
    # Logic to determine Installer Image & Download URL
    local installer_image=""
    local download_url=""
    
    if [ -n "$extensions" ] || [ -n "$kernel_args" ]; then
        log "[${role^^}] Resolving Factory Schematic for Extensions='${extensions}' Args='${kernel_args}'"
        local schematic_id
        schematic_id=$(get_schematic_id "$version" "$extensions" "$kernel_args")
        
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
        
        # Fallback to Factory for Vanilla if GitHub Release fails
        if [ -z "$download_url" ]; then
             warn "GitHub release artifact not found for ${version}. Trying Factory for Vanilla image..."
             local schematic_id
             # Pass empty strings for extensions/args to get defaults
             if schematic_id=$(get_schematic_id "$version" "" ""); then
                 if ! download_url=$(get_factory_url "${schematic_id}" "${version}"); then
                     error "Factory fallback failed."
                     return 1
                 fi
                 # Update installer image to use Factory since GHCR might be missing too
                 installer_image="factory.talos.dev/image/${schematic_id}/${version}/installer"
                 log "Resolved Vanilla image via Factory (Schematic: ${schematic_id})"
             fi
         fi
    fi
    
    # Export variables
    if [ "$role" == "cp" ]; then
        export CP_IMAGE_NAME="$image_name"
        export CP_INSTALLER_IMAGE="$installer_image"
    else
        export WORKER_IMAGE_NAME="$image_name"
        export WORKER_INSTALLER_IMAGE="$installer_image"
    fi
    
    log "[${role^^}] Configured: Image=${image_name}, Installer=${installer_image}, NestedVirt=${nested_virt}"

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
    log "  -> Creating GCP Image resource (NestedVirt=${nested_virt})..."
    
    local -a LICENSES_FLAG=()
    if [ "$nested_virt" == "true" ]; then
        # Required for Nested Virtualization
        LICENSES_FLAG=("--licenses=projects/vm-options/global/licenses/enable-vmx")
    fi
    
    if ! gcloud compute images create "${image_name}" \
        --source-uri="gs://${BUCKET_NAME}/${gcs_object}" \
        --guest-os-features=VIRTIO_SCSI_MULTIQUEUE \
        "${LICENSES_FLAG[@]}" \
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

    # 1. Control Plane Image (Standard)
    ensure_single_image "cp" "${CP_TALOS_VERSION}" "${CP_EXTENSIONS}" "${CP_KERNEL_ARGS}" || return 1
    
    # 2. Worker Images (Per Pool)
    # Iterate over all defined pools to ensure their specific images exist.
    if [ -n "${NODE_POOLS:-}" ]; then
        for pool in "${NODE_POOLS[@]}"; do
            local safe_pool="${pool//-/_}"
            local pool_ext_var="POOL_${safe_pool^^}_EXTENSIONS"
            local pool_kargs_var="POOL_${safe_pool^^}_KERNEL_ARGS"
            local pool_nv_var="POOL_${safe_pool^^}_ALLOW_NESTED_VIRT"
            
            # Resolve Pool Specifics -> Generic Pool Defaults -> Global Defaults
            # Note: POOL_EXTENSIONS defaults to WORKER_EXTENSIONS in config.sh, so we just check POOL_EXTENSIONS fallback
            local extensions="${!pool_ext_var:-$POOL_EXTENSIONS}"
            local kernel_args="${!pool_kargs_var:-$POOL_KERNEL_ARGS}"
            local nested_virt="${!pool_nv_var:-false}"
            
            log "Ensuring image for pool '${pool}' (Ext: ${extensions}, KArgs: ${kernel_args}, NestedVirt: ${nested_virt})..."
            ensure_single_image "worker" "${WORKER_TALOS_VERSION}" "${extensions}" "${kernel_args}" "${nested_virt}" || return 1
        done
    else
        # Fallback for legacy single-worker setup
        ensure_single_image "worker" "${WORKER_TALOS_VERSION}" "${WORKER_EXTENSIONS}" "${WORKER_KERNEL_ARGS}" || return 1
    fi
}
