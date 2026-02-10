# Talos on GCP Deployment Script

This script automates the deployment of a Talos Linux cluster on Google Cloud Platform (GCP). It follows the [official Sidero Labs documentation](https://docs.siderolabs.com/talos/v1.12/platform-specific-installations/cloud-platforms/gcp).

## Prerequisites
Before running the script, you must prepare your Google Cloud environment (Project, Billing, APIs, Permissions).

👉 **[Read the GCP Preparation Guide](docs/gcp-preparation.md)**

Ensure you have the following tools installed locally:
- `gcloud` (Google Cloud CLI)
- `talosctl` (Talos CLI)
- `jq` (JSON processor)
- `gsutil` (Part of gcloud)

## Configuration
You can customize the deployment by setting environment variables before running the script:

| Variable | Description | Default |
| :--- | :--- | :--- |
| `PROJECT_ID` | GCP Project ID | *(Detected)* |
| `REGION` | GCP Region | `us-central1` |
| `ZONE` | GCP Zone | `us-central1-b` |
| `CLUSTER_NAME` | Name of the Talos Cluster | `talos-gcp-cluster` |
| `CP_MACHINE_TYPE` | Control Plane Machine Type | `e2-standard-2` |
| `WORKER_MACHINE_TYPE` | Worker Machine Type | `e2-standard-2` |
| `CP_DISK_SIZE` | Control Plane **Boot Disk** Size | `20GB` |
| `WORKER_DISK_SIZE` | Worker **Boot Disk** Size | `20GB` |
| `CP_COUNT` | Number of Control Plane Nodes | `3` |
| `WORKER_COUNT` | Number of Worker Nodes | `1` |
| `TALOS_VERSION` | Talos Version (e.g., v1.8.0) | *(Latest Valid)* |

## Architecture

```ascii
+----------------------------------------------------------------------------------------------------+
| GCP Project (talos-vpc / 10.0.0.0/24)                                                              |
|                                                                                                    |
|   +-----------------+           +-----------------------+            +---------------------+       |
|   |  Bastion Host   |           |     Control Plane     |            |     Worker Nodes    |       |
|   | (talos-bastion) |---------->| (talos-controlplane*) |----------->|   (talos-worker*)   |       |
|   |  [Internal IP]  |           |     [Internal IP]     |            |    [Internal IP]    |       |
|   +--------^--------+           +-----------^-----------+            +----------|----------+       |
|            |                                |api (6443)                         |                  |
|       (IAP Tunnel)                          |                                   v                  |
|            ^                          (Internal LB)                        (Cloud NAT)             |
|            |                                ^                                   |                  |
|  +---------+---------+          +-----------+-----------+                       v                  |
|  |   Admin User      |          |   Public LoadBalancer |                   (Internet)             |
|  | (gcloud ssh ...)  |          |      (External IP)    |                                          |
|  +-------------------+          +-----------------------+                                          |
+----------------------------------------------------------------------------------------------------+
```

## Architecture & Networking

This deployment creates a high-availability Control Plane using Google Cloud's **Global TCP Load Balancer**.

### Application Flow
1.  **Frontend**: A global Anycast IP (`talos-lb-ip`) listens on **TCP port 443**.
2.  **Load Balancer**: Forwards traffic to the `talos-ig` Instance Group.
3.  **Health Check**: The LB probes each node on port **6443** (Kubernetes API).
    *   **Control Plane Nodes**: Pass the check (API Server is running) -> Receive traffic.
    *   **Worker Nodes**: Fail the check (No API Server) -> Ignored by LB.
4.  **Backend**: Traffic reaches port 6443 on a healthy Control Plane node.

### Access Configuration
The script automatically retrieves the Load Balancer's public IP and embeds it into the generated configuration files:
*   **talosconfig**: `endpoints: [ <LB_IP> ]`
*   **kubeconfig**: `server: https://<LB_IP>:443`

This ensures that all administrative commands (`talosctl`, `kubectl`) are routed through the highly available Load Balancer, providing resilience against individual node failures.

## Usage

### 0. Quickstart (Default Cluster)
Creates a cluster named `talos-gcp-cluster`.
```bash
./talos-gcp create
```
*Note: If `CLUSTER_NAME` is unset, the script will warn you and default to `talos-gcp-cluster` after 5 seconds.*

### 1. Multi-Cluster Support (New!)
To create a second, isolated cluster (e.g., `dev-cluster`):

```bash
export CLUSTER_NAME="dev-cluster"
./talos-gcp create
```

**Key Features:**
*   **Isolation:** Each cluster gets its own VPC (`dev-cluster-vpc`), Subnet, NAT, and FW rules.
*   **State:** Configurations are stored in `_out/dev-cluster/` and `gs://BUCKET/dev-cluster/secrets.yaml`.
*   **Safety:** Resource deletion is scoped by label `cluster=dev-cluster`.

### 2. Operational Commands
All commands respect the active `CLUSTER_NAME`.

**Check Status:**
```bash
export CLUSTER_NAME="dev-cluster"
./talos-gcp status
```

**Scale Workers:**
```bash
export CLUSTER_NAME="dev-cluster"
./talos-gcp scale 5
```

**Diagnose:**
```bash
export CLUSTER_NAME="dev-cluster"
./talos-gcp diagnose
```

### 3. Verification & Access
Once deployed, the script generates `talosconfig` and `kubeconfig` in `_out/${CLUSTER_NAME}/`.
Secure access is available via IAP Tunneling (see [docs/secure-access.md](docs/secure-access.md)).

## Scaling
You can explicitly set the number of workers, or add/remove them incrementally:
```bash
# Scale to a specific number of workers (e.g., 5)
./talos-gcp scale 5

# Add a new worker node (+1)
./talos-gcp scale-up

# Remove the worker node with the highest index
./talos-gcp scale-down
```

## Secure Access (No SSH Shell)
For enhanced security, you can access the cluster without SSH keys or a login shell on the bastion. This uses **IAP TCP Forwarding**, which authenticates via Google Cloud IAM.

👉 **[Read the Secure Access Guide](docs/secure-access.md)**

## Documentation
*   **[GCP Prep Guide](docs/gcp-preparation.md)**: permission and project setup.
*   **[Access Guide](docs/access-guide.md)**: Detailed instructions on connecting via SSH, Tunnels, and local `kubectl`, including secure IAP methods.
*   **[Architecture & Design](docs/architecture.md)**: Explanations of networking (IP Aliasing) and storage patterns.
*   **Storage**: See "Configuration Details" > "CSI Driver" below.

## Configuration Details

### Cloud Controller Manager (CCM)
The script deploys the GCP CCM (`registry.k8s.io/cloud-provider-gcp/cloud-controller-manager:v28.2.1`) with specific flags to ensure compatibility with Talos:
*   `--configure-cloud-routes=false`: Disabled to prevent conflicts with Talos CNI (Flannel/Cilium).
*   `--allocate-node-cidrs=true`: Enabled to allow IPAM to function correctly.
*   `--cluster-cidr=10.244.0.0/16`: Matches default Talos PodCIDR to ensure correct node initialization.

### CSI Driver (Storage)
The GCP Persistent Disk CSI driver is deployed automatically. The script handles:
*   **Namespace Creation:** Creates `gce-pd-csi-driver` (missing in upstream overlays).
*   **Authentication:** Creates a `cloud-sa` secret using the project Service Account key.
*   **Security:** Labels the namespace with `pod-security.kubernetes.io/enforce=privileged` to allow driver access to host paths.

## Storage Verification
To verify that storage provisioning is working correctly:
```bash
./talos-gcp verify-storage
```
- **`verify-storage`**: Smoke test for PVC/PV functionality.
- **`update-traefik`**: Deploys/Upgrades official Traefik Helm Chart (using first external IP).
- **`start` / `stop`**: Suspend/Resume instances.

## Known Issues
(None currently active)

## Destroy
To remove all resources:
```bash
./talos-gcp destroy
```

The script will prompt for confirmation before deleting resources.
