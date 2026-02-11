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
| `WORKER_ADDITIONAL_DISKS` | Additional Disks (type:size:device) | *(Empty)* |
| `TALOS_VERSION` | Talos Version (e.g., v1.8.0) | *(Latest Valid)* |
| `CP_TALOS_VERSION` | Control Plane Talos Version | `$TALOS_VERSION` |
| `WORKER_EXTENSIONS` | Worker Extensions (e.g. gvisor) | *(Empty)* |

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
export WORKER_COUNT=5
./talos-gcp apply
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
You can explicitly set the number of workers in your config (e.g., `WORKER_COUNT=5`) and run `apply`:

```bash
# Update config or env var
export WORKER_COUNT=5

# Apply changes (Prompts for confirmation if deleting nodes)
./talos-gcp apply

# Non-interactive mode (Auto-confirm)
./talos-gcp apply --yes
```

The `apply` command is **idempotent**: it creates missing nodes and removes extra nodes to match `WORKER_COUNT`.

## Secure Access (Identity-Aware Bastion)

The cluster uses a hardened **Identity-Aware Bastion** for secure access.

*   **Authentication**: Uses Google Identity (OS Login) + MFA. No static SSH keys.
*   **Authorization**: Admin vs User roles.
    *   **Admins**: Full shell access. Requires `roles/compute.osAdminLogin` (Auto-granted to deployer).
    *   **Users**: Restricted to Port Forwarding only (No Shell). Requires `roles/iap.tunnelResourceAccessor` + `roles/compute.osLogin`.

### User Management (Pure IAM)
Access is managed entirely via Google Cloud IAM. No manual user creation is needed on the Bastion.

1.  **Restricted Access (Port Forwarding Only)**:
    Grant the user `roles/compute.osLogin`.
    *   They can tunnel to the API/Internal LB.
    *   They **cannot** get a shell on the Bastion (`nologin`).

2.  **Admin Access (Full Shell)**:
    Grant the user `roles/compute.osAdminLogin`.
    *   They get a full shell (`/bin/bash`) and `sudo` rights.
    *   *Note*: When switching roles, you may need to recreate the bastion to force a permission sync if it doesn't happen automatically.

To revoke access (remove from group):
```bash
./talos-gcp bastion-remove-user <google-email-username>
```

### Bastion Maintenance
To recreate the bastion (e.g., to apply new security configs or fix issues):
```bash
./talos-gcp recreate-bastion
```

### Admin Management
To grant a user full shell access (Admin):
```bash
./talos-gcp grant-admin <email@example.com>
```

To list current Admins:
```bash
./talos-gcp list-admins
```

### Connecting
Users connect via a single `gcloud` command that tunnels through IAP:
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
