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

generate_pool_config_inline() {
    local base_file="$1"
    local output_file="$2"
    local labels="$3"
    local taints="$4"
    local use_storage_net="$5"
    local extensions="$6"
    local kernel_args="$7"
    local tcp_ports="$8"
    local udp_ports="$9"

    local gen_script="${OUTPUT_DIR}/gen_pool_config.py"
    
    cat <<'PYEOF' > "${gen_script}"
import sys
import yaml
import os
import traceback

def generate_pool_config(base_file, output_file, labels_str, taints_str, use_storage_net_str, extensions_str, kernel_args_str, open_tcp_ports, open_udp_ports):
    # Validating inputs
    if not os.path.exists(base_file):
        print(f"Error: Base file {base_file} not found!")
        sys.exit(1)

    try:
        with open(base_file, 'r') as f:
            docs = list(yaml.safe_load_all(f))
        
        # Filter out HostnameConfig
        docs = [d for d in docs if d is not None and d.get('kind') != 'HostnameConfig']

        for i, data in enumerate(docs):
            if data is None: continue
            
            # Identify main config
            if 'kind' in data and data['kind'] != 'Config': continue
            if 'machine' not in data and 'cluster' not in data and 'version' not in data: continue

            if 'machine' not in data: data['machine'] = {}
            if 'kubelet' not in data['machine']: data['machine']['kubelet'] = {}
            if 'install' not in data['machine']: data['machine']['install'] = {}
            if 'network' not in data['machine']: data['machine']['network'] = {}

            if 'extraArgs' not in data['machine']['kubelet']:
                data['machine']['kubelet']['extraArgs'] = {}

            # 1. Labels
            if labels_str:
                pairs = labels_str.replace(',', ' ').split()
                sanitized_pairs = []
                for pair in pairs:
                    if '=' in pair: sanitized_pairs.append(pair)
                    else: sanitized_pairs.append(f"{pair}=")
                
                existing = data['machine']['kubelet']['extraArgs'].get('node-labels', "")
                new_lbls = ",".join(sanitized_pairs)
                if existing: new_lbls = existing + "," + new_lbls
                data['machine']['kubelet']['extraArgs']['node-labels'] = new_lbls

            # 2. Taints
            if taints_str:
                input_taints = taints_str.replace(',', ' ').split()
                sanitized = [t for t in input_taints if ':' in t]
                if sanitized:
                    existing = data['machine']['kubelet']['extraArgs'].get('register-with-taints', "")
                    new_t = ",".join(sanitized)
                    if existing: new_t = existing + "," + new_t
                    data['machine']['kubelet']['extraArgs']['register-with-taints'] = new_t

            # 3. Extensions
            if extensions_str:
                ext_list = [{'image': e.strip()} for e in extensions_str.split(',') if e.strip()]
                data['machine']['install']['extensions'] = ext_list

            # 4. Kernel Args
            if kernel_args_str:
                # Handle comma or space separation
                args_list = [a.strip() for a in kernel_args_str.replace(',', ' ').split() if a.strip()]
                data['machine']['install']['extraKernelArgs'] = args_list
                # Resolve conflict: extraKernelArgs cannot be used with grubUseUKICmdline=true
                if 'grubUseUKICmdline' in data['machine']['install']:
                    data['machine']['install']['grubUseUKICmdline'] = False

            # 5. Network (Storage Net)
            if use_storage_net_str == "true":
                 if 'interfaces' not in data['machine']['network']:
                     data['machine']['network']['interfaces'] = []

                 interfaces = data['machine']['network']['interfaces']
                 eth0_found = False
                 eth1_found = False
                 
                 for iface in interfaces:
                     if iface.get('interface') == 'eth0' or (iface.get('deviceSelector') or {}).get('busPath') == '0*':
                         eth0_found = True
                         iface['dhcp'] = True
                         if 'dhcpOptions' in iface:
                             iface['dhcpOptions'].pop('routeMetric', None)
                         
                     if iface.get('interface') == 'eth1' or (iface.get('deviceSelector') or {}).get('busPath') == '1*':
                         eth1_found = True
                         iface['dhcp'] = True
                         if 'dhcpOptions' not in iface: iface['dhcpOptions'] = {}
                         iface['dhcpOptions']['routeMetric'] = 2048

                 if not eth0_found:
                     interfaces.append({'interface': 'eth0', 'dhcp': True, 'mtu': 1460})
                 
                 if not eth1_found:
                     interfaces.append({
                         'deviceSelector': {'busPath': '1*'},
                         'dhcp': True, 
                         'mtu': 1460,
                         'dhcpOptions': {'routeMetric': 2048}
                     })

        with open(output_file, 'w') as f:
            yaml.safe_dump_all(docs, f)

    except Exception:
        traceback.print_exc()
        sys.exit(1)

if __name__ == "__main__":
    generate_pool_config(
        sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], 
        sys.argv[5], sys.argv[6] if len(sys.argv)>6 else "", 
        sys.argv[7] if len(sys.argv)>7 else "", 
        sys.argv[8] if len(sys.argv)>8 else "", 
        sys.argv[9] if len(sys.argv)>9 else ""
    )
PYEOF

    run_safe "${PYTHON_CMD}" "${gen_script}" \
        "${base_file}" "${output_file}" "${labels}" "${taints}" \
        "${use_storage_net}" "${extensions}" "${kernel_args}" \
        "${tcp_ports}" "${udp_ports}"
        
    rm -f "${gen_script}"
}
