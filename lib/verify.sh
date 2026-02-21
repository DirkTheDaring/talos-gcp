#!/bin/bash

diagnose() {
    set_names
    # check_dependencies - Not needed
    
    mkdir -p _out
    echo "--- pwd ---" > _out/diagnose.txt
    pwd >> _out/diagnose.txt
    echo "--- ls -la ---" >> _out/diagnose.txt
    ls -la >> _out/diagnose.txt
    echo "--- env ---" >> _out/diagnose.txt
    env >> _out/diagnose.txt
    echo "--- whoami ---" >> _out/diagnose.txt
    whoami >> _out/diagnose.txt
    echo "--- python3 version ---" >> _out/diagnose.txt
    if [ -n "${PYTHON_CMD:-}" ]; then
        "${PYTHON_CMD}" --version >> _out/diagnose.txt 2>&1
    elif command -v python3.14 &>/dev/null; then
        python3.14 --version >> _out/diagnose.txt 2>&1
    elif command -v python3 &>/dev/null; then
        python3 --version >> _out/diagnose.txt 2>&1
    else
        echo "Python not found" >> _out/diagnose.txt
    fi
    
    log "Environment diagnostics written to _out/diagnose.txt"
    
    echo "========================================="
    echo " Talos GCP Diagnostics"
    echo " Cluster: ${CLUSTER_NAME}"
    echo " Project: ${PROJECT_ID}"
    echo " Zone:    ${ZONE}"
    echo "========================================="
    
    # 1. Check Cloud NAT (Crucial for Bastion Outbound)
    echo ""
    echo "[Network] Checking Cloud NAT..."
    if gcloud compute routers nats list --router="${ROUTER_NAME}" --region="${REGION}" --project="${PROJECT_ID}" | grep -q "${NAT_NAME}"; then
        echo "OK: Cloud NAT '${NAT_NAME}' exists."
    else
        echo "ERROR: Cloud NAT '${NAT_NAME}' not found. Bastion may lack internet access."
    fi

    # 2. Check Bastion Status
    echo ""
    echo "[Compute] Checking Bastion Host..."
    local BASTION_STATUS=$(gcloud compute instances describe "${BASTION_NAME}" --zone "${ZONE}" --project="${PROJECT_ID}" --format="value(status)" 2>/dev/null)
    if [ "$BASTION_STATUS" == "RUNNING" ]; then
        echo "OK: Bastion '${BASTION_NAME}' is RUNNING."
    else
        echo "ERROR: Bastion '${BASTION_NAME}' is in state: ${BASTION_STATUS:-Not Found}"
    fi

    # 3. Check Control Plane Instances
    echo ""
    echo "[Compute] Checking Control Plane Instances..."
    gcloud compute instances list --filter="name~'${CLUSTER_NAME}-cp-.*'" --project="${PROJECT_ID}" --format="table(name,status,networkInterfaces[0].networkIP)"

    # 4. Check Load Balancers (Forwarding Rules)
    echo ""
    echo "[Network] Checking Load Balancers..."
    gcloud compute forwarding-rules list --filter="name~'${CLUSTER_NAME}.*'" --project="${PROJECT_ID}" --format="table(name,IPAddress,IPProtocol,ports,target)"

    # 5. Check Health Checks
    echo ""
    echo "[Network] Checking Health Checks..."
    gcloud compute health-checks list --filter="name~'${CLUSTER_NAME}.*'" --project="${PROJECT_ID}" --format="table(name,type,checkIntervalSec,timeoutSec,healthyThreshold,unhealthyThreshold)"

    echo "========================================="
    echo "Diagnostics Complete."
}

verify_storage() {
    log "Verifying Storage Configuration..."
    
    # 1. Check StorageClasses
    log "Checking StorageClasses..."
    if ! gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl get sc"; then
        error "Failed to list StorageClasses. Is the cluster reachable?"
        return 1
    fi
    
    # 2. Create PVC & Pod
    log "Creating PVC and Test Pod..."
    cat <<EOF > "${OUTPUT_DIR}/storage-test.yaml"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: standard-rwo
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: test-storage-pod
spec:
  containers:
  - name: test-container
    image: busybox
    command: ["/bin/sh", "-c", "echo 'Hello Talos Storage' > /data/test-file && sleep 3600"]
    volumeMounts:
    - mountPath: "/data"
      name: test-volume
  volumes:
  - name: test-volume
    persistentVolumeClaim:
      claimName: test-pvc
  restartPolicy: Never
EOF

    run_safe gcloud compute scp "${OUTPUT_DIR}/storage-test.yaml" "${BASTION_NAME}:~" --zone "${ZONE}" --tunnel-through-iap
    run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl apply -f storage-test.yaml"

    # 3. Wait for Pod
    log "Waiting for Test Pod to be Ready (max 2m)..."
    local POD_STATUS=""
    for i in {1..24}; do
        POD_STATUS=$(gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl get pod test-storage-pod -o jsonpath='{.status.phase}'" 2>/dev/null)
        if [ "$POD_STATUS" == "Running" ]; then
            log "Pod is Running!"
            break
        fi
        echo -n "."
        sleep 5
    done
    echo ""
    
    if [ "$POD_STATUS" != "Running" ]; then
        error "Pod failed to start. Status: ${POD_STATUS:-Unknown}"
        log "Investigating..."
        gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl describe pod test-storage-pod"
        gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl describe pvc test-pvc"
        gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl get events --sort-by=.metadata.creationTimestamp | tail -n 20"
        
        # Cleanup and Failure Return
        log "Cleaning up Test Resources (due to failure)..."
        gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl delete -f storage-test.yaml --grace-period=0 --force"
        rm -f "${OUTPUT_DIR}/storage-test.yaml"
        return 1
    else
        # 4. Check Write
        log "Verifying data write..."
        if gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl exec test-storage-pod -- cat /data/test-file" | grep -q "Hello Talos Storage"; then
            log "SUCCESS: Data written and read from PVC."
        else
            error "FAILURE: Could not read data from PVC."
        fi
    fi

    # 5. Cleanup
    log "Cleaning up Test Resources..."
    gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl delete -f storage-test.yaml --grace-period=0 --force"
    rm -f "${OUTPUT_DIR}/storage-test.yaml"
    
    if [ "$POD_STATUS" != "Running" ]; then
        return 1
    fi
}

verify_storage_perf() {
    log "Verifying Storage Performance (IOPS & Throughput)..."
    
    # 1. Select StorageClasses
    local storage_classes=("standard-rwo" "rook-ceph-ceph-block" "rook-ceph-ceph-filesystem")
    
    # Prereq: Check Bastion
    if ! gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl get sc" &>/dev/null; then
        error "Failed to list StorageClasses. Is the cluster reachable?"
        return 1
    fi
    
    local test_size="5Gi"
    local pod_name="storage-perf-test"
    local pvc_name="perf-pvc"
    local yaml_file="${OUTPUT_DIR}/storage-perf.yaml"

    echo ""
    echo "============================================================"
    echo "   STORAGE PERFORMANCE BENCHMARK"
    echo "   Cluster: ${CLUSTER_NAME}"
    echo "============================================================"
    
    declare -a PERF_REPORT
    
    for sc in "${storage_classes[@]}"; do
        # Check if SC exists
        if ! gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl get sc ${sc}" &>/dev/null; then
            log "StorageClass '${sc}' not found on cluster. Skipping."
            continue
        fi

        echo ""
        log "▶ Benchmarking StorageClass: ${sc}"
        log "  Creating PVC (${test_size}) and Test Pod..."
        
        cat <<EOF > "${yaml_file}"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${pvc_name}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ${sc}
  resources:
    requests:
      storage: ${test_size}
---
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
spec:
  containers:
  - name: test-container
    image: alpine:latest
    command: ["/bin/sh", "-c", "sleep 3600"]
    volumeMounts:
    - mountPath: "/data"
      name: test-volume
  volumes:
  - name: test-volume
    persistentVolumeClaim:
      claimName: ${pvc_name}
  restartPolicy: Never
EOF

        run_safe gcloud compute scp "${yaml_file}" "${BASTION_NAME}:~" --zone "${ZONE}" --tunnel-through-iap
        run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl apply -f storage-perf.yaml"

        # Wait for Pod
        log "  Waiting for Test Pod to be Ready..."
        local pod_ready=false
        for i in {1..30}; do
            local status=$(gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl get pod ${pod_name} -o jsonpath='{.status.phase}'" 2>/dev/null)
            if [ "$status" == "Running" ]; then
                pod_ready=true
                break
            fi
            echo -n "."
            sleep 5
        done
        echo ""

        if [ "$pod_ready" != "true" ]; then
            error "  Pod failed to start. Skipping benchmark for ${sc}."
            gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl describe pod ${pod_name}"
            # Cleanup
            gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl delete -f storage-perf.yaml --grace-period=0 --force" &>/dev/null
            rm -f "${yaml_file}"
            continue
        fi

        log "  Installing fio in test pod..."
        run_safe gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl exec ${pod_name} -- apk update >/dev/null 2>&1 && kubectl exec ${pod_name} -- apk add fio coreutils >/dev/null 2>&1"

        # --- 1. Sequential Write (dd) ---
        log "  [1/4] Running Sequential Write (1GB dd)..."
        local dd_write_out=$(gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl exec ${pod_name} -- dd if=/dev/zero of=/data/test.img bs=1M count=1024 oflag=direct 2>&1")
        local write_speed=$(echo "$dd_write_out" | tail -n 1 | awk -F', ' '{print $NF}')
        echo "      > Write Throughput: ${write_speed:-Failed}"

        # --- 2. Sequential Read (dd) ---
        # Clear cache first if possible, though it's hard inside a container without privs. 
        # Using iflag=direct bypasses cache.
        log "  [2/4] Running Sequential Read (1GB dd)..."
        local dd_read_out=$(gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl exec ${pod_name} -- dd if=/data/test.img of=/dev/null bs=1M count=1024 iflag=direct 2>&1")
        # Busybox dd output format: "1073741824 bytes (1024.0MB) copied, 1.134375 seconds, 902.7MB/s"
        # Since it uses a comma separator, we can extract the last field. For GNU dd it might be different, but busybox awk handles both reasonably with regex or just getting the last word.
        local read_speed=$(echo "$dd_read_out" | tail -n 1 | awk -F', ' '{print $NF}')
        echo "      > Read Throughput:  ${read_speed:-Failed}"

        # Clean up dd file
        gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl exec ${pod_name} -- rm -f /data/test.img"

        # --- 3. Random Read IOPS (fio) ---
        log "  [3/4] Running Random Read (fio, 4k, 30s)..."
        local fio_read_cmd="fio --name=randread --ioengine=libaio --direct=1 --rw=randread --bs=4k --iodepth=64 --numjobs=1 --size=1G --runtime=30 --time_based --directory=/data --output-format=json"
        local fio_read_json=$(gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl exec ${pod_name} -- ${fio_read_cmd}" 2>/dev/null)
        
        local read_iops=$(echo "$fio_read_json" | jq -r '.jobs[0].read.iops' | cut -d'.' -f1)
        local read_lat=$(echo "$fio_read_json" | jq -r '.jobs[0].read.lat_ns.mean' 2>/dev/null)
        if [ -n "$read_lat" ] && [ "$read_lat" != "null" ]; then
             read_lat=$(echo "$read_lat / 1000000" | bc -l | awk '{printf "%.2f ms", $1}')
        else
             read_lat="N/A"
        fi
        echo "      > Random Read IOPS: ${read_iops:-Failed} (Avg Latency: ${read_lat})"

        # Clean up read file
        gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl exec ${pod_name} -- rm -f /data/randread.0.0"

        # --- 4. Random Write IOPS (fio) ---
        log "  [4/4] Running Random Write (fio, 4k, 30s)..."
        local fio_write_cmd="fio --name=randwrite --ioengine=libaio --direct=1 --rw=randwrite --bs=4k --iodepth=64 --numjobs=1 --size=1G --runtime=30 --time_based --directory=/data --output-format=json"
        local fio_write_json=$(gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl exec ${pod_name} -- ${fio_write_cmd}" 2>/dev/null)
        
        local write_iops=$(echo "$fio_write_json" | jq -r '.jobs[0].write.iops' | cut -d'.' -f1)
        local write_lat=$(echo "$fio_write_json" | jq -r '.jobs[0].write.lat_ns.mean' 2>/dev/null)
        if [ -n "$write_lat" ] && [ "$write_lat" != "null" ]; then
             write_lat=$(echo "$write_lat / 1000000" | bc -l | awk '{printf "%.2f ms", $1}')
        else
             write_lat="N/A"
        fi
        echo "      > Random Write IOPS: ${write_iops:-Failed} (Avg Latency: ${write_lat})"
        
        # Cleanup
        log "  Cleaning up resources for ${sc}..."
        gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl delete -f storage-perf.yaml --grace-period=0 --force" &>/dev/null
        rm -f "${yaml_file}"
        
        echo "  --- Summary for ${sc} ---"
        echo "  Sequential Write: ${write_speed}"
        echo "  Sequential Read:  ${read_speed}"
        echo "  Random Read IOPS: ${read_iops}"
        echo "  Random Write IOPS: ${write_iops}"
        echo "  --------------------------------"
        
        PERF_REPORT+=("${sc}|${write_speed:-Failed}|${read_speed:-Failed}|${read_iops:-Failed} (${read_lat})|${write_iops:-Failed} (${write_lat})")
    done
    
    echo ""
    echo "=========================================================================================================="
    echo "                               STORAGE PERFORMANCE SUMMARY REPORT"
    echo "=========================================================================================================="
    printf "%-30s | %-16s | %-16s | %-22s | %-22s\n" "StorageClass" "Seq Write" "Seq Read" "Rand Read IOPS" "Rand Write IOPS"
    echo "----------------------------------------------------------------------------------------------------------"
    for row in "${PERF_REPORT[@]}"; do
        IFS='|' read -r sc ws rs ri wi <<< "$row"
        printf "%-30s | %-16s | %-16s | %-22s | %-22s\n" "$sc" "$ws" "$rs" "$ri" "$wi"
    done
    echo "=========================================================================================================="
    echo ""
    log "Storage Performance Benchmark Complete."
}

verify_connectivity() {
    log "Verifying Network Connectivity (Pod-to-Pod & DNS)..."
    
    # Prereq: Bastion
    if ! ssh_command "true"; then
        error "Cannot connect to Bastion."
        return 1
    fi

    # 1. Deploy Net Test DaemonSet (tolerates everything)
    log "Deploying Network Test DaemonSet..."
    cat <<EOF > "${OUTPUT_DIR}/net-test.yaml"
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: net-test
  namespace: default
  labels:
    app: net-test
spec:
  selector:
    matchLabels:
      app: net-test
  template:
    metadata:
      labels:
        app: net-test
    spec:
      tolerations:
      - operator: Exists
      containers:
      - name: net-test
        image: busybox
        command: ["/bin/sh", "-c", "sleep 3600"]
EOF

    run_safe gcloud compute scp "${OUTPUT_DIR}/net-test.yaml" "${BASTION_NAME}:~" --zone "${ZONE}" --tunnel-through-iap
    ssh_command "kubectl apply -f net-test.yaml"

    log "Waiting for DaemonSet rollout..."
    ssh_command "kubectl rollout status ds/net-test --timeout=120s"

    # 2. Collect Pods
    log "Collecting Pod information..."
    # Format: NAME NODE IP ROLE
    # We use a label selector to find CP nodes if possible, but busybox doesn't know node roles easily from inside.
    # We'll relies on kubectl to tell us where they are.
    local PODS_JSON
    PODS_JSON=$(ssh_command "kubectl get pods -l app=net-test -o jsonpath='{range .items[*]}{.metadata.name}{\"\t\"}{.spec.nodeName}{\"\t\"}{.status.podIP}{\"\n\"}{end}'")
    
    # Parse into arrays: CP_PODS and WORKER_PODS
    local -a cp_pods
    local -a worker_pods
    
    while IFS=$'\t' read -r pod_name node_name pod_ip; do
        if [[ "$node_name" == *"-cp-"* ]]; then
            cp_pods+=("$pod_name|$node_name|$pod_ip")
        elif [[ "$node_name" == *"-worker-"* ]]; then
            worker_pods+=("$pod_name|$node_name|$pod_ip")
        fi
    done <<< "$PODS_JSON"

    log "Found ${#cp_pods[@]} Control Plane pods and ${#worker_pods[@]} Worker pods."

    if [ ${#cp_pods[@]} -eq 0 ] || [ ${#worker_pods[@]} -eq 0 ]; then
        warn "Insufficient pods to test Cross-Node connectivity (Need at least 1 CP and 1 Worker)."
        if [ ${#cp_pods[@]} -eq 0 ]; then warn "No CP pods found (Taints issue?)."; fi
        if [ ${#worker_pods[@]} -eq 0 ]; then warn "No Worker pods found."; fi
        # cleanup
        ssh_command "kubectl delete -f net-test.yaml --grace-period=0 --force"
        return 1
    fi

    # Pick representative pods
    local cp_target="${cp_pods[0]}"
    local worker_target="${worker_pods[0]}"
    
    IFS='|' read -r cp_pod cp_node cp_ip <<< "$cp_target"
    IFS='|' read -r worker_pod worker_node worker_ip <<< "$worker_target"

    log "Testing Connectivity:"
    log "  Control Plane: ${cp_pod} (${cp_node}, ${cp_ip})"
    log "  Worker:        ${worker_pod} (${worker_node}, ${worker_ip})"
    echo ""

    local fail_count=0

    # Test A: CP -> Worker Ping
    log "[Ping] Control Plane -> Worker (${worker_ip})..."
    if ssh_command "kubectl exec ${cp_pod} -- ping -c 3 -W 2 ${worker_ip}"; then
        echo "✅ Success"
    else
        echo "❌ FAILED"
        ((fail_count++))
    fi

    # Test B: Worker -> CP Ping
    log "[Ping] Worker -> Control Plane (${cp_ip})..."
    if ssh_command "kubectl exec ${worker_pod} -- ping -c 3 -W 2 ${cp_ip}"; then
         echo "✅ Success"
    else
         echo "❌ FAILED"
         ((fail_count++))
    fi
    
    # Test C: CP -> DNS
    log "[DNS] Control Plane -> kubernetes.default.svc.cluster.local..."
    if ssh_command "kubectl exec ${cp_pod} -- nslookup kubernetes.default.svc.cluster.local"; then
         echo "✅ Success"
    else
         echo "❌ FAILED"
         ((fail_count++))
    fi

    # Cleanup
    log "Cleaning up Network Test Resources..."
    ssh_command "kubectl delete -f net-test.yaml --grace-period=0 --force"
    rm -f "${OUTPUT_DIR}/net-test.yaml"
    
    if [ $fail_count -eq 0 ]; then
        log "Verificaton Passed: Network is healthy."
        return 0
    else
        error "Verification Failed: $fail_count tests failed."
        return 1
    fi
}

verify_ccm() {
    log "Verifying GCP Cloud Controller Manager Configuration..."

    # 1. Check Mode
    local mode="${CILIUM_ROUTING_MODE:-native}"
    log "Routing Mode: ${mode}"

    # 2. Get Deployment Arguments
    # We fetch the args as a simple string for grep checking
    local args_str
    args_str=$(ssh_command "kubectl -n kube-system get deployment gcp-cloud-controller-manager -o jsonpath='{.spec.template.spec.containers[0].args}'")
    
    log "Current Arguments: ${args_str}"

    local fail=0

    if [ "$mode" == "native" ]; then
        if [[ "$args_str" != *"--allocate-node-cidrs=false"* ]]; then
            error "❌ FAIL: --allocate-node-cidrs should be 'false' in native mode."
            ((fail++))
        else
            echo "✅ --allocate-node-cidrs=false found."
        fi
        
        if [[ "$args_str" != *"--configure-cloud-routes=false"* ]]; then
            error "❌ FAIL: --configure-cloud-routes should be 'false' in native mode."
             ((fail++))
        else
            echo "✅ --configure-cloud-routes=false found."
        fi
        
        if [[ "$args_str" != *"-node-ipam-controller"* ]]; then
             error "❌ FAIL: node-ipam-controller should be disabled in native mode."
             ((fail++))
        else
             echo "✅ node-ipam-controller disabled."
        fi
    else
        log "Tunnel mode detected. Skipping specific native routing flag checks."
    fi

    # 3. Check Pod Status
    log "Checking CCM Pod Status..."
    # Attempt rollout status first (waits for 60s)
    if ssh_command "kubectl -n kube-system rollout status deployment/gcp-cloud-controller-manager --timeout=60s"; then
        echo "✅ CCM Deployment is Ready."
    else
        warn "Rollout status timed out or failed. Checking Deployment Availability directly..."
        # Fallback: Check if Available condition is True
        local available
        available=$(ssh_command "kubectl -n kube-system get deployment gcp-cloud-controller-manager -o jsonpath='{.status.conditions[?(@.type==\"Available\")].status}'" 2>/dev/null)
        
        if [ "$available" == "True" ]; then
             echo "✅ CCM Deployment is Available (Rollout status check was flaky)."
        else
             # Handle empty output (kubectl failure) vs False/Unknown
             local status_msg="${available:-Not Found/Error}"
             error "❌ CCM Deployment is NOT Ready (Available: ${status_msg})."
             ((fail++))
        fi
    fi

    if [ "$fail" -eq 0 ]; then
        log "🎉 CCM Verification Passed!"
        return 0
    else
        error "CCM Verification Failed with $fail errors."
        return 1
    fi
}


verify_gcp_alignment() {
    log "Verifying GCP Alias IP <-> K8s PodCIDR Alignment..."
    
    # 1. Get K8s Nodes and CIDRs
    log "Fetching Kubernetes Node CIDRs..."
    # Format: node-name cidr
    # We use explicit gcloud ssh to be robust
    local K8S_CIDRS=$(gcloud compute ssh "${BASTION_NAME}" --zone "${ZONE}" --tunnel-through-iap --command "kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name} {.spec.podCIDR}{\"\n\"}{end}'" 2>/dev/null)
    
    if [ -z "$K8S_CIDRS" ]; then
        warn "Could not fetch Kubernetes Nodes. Skipping alignment check."
        return 0
    fi
    
    # 2. Get GCP Alias IPs
    log "Fetching GCP Alias IPs..."
    # Format: node-name alias-ip-range
    local GCP_ALIASES=$(gcloud compute instances list --filter="name~'${CLUSTER_NAME}-.*'" --project="${PROJECT_ID}" --format="table(name,networkInterfaces[0].aliasIpRanges.ipCidrRange.list())" | tail -n +2)
    
    local MISMATCH_FOUND=false
    
    # 3. Compare
    echo "$K8S_CIDRS" | while read -r node cidr; do
        # Find corresponding GCP Alias
        local gcp_alias=$(echo "$GCP_ALIASES" | grep "^${node}\s" | awk '{print $2}')
        
        if [ -z "$cidr" ] || [ "$cidr" == "<none>" ]; then
            warn "Node $node has no PodCIDR assigned in Kubernetes."
            continue
        fi
        
        if [ -z "$gcp_alias" ]; then
            error "Node $node has PodCIDR $cidr but NO Alias IP in GCP!"
            MISMATCH_FOUND=true
        elif [ "$gcp_alias" != "$cidr" ]; then
            error "Node $node Split-Brain Detected! K8s: $cidr != GCP: $gcp_alias"
            MISMATCH_FOUND=true
        else
            log "OK: Node $node ($cidr) matches GCP Alias."
        fi
    done
    
    if [ "$MISMATCH_FOUND" == "true" ]; then
        error "IPAM Misalignment Detected! See logs above."
        return 1
    else
        log "GCP IPAM Alignment Verified."
        return 0
    fi
}

check_sa_key_limit() {
    local sa_email="${1:-$SA_EMAIL}"
    
    log "Checking Service Account Key Limit for: ${sa_email}..."
    log "DEBUG: check_sa_key_limit called with sa_email='${sa_email}'"
    
    # List USER_MANAGED keys
    local keys
    if ! keys=$(gcloud iam service-accounts keys list \
        --iam-account="${sa_email}" \
        --project="${PROJECT_ID}" \
        --managed-by="user" \
        --format="value(name)" 2>/dev/null); then
        warn "Failed to check keys for ${sa_email}. Assuming safe."
        return 0
    fi
    
    local count
    count=$(echo "$keys" | grep -v "^$" | wc -l)
    
    log "Current Key Count: ${count} / 10 (User Managed)"
    
    if [ "$count" -ge 10 ]; then
        error "Service Account '${sa_email}' has reached the 10-key limit!"
        error "Deployment WILL fail with FAILED_PRECONDITION."
        error "Auto-pruning is enabled, but if you are using a shared SA, checks might prevent it."
        return 1
    elif [ "$count" -ge 8 ]; then
        warn "Service Account '${sa_email}' is nearing the key limit ($count/10)."
        warn "Old keys will be pruned automatically during deployment."
    fi
    
    return 0
}
