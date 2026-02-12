# Advanced Usage & Features

## 1. Phased Deployment
For debugging or granular control, you can run the deployment in phases instead of all at once.

```bash
./talos-gcp phase1  # Resources (Image, Bucket)
./talos-gcp phase2  # Infrastructure (VPC, VMs)
./talos-gcp phase3  # Wait for RUNNING state
./talos-gcp phase4  # Bastion Setup
./talos-gcp phase5  # Bootstrap & Register
```

## 2. Diagnostics
If the cluster is not behaving as expected, run the built-in diagnostics tool. It checks GCP permissions, quotas, network reachability, and service account status.

```bash
./talos-gcp diagnose
```

## 3. Storage & CSI
The cluster comes pre-configured with the **GCP Compute Persistent Disk CSI Driver**.

*   **Mechanism**: Nodes use the attached Service Account (`talos-cluster-sa` with `compute.storageAdmin`) to provision disks.
*   **StorageClasses**:
    *   `standard-rwo`: Balanced Persistent Disk.
    *   `premium-rwo`: SSD Persistent Disk.

**Example Usage**:
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: fast-storage
spec:
  accessModes: [ "ReadWriteOnce" ]
  storageClassName: premium-rwo
  resources:
    requests:
      storage: 50Gi
```

## 4. Public Access & DNS
The cluster runs the **GCP Cloud Controller Manager (CCM)**, enabling standard LoadBalancer integration.

### Expose a Service
```bash
kubectl expose deployment nginx --type=LoadBalancer --port=80
```

### Check IP
```bash
./talos-gcp public-ip
```

### DNS Setup
Create an **A Record** in your DNS provider pointing to the `EXTERNAL-IP` returned by the command above.

## 5. Configuration Reference (Expert)

## Manual Load Balancing (Legacy / HostPort Mode)

**WARNING**: This configuration is generally NOT recommended for standard Kubernetes deployments. Use `update-traefik` (Option 3 in Services Guide) instead.

### When to use this?
*   You want to run an Ingress Controller (like Traefik) as a **DaemonSet** using `hostNetwork: true` or `hostPort: 80`.
*   You want a simple "Layer 4 passthrough" where GCP dumps all traffic to your nodes, bypassing K8s Services logic.
*   You want to save money by reusing a single pre-provisioned Load Balancer for non-standard ports.

### Configuration
Set `INGRESS_IPV4_CONFIG` in your `cluster.env`:
```bash
INGRESS_IPV4_CONFIG="80,443"
```
Then run `apply-ingress`. This creates a GCP Forwarding Rule that sends all traffic on ports 80 and 443 to the `talos-worker` Instance Group.

### Conflict with CCM
If you set this, **do NOT** try to create a Kubernetes Service with `type: LoadBalancer` (and `loadBalancerIP` set to the same IP). They will conflict because both systems will try to create a Forwarding Rule on the same IP+Port.

You can customize the deployment by setting environment variables before running the script.

| Variable | Default | Description |
| :--- | :--- | :--- |
| `PROJECT_ID` | *(current gcloud project)* | GCP Project ID |
| `REGION` | `us-central1` | GCP Region |
| `ZONE` | `us-central1-b` | GCP Zone |
| `CLUSTER_NAME` | `talos-gcp-cluster` | Name of the cluster |
| `MACHINE_TYPE` | `e2-standard-2` | VM Size for generic nodes |
| `VPC_NAME` | `talos-vpc` | Name of the Custom VPC |
| `SUBNET_RANGE` | `10.100.0.0/20` | IP Range for the Subnet |
| `TALOS_VERSION` | *(latest stable)* | Specific Talos version (e.g. `v1.12.3`) |

**Example**:
```bash
export REGION="europe-west1"
export ZONE="europe-west1-b"
export MACHINE_TYPE="e2-highcpu-4"
./talos-gcp create
```

## 6. Cost Saving (Pause/Resume)

If you are not using the cluster (e.g., overnight or on weekends), you can **Stop** all nodes to save on Compute Engine costs.

**Stop Nodes:**
```bash
./talos-gcp stop
```
*Note: You still pay for the Persistent Disks and Static IPs while stopped.*

**Start Nodes:**
```bash
./talos-gcp start
```
The cluster will automatically recover, and nodes will rejoin.

## 7. Troubleshooting & Known Failures

## 8. Scaling and Idempotency

The deployment script's `apply` command is **idempotent**, meaning it converges the current state of the cluster to the desired state defined in your configuration.

### How `apply` works:
1.  **Reads Configuration**: Loads `WORKER_COUNT` from `cluster.env` (or environment variables).
2.  **Identifies Nodes**: Lists all instances with label `cluster=${CLUSTER_NAME}` and role `worker`.
3.  **Calculates Diff**:
    *   **Missing Nodes**: If `Current < Target`, it creates new instances (e.g., `worker-3`, `worker-4`).
    *   **Extra Nodes**: If `Current > Target`, it identifies the highest-indexed nodes for removal.
4.  **Pruning Safety**:
    *   Before deleting any node, the script **prompts for confirmation** (`Are you sure you want to DELETE...?`).
    *   To bypass this prompt (e.g., in CI/CD pipelines), use the `--yes` or `-y` flag:
        ```bash
        ./talos-gcp apply --yes
        ```

This design allows you to manage the cluster size declaratively by simply updating the `WORKER_COUNT` variable.

## 9. Orphan Management

Over time, cloud environments can accumulate "orphaned" resources—items that are no longer attached to any active cluster but still incur costs. The `talos-gcp` CLI includes a built-in tool to detect and clean up these leftovers.

**Scope:** This command scans the **Entire GCP Project**, not just the current cluster. This is intentional, as orphans often persist after a cluster mechanism has failed or been deleted.

### Detect Orphans
To list all potential orphans without making any changes:

```bash
./talos-gcp orphans
# or
./talos-gcp orphans list
```

**Scanned Resources:**
*   **Unattached Disks**: Persistent Disks with no attached instances.
*   **Unused Static IPs**: Reserved IP addresses not bound to any forwarding rule.
*   **Dangling Images**: `talos-*` images that are not the boot disk for any running instance.
*   **Zombie Load Balancers**: Forwarding Rules pointing to empty or non-existent target pools.

### Cleanup Orphans
To interactively clean up resources:

```bash
./talos-gcp orphans clean
```

**Safety Features:**
1.  **Selection**: You must explicitly select resources by ID (e.g., `1,3,5`).
2.  **Confirmation**: A final `[y/N]` prompt is required for each deletion.
3.  **Recent Detach Protection**: If you try to delete a disk that was detached **less than 1 hour ago**, the tool will warn you and require a secondary confirmation. This prevents accidental deletion of disks during maintenance or reboots.

