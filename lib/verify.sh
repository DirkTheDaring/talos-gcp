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
