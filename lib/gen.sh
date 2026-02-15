#!/bin/bash

# --- Configuration Generation Library ---
# Handles offline generation of Talos configurations by mocking cloud dependencies.

cmd_gen_config() {
    # 1. defined mocked gsutil function
    # We define it as a function so it overrides the system command for this scope
    function gsutil() {
        echo "MOCK gsutil: $@" >&2
        if [[ "$1" == "-q" && "$2" == "stat" ]]; then
            # If secrets.yaml exists locally, pretend it exists remotely
            if [ -f "${OUTPUT_DIR}/secrets.yaml" ]; then
                return 0
            fi
            return 1
        fi
        # Ignore cp or other commands
        return 0
    }
    
    # Export it so subshells use it? Bash functions aren't exported by default.
    # But generation functions rely on it being present in the environment if they call `gsutil`.
    # `run_safe` might shadow it if it calls binary directly, but `run_safe` calls "$@" which resolves function first in bash.
    export -f gsutil

    log "Starting Offline Configuration Generation..."
    
    # Ensure variables
    export TALOSCTL_FORCE_BINARY=true
    
    # Ensure tools (after config.sh defines versions)
    # We assume 'check_dependencies' or 'talos-gcp' has already set up basics, 
    # but we need to ensure TALOSCTL/KUBECTL vars are set for the generation scripts.
    if [ -z "${TALOSCTL:-}" ]; then
         export TALOSCTL=$(ensure_tool "talosctl" "${CP_TALOS_VERSION}")
    fi
     if [ -z "${KUBECTL:-}" ]; then
         export KUBECTL=$(ensure_tool "kubectl" "${KUBECTL_VERSION}")
    fi

    # Ensure output dir exists
    echo "DEBUG: OUTPUT_DIR='$OUTPUT_DIR'"
    mkdir -p "$OUTPUT_DIR"

    log "Running generate_talos_configs (MOCKED)..."
    generate_talos_configs

    # Generate Pool Configs manually
    # This logic matches what was in gen_config_only.sh
    
    # We need to source workers.sh if not availability (it is sourced by talos-gcp)
    # But just in case:
    if ! type generate_pool_config_inline &>/dev/null; then
         source "${SCRIPT_DIR}/lib/workers.sh"
    fi

    log "Generating worker-mon.yaml..."
    generate_pool_config_inline \
        "$OUTPUT_DIR/worker.yaml" \
        "$OUTPUT_DIR/worker-mon.yaml" \
        "role=ceph-mon" \
        "role=ceph-mon:NoSchedule" \
        "true" \
        "${POOL_MON_EXTENSIONS:-$POOL_EXTENSIONS}" \
        "${POOL_MON_KERNEL_ARGS:-$POOL_KERNEL_ARGS}" \
        "${WORKER_OPEN_TCP_PORTS:-}" \
        "${WORKER_OPEN_UDP_PORTS:-}"

    log "Generating worker-osd.yaml..."
    generate_pool_config_inline \
        "$OUTPUT_DIR/worker.yaml" \
        "$OUTPUT_DIR/worker-osd.yaml" \
        "role=ceph-osd" \
        "" \
        "true" \
        "${POOL_OSD_EXTENSIONS:-$POOL_EXTENSIONS}" \
        "${POOL_OSD_KERNEL_ARGS:-$POOL_KERNEL_ARGS}" \
        "${WORKER_OPEN_TCP_PORTS:-}" \
        "${WORKER_OPEN_UDP_PORTS:-}"

    log "Config generation complete."
    
    # Unset mock
    unset -f gsutil
}
