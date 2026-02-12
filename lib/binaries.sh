#!/bin/bash

# --- Binary Management Library ---
# Handles resolution and downloading of versioned binaries (talosctl, kubectl).

# Base Directory for Tools
TOOLS_BASE_DIR="$(pwd)/_out/tools"

# Ensure_tool: Checks for binary, downloads if missing.
# Usage: ensure_tool <binary_name> <version>
# Returns: Absolute path to the binary.
# Fails: If download fails or is impossible.
ensure_tool() {
    local name="$1"
    local version="$2"
    
    if [ -z "$name" ] || [ -z "$version" ]; then
        error "ensure_tool: Missing arguments (name or version)."
        exit 1
    fi

    # Define Versioned Path
    local version_dir="${TOOLS_BASE_DIR}/${version}"
    local binary_path="${version_dir}/${name}"

    # 1. Check if exists and is executable
    if [ -x "$binary_path" ]; then
        # Optional: specific version check if needed, but path separating by version usually suffices.
        # We trust the path structure vX.Y.Z contains vX.Y.Z.
        echo "$binary_path"
        return 0
    fi

    # 2. Download if missing
    log "Binary '${name}' (${version}) not found at ${binary_path}."
    log "Attempting to download..."

    mkdir -p "${version_dir}"

    local url=""
    local os=$(uname -s | tr '[:upper:]' '[:lower:]')
    local arch="${ARCH:-amd64}" # Default to amd64 if not set, though config.sh sets it.

    case "$name" in
        talosctl)
            # URL: https://github.com/siderolabs/talos/releases/download/${version}/talosctl-${os}-${arch}
            url="https://github.com/siderolabs/talos/releases/download/${version}/talosctl-${os}-${arch}"
            ;;
        kubectl)
            # URL: https://dl.k8s.io/release/${version}/bin/${os}/${arch}/kubectl
            url="https://dl.k8s.io/release/${version}/bin/${os}/${arch}/kubectl"
            ;;
        *)
            error "Unknown binary: $name"
            exit 1
            ;;
    esac

    if ! curl -L --fail --silent --show-error -o "${binary_path}" "$url"; then
        error "Failed to download ${name} from ${url}."
        rm -f "${binary_path}" # Cleanup partial
        exit 1
    fi

    chmod +x "${binary_path}"
    log "Downloaded ${name} (${version}) successfully."
    
    echo "$binary_path"
}

# Get_tool_path: Returns path if exists, else empty.
# Usage: get_tool_path <binary_name> <version>
get_tool_path() {
    local name="$1"
    local version="$2"
    local binary_path="${TOOLS_BASE_DIR}/${version}/${name}"

    if [ -x "$binary_path" ]; then
        echo "$binary_path"
    else
        echo ""
    fi
}
