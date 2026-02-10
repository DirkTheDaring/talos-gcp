#!/bin/bash

# --- Phase 1: Resource Gathering ---

# Helper to check url with timeout
check_url() {
    curl --connect-timeout 10 --http1.1 --output /dev/null --silent --head --fail "$1"
}

# Helper to resolve image for a given version
# Returns path to image or empty string
resolve_image_for_version() {
    local version="$1"
    local image_sr=""
    
    log "Checking for GCP image in Talos version ${version}..."

    # 0. Talos Image Factory (Primary for v1.5+)
    log "Attempting to resolve via Talos Image Factory..."
    # Create default schematic
    local schematic_id=""
    local factory_response=""
    
    # POST empty customization to get ID
    # Using -k (insecure) only if desperate, but let's stick to standard SSL.
    # Format payload as JSON or YAML. JSON is safer.
    factory_response=$(curl --connect-timeout 10 -s -X POST "https://factory.talos.dev/schematics" \
        -H "Content-Type: application/json" \
        -d '{"customization": {}}')
        
    if [ -n "$factory_response" ]; then
        schematic_id=$(echo "$factory_response" | jq -r .id 2>/dev/null)
    fi
    
    if [ -n "$schematic_id" ] && [ "$schematic_id" != "null" ]; then
        log "Got Schematic ID: $schematic_id"
        # Construct Factory URL
        # Try variations of the filename
        local found_factory_url=""
        local factory_variations=(
            "gcp-$ARCH.tar.gz"
            "gcp-$ARCH.raw.tar.gz"
            "gcp-$ARCH.disk.raw.tar.gz"
            "talos-gcp-$ARCH.tar.gz"
        )
        
        for variation in "${factory_variations[@]}"; do
            local test_url="https://factory.talos.dev/image/$schematic_id/$version/$variation"
            if check_url "$test_url"; then
                echo "$test_url"
                found_factory_url="true"
                break
            fi
        done
        
        if [ -n "$found_factory_url" ]; then
            return 0
        else
                warn "Factory URL not accessible for any variation (e.g. $factory_url)"
        fi
    else
        warn "Could not obtain Schematic ID from Factory API."
    fi

    # 1. Check cloud-images.json (Secondary)
    local cloud_images_url="https://github.com/siderolabs/talos/releases/download/${version}/cloud-images.json"
    
    if check_url "$cloud_images_url"; then
        curl --connect-timeout 10 --http1.1 -s -L -o cloud-images.json "$cloud_images_url"
        # Extract GCP image URL (Platform=gcp or Cloud=gcp)
        image_sr=$(jq -r --arg arch "$ARCH" '.[] | select((.cloud == "gcp" or .platform == "gcp") and .arch == $arch) | .url' cloud-images.json 2>/dev/null || echo "")
        rm -f cloud-images.json
        
        if [ -n "$image_sr" ] && [ "$image_sr" != "null" ]; then
            echo "$image_sr"
            return 0
        fi
    fi

    # 2. Check Legacy / Direct URLs (Tertiary)
    local possible_urls=(
        "https://github.com/siderolabs/talos/releases/download/${version}/gcp-${ARCH}.tar.gz"
        "https://github.com/siderolabs/talos/releases/download/${version}/gcp-${ARCH}.raw.tar.gz"
        "https://github.com/siderolabs/talos/releases/download/${version}/talos-gcp-${ARCH}.tar.gz"
    )
    
    for url in "${possible_urls[@]}"; do
            if check_url "$url"; then
                echo "$url"
                return 0
            fi
    done
    
    return 1
}

phase1_resources() {
    log "Phase 1: Resource Gathering..."
    check_apis
    check_quotas
    check_permissions
    
    # Identity management
    ensure_service_account
    
    # Check if variable is set (even if empty, though set -u catches unset)
    local target_version="${TALOS_VERSION:-}"

    # Determine Version Strategy
    if [ -n "${TALOS_VERSION:-}" ]; then
        # User specified version, stick to it
        log "Using configured Talos Version: ${TALOS_VERSION}"
        IMAGE_SOURCE=$(resolve_image_for_version "$TALOS_VERSION")
        if [ -z "$IMAGE_SOURCE" ]; then
            error "Could not find valid GCP image for user-specified version ${TALOS_VERSION}."
            exit 1
        fi
    else
        # Auto-detect latest WORKING version (GCP image exists)
        log "Fetching recent Talos versions to find latest with GCP support..."
        
        # Get last 5 releases
        RECENT_VERSIONS=$(curl --http1.1 -s "https://api.github.com/repos/siderolabs/talos/releases?per_page=5" | jq -r '.[].tag_name' 2>/dev/null)
        
        if [ -z "$RECENT_VERSIONS" ]; then
            warn "Could not fetch releases from GitHub API."
                # Fallback to hardcoded stable if API fails completely
            RECENT_VERSIONS="v1.9.1" 
        fi
        
        FOUND_VERSION=""
        
        for version in $RECENT_VERSIONS; do
            log "Checking version: ${version}..."
            img_src=$(resolve_image_for_version "$version" || true)
            
            if [ -n "$img_src" ]; then
                log "Found valid GCP image for ${version}!"
                TALOS_VERSION="$version"
                IMAGE_SOURCE="$img_src"
                FOUND_VERSION="true"
                break
            else
                log "Version ${version} does not appear to have GCP images. Skipping."
            fi
        done
        
        if [ -z "$FOUND_VERSION" ]; then
            error "FATAL: Could not find any recent Talos version with GCP images."
            error "Checked versions: $(echo $RECENT_VERSIONS | tr '\n' ' ')"
            exit 1
        fi
    fi

    # Refresh Image Name based on potentially new version
    TALOS_IMAGE_NAME="talos-${TALOS_VERSION//./-}-gcp-${ARCH}"
    export TALOS_IMAGE_NAME
    
    # Create output directory for artifacts (Ensure it exists)
    mkdir -p "${OUTPUT_DIR}"

    local gcs_object="talos-${TALOS_VERSION}-${ARCH}.tar.gz"

    log "Resolved Talos Version: ${TALOS_VERSION}"
    
    # 0.5. Download matching talosctl to ensure compatibility/prevent crashes
    log "Ensuring local talosctl matches ${TALOS_VERSION}..."
    local TALOSCTL_BIN="${OUTPUT_DIR}/talosctl"
    
    if [ ! -f "${TALOSCTL_BIN}" ]; then
        log "Copying verified talosctl from PATH..."
        cp "$(which talosctl)" "${TALOSCTL_BIN}"
        chmod +x "${TALOSCTL_BIN}"
    else
        log "Using existing local talosctl binary (${TALOSCTL_BIN})."
    fi

    
    # Refresh wrapper in case we just downloaded it
    check_dependencies

    log "Resolved Image Name: ${TALOS_IMAGE_NAME}"
    log "Resolved GCS Object: ${gcs_object}"
    log "Image Source: ${IMAGE_SOURCE}"

    if ! gsutil ls -b "gs://${BUCKET_NAME}" &> /dev/null; then
        log "Creating GCS Bucket: gs://${BUCKET_NAME}..."
        # Security Hardening: Enforce Public Access Prevention & Uniform Bucket-Level Access
        run_safe gsutil mb -p "${PROJECT_ID}" -c standard -l "${REGION}" -b on --pap enforced "gs://${BUCKET_NAME}"
    else
        log "GCS Bucket gs://${BUCKET_NAME} already exists."
    fi

    if gcloud compute images describe "${TALOS_IMAGE_NAME}" --project="${PROJECT_ID}" &> /dev/null; then
        log "Talos image '${TALOS_IMAGE_NAME}' already exists in GCP Project. Skipping download/upload."
    else
        # Check if already in GCS to skip download
        if gsutil ls "gs://${BUCKET_NAME}/${gcs_object}" &> /dev/null; then
                log "Talos image found in GCS bucket (gs://${BUCKET_NAME}/${gcs_object}). Skipping download."
        else
            log "Downloading Talos image..."
            run_safe retry curl --http1.1 -L -o "${OUTPUT_DIR}/talos-gcp.tar.gz" "${IMAGE_SOURCE}"
            
            if [ ! -s "${OUTPUT_DIR}/talos-gcp.tar.gz" ]; then
                error "Download failed: ${OUTPUT_DIR}/talos-gcp.tar.gz is empty."
                exit 1
            fi

            log "Uploading image to GCS..."
            run_safe retry gsutil cp "${OUTPUT_DIR}/talos-gcp.tar.gz" "gs://${BUCKET_NAME}/${gcs_object}"
            rm -f "${OUTPUT_DIR}/talos-gcp.tar.gz"
        fi

        log "Registering image '${TALOS_IMAGE_NAME}' in GCP..."
        if ! gcloud compute images create "${TALOS_IMAGE_NAME}" \
            --source-uri="gs://${BUCKET_NAME}/${gcs_object}" \
            --guest-os-features=VIRTIO_SCSI_MULTIQUEUE \
            --project="${PROJECT_ID}" 2>/dev/null; then
            
            # Check if it failed because it exists (Race condition)
            if gcloud compute images describe "${TALOS_IMAGE_NAME}" --project="${PROJECT_ID}" &>/dev/null; then
                log "Image '${TALOS_IMAGE_NAME}' was created by another process. Proceeding."
            else
                error "Failed to create image '${TALOS_IMAGE_NAME}'."
                exit 1
            fi
        fi
    fi
}
