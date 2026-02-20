# Configuration Reference

**Purpose**: Exhaustive dictionary of all supported environment variables controlling the `talos-gcp` cluster deployment.
**Audience**: Administrators / Architects
**Overrides**: These values can be set inline before commands (e.g. `export CLUSTER_NAME="prod" ./talos-gcp apply`), or persistently declared inside `clusters/clustername.env`.

---

## 1. Core Cluster Identity & GCP Settings

| Variable | Default Value / Rule | Description |
| :------- | :----------- | :---------- |
| `CLUSTER_NAME` | `talos-gcp-cluster` | Primary seed string used to name all VPCs, Subnets, VMs, and generated GCP Roles. Must be <20 chars. |
| `PROJECT_ID` | `gcloud config get-value project` | Target GCP Project ID for all resources. Automatically detected if not explicitly set. |
| `REGION` | `us-central1` | GCP region for the deployment. |
| `ZONE`   | `${REGION}-b` | Specific zone within the Region where Instance Groups will operate. |
| `ARCH`   | Auto-detected | CPU architecture (`amd64` or `arm64`). Auto-detected via `uname -m`. |

## 2. Infrastructure Computes (Control Plane & Workers)

| Variable | Default Value / Rule | Description |
| :------- | :----------- | :---------- |
| `CP_COUNT` | `1` | Total number of Control Plane nodes in the underlying API Instance Group. For high availability, set to 3. |
| `CP_MACHINE_TYPE` | `e2-standard-2` | Google Cloud Compute instance type for Control Planes. |
| `CP_DISK_SIZE` | `200GB` | Boot disk volume allocated to API nodes. |
| `NODE_POOLS` | `("worker")` | Array of worker pool names. Used to provision heterogeneous node groups. |
| `WORKER_COUNT` | `1` | Base count of scalable nodes running applications. Modifiable via `./talos-gcp apply`. |
| `WORKER_MACHINE_TYPE` | `e2-standard-2` | Google Cloud Compute instance type for worker workloads. |
| `WORKER_DISK_SIZE`| `200GB` | Boot disk volume allocated to worker endpoints. |

## 3. Platform & Tool Versions

| Variable | Default Value / Rule | Description |
| :------- | :----------- | :---------- |
| `TALOS_VERSION` | `v1.12.4` | Global Talos node version. Determines the `talosctl` CLI and GCP image artifacts fetched. |
| `CP_TALOS_VERSION` | `$TALOS_VERSION` | Override Talos version specifically for Control Plane nodes. |
| `WORKER_TALOS_VERSION` | `$TALOS_VERSION` | Override Talos version specifically for Worker nodes. |
| `KUBECTL_VERSION` | `v1.35.0` | Target `kubectl` execution version downloaded during provisioning. |
| `HELM_VERSION` | `v3.16.2` | Target `helm` version downloaded for cluster deployments. |

## 4. Talos OS Configuration & Extensions

| Variable | Default Value / Rule | Description |
| :------- | :----------- | :---------- |
| `CP_EXTENSIONS` | `(unset)` | Comma-separated list of Sidero Labs system extensions to bake into Control Plane images (e.g. `siderolabs/nvidia-container-toolkit`). |
| `WORKER_EXTENSIONS` | `(unset)` | Comma-separated list of system extensions to bake into Worker images (e.g. `siderolabs/gvisor`). |
| `POOL_EXTENSIONS` | `$WORKER_EXTENSIONS` | Pool-specific extension overrides. |
| `CP_KERNEL_ARGS` | `(unset)` | Comma or space-separated Kernel arguments applied to Control Planes (e.g. `console=ttyS0,115200`). |
| `WORKER_KERNEL_ARGS` | `(unset)` | Kernel arguments applied to Workers. |
| `POOL_KERNEL_ARGS` | `$WORKER_KERNEL_ARGS`| Pool-specific Kernel arguments. |

## 5. Networking Core & Routing

| Variable | Default Value / Rule | Description |
| :------- | :----------- | :---------- |
| `VPC_NAME` | `${CLUSTER_NAME}-vpc` | Name of the primary private network envelope bridging resources. |
| `SUBNET_NAME` | `${CLUSTER_NAME}-subnet` | Primary Subnet component. |
| `SUBNET_RANGE` | `10.100.0.0/20` | CIDR allocated for the nodes and internal load balancers. |
| `POD_CIDR` | `10.200.0.0/14` | Inner-cluster CIDR allocated strictly by the GCP Cloud Controller Manager. |
| `SERVICE_CIDR` | `10.96.0.0/20` | Virtual CIDR representing intra-cluster headless and clustered services. |
| `STORAGE_CIDR` | `(unset)` | Optional second NIC Subnet range dedicated exclusively for storage traffic (e.g. `10.110.0.0/20`). |
| `CP_USE_STORAGE_NETWORK` | `false` | If `true` and a `STORAGE_CIDR` is active, attaches CP nodes to the secondary storage network. |
| `ALLOCATE_NODE_CIDRS`| `true` | Tells the GCP Cloud Controller Manager to authoritative-route Pod ranges using Alias IPs on GCP VMs. |

## 6. Installed Features & Add-ons

| Variable | Default Value / Rule | Description |
| :------- | :----------- | :---------- |
| `INSTALL_CILIUM` | `true` | Installs Cilium CNI automatically after Bootstrap. |
| `CILIUM_VERSION`| `1.18.6`  | Version of the Cilium Helm chart / daemon deployed. |
| `CILIUM_ROUTING_MODE` | `native` | `tunnel` or `native`. Native uses GCP VPC routing, removing VXLAN overhead. |
| `INSTALL_HUBBLE` | `true` | Deploys Cilium Hubble for observability. |
| `INSTALL_CSI` | `true` | Deploys Google Compute Persistent Disk CSI Driver for PVC management. |
| `TRAEFIK_VERSION`| `38.0.2` | Traefik Ingress controller Helm Chart version deployed via `./talos-gcp update-traefik`. |

## 7. Operational Firewalling & Ingress Points

| Variable | Default Value / Rule | Description |
| :------- | :----------- | :---------- |
| `HC_SOURCE_RANGES` | `35.191.0/16, 130...` | Google Cloud Load Balancer probe source IPs allowed to probe the CP and Workers. |
| `WORKER_HC_PORT` | `80` | Port probed by the cloud LB to verify node health. |
| `INGRESS_IP_COUNT` | `1` | Number of Public Static IPs to reserve for Ingress Controllers. |
| `INGRESS_IPV4_CONFIG` | `(unset)` | Overrides automatic public IP allocation (Advanced). |
| `WORKER_OPEN_TCP_PORTS` | `(unset)` | Allows specific external TCP ports through GCP firewall to worker nodes (e.g. `30000-32767`). |
| `WORKER_OPEN_UDP_PORTS` | `(unset)` | Allows specific external UDP ports through GCP firewall to worker nodes. |
| `WORKER_OPEN_SOURCE_RANGES`| `0.0.0.0/0` | Associated source ranges for the open TCP/UDP worker ports. |

## 8. Rook / Ceph Storage Layer

| Variable | Default Value / Rule | Description |
| :------- | :----------- | :---------- |
| `ROOK_ENABLE` | `false` | Instructs the deployment to attempt Rook-Ceph operator initialization. |
| `ROOK_DEPLOY_MODE` | `helm` | `operator` (legacy dynamic installation) or `helm` (declarative static charts). |
| `ROOK_CHART_VERSION` | `v1.18.9` | Target version for the Rook Helm charts. |
| `ROOK_MDS_CPU` / `MEMORY` | `3` / `4Gi` | CPU and Memory reservations for Metadata Servers (Production Default). |
| `ROOK_OSD_CPU` / `MEMORY` | `1` / `2Gi` | CPU and Memory reservations per OSD block device. |
| `ROOK_EXTERNAL_CLUSTER_NAME`| `(unset)` | Target cluster name for fetching external Ceph tokens (Cross-cluster mode). |

## 9. Global Labels & Scheduling Optimizer

| Variable | Default Value / Rule | Description |
| :------- | :----------- | :---------- |
| `LABELS` | `(unset)` | Comma-separated key=value GCP tags applied to all nodes/resources. |
| `WORK_HOURS_START` | `(unset)` | 24h format (e.g. `08:00`) triggering GCP to exit suspend mode. |
| `WORK_HOURS_STOP`  | `(unset)` | 24h format (e.g. `18:00`) triggering GCP to suspend nodes for cost savings. |
| `WORK_HOURS_DAYS`  | `Mon-Fri` | Days of week the Work Hours window is active. (e.g. `1-5`, `Mon-Sat`). |
| `WORK_HOURS_TIMEZONE` | Auto-detected | Timezone applied to the schedule (e.g. `Europe/Berlin`). Resolves automatically from GCP Region. |

## 10. Multi-Cluster Peering & Identity (Advanced)

| Variable | Default Value / Rule | Description |
| :------- | :----------- | :---------- |
| `PEER_WITH` | `()` (Empty Array)| Array of other `CLUSTER_NAME`s to automatically VPC-Peer with. |
| `SA_NAME` | `${CLUSTER_NAME}-${HASH}-sa`| Explicit override for the Service Account name. If unset, it generates a resilient suffix hash to prevent collision. |
| `CP_SERVICE_ACCOUNT` | `$SA_NAME` | Override Service Account exclusively for Control Planes. |
| `WORKER_SERVICE_ACCOUNT`| `$SA_NAME` | Override Service Account exclusively for workers. |

## References
- [Installation Guide](../admin/installation.md)
- [Interfaces Reference](interfaces.md)
