#!/bin/bash

# --- Colors ---
RED=$'\e[0;31m'
GREEN=$'\e[0;32m'
YELLOW=$'\e[1;33m'
BLUE=$'\e[0;34m'
NC=$'\e[0m'

log() { echo -e "${GREEN}[INFO] $1${NC}" >&2; }
warn() { echo -e "${YELLOW}[WARN] $1${NC}" >&2; }
error() { echo -e "${RED}[ERROR] $1${NC}" >&2; }
info() { echo -e "${BLUE}[DEBUG] $1${NC}"; }

# Retry Wrapper
retry() {
    local max_attempts=8
    local timeout=1
    local attempt=1
    local exitCode=0

    while (( attempt <= max_attempts ))
    do
        "$@" && return 0
        exitCode=$?

        if (( attempt == max_attempts )); then
            error "Command failed after $max_attempts attempts: $*"
            return $exitCode
        fi

        warn "Command failed (Attempt $attempt/$max_attempts). Retrying in $timeout seconds..."
        sleep $timeout
        (( attempt++ ))
        timeout=$(( timeout * 2 ))
    done
}

# Error Handling Wrapper
run_safe() {
    "$@" || {
        local status=$?
        error "Command failed: $*"
        error "Exit Code: $status"
        echo "Tip: Run './talos-gcp diagnose' to check the state of your environment." >&2
        return $status
    }
}

# Run command on Bastion (Tunnel Support)
run_on_bastion() {
    local cmd="$1"
    
    # Execute
    # -q: Quiet
    # -o StrictHostKeyChecking=no: Prevent prompt
    # -o UserKnownHostsFile=/dev/null: Prevent known_hosts pollution
    # --tunnel-through-iap: Enable access for private instances
    if ! gcloud compute ssh "${BASTION_NAME}" \
        --zone "${ZONE}" \
        --project="${PROJECT_ID}" \
        --tunnel-through-iap \
        --command "${cmd}" \
        -- -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null; then
        warn "Failed to execute command on bastion. (Bastion might be down or not reachable via IAP)"
        return 1
    fi
}
