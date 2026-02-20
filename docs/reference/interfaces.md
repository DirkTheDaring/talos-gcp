# Interfaces & Entry Points

**Purpose**: Formalize every entrypoint and touchpoint of the `talos-gcp` ecosystem.  
**Audience**: Application Developers / Architects  

---

## 1. Command Line Interface (CLI)

The repository provides a single executable: `./talos-gcp`.

### Core Verbs
- `create`: Provisions immutable GCP resources and bootstraps `/boot` nodes.
- `apply`: Reconsiders node scales against existing definitions.
- `destroy`: Reclaims all resources associated with a `CLUSTER_NAME` tagging.
- `status`: Connects to GCP instances and summarizes online nodes and last transition timestamps.

### Operational Verbs
- `update-schedule`: Syncs new `WORK_HOURS_*` parameters to GCP Instance resource policies.
- `diagnose`: Validates IAM mapping, internal API load balancer IP reachability, and subnets.
- `ssh-bastion`: Encapsulates `gcloud compute ssh --tunnel-through-iap`.

## 2. API Surface

### The Kubernetes Control Plane API
* **Endpoint Type**: Internal TCP/UDP Load Balancer (ILB).
* **Location**: Within the `${CLUSTER_NAME}-vpc` subnet.
* **Ports**: `6443`.
* **Access Control**: Exposed solely to the internal subnet ranges. Resolvable remotely only if connected directly into the VPC or proxied via the Bastion Host.

### Internal Workload Entrypoints
* **Ingress Type**: LoadBalancer service managed by the GCP Cloud Controller Manager (via Traefik or raw NodePorts).
* **Ports**: `80` (HTTP), `443` (HTTPS) natively unblocked via firewall configuration inside `talos-gcp`.

### Application Data Flow Diagram
```ascii
+-----------------+           +-----------------------+
|  Public Client  |           |    Internal Admin     |
|    (Internet)   |           |    (Bastion/Proxy)    |
+--------+--------+           +-----------+-----------+
         |                                |
    "Port 80/443"              "Internal ILB Port 6443"
         |                                |
         v                                v
+-------------------------------------------------------------+
|                     Kubernetes Runtime                      |
|                                                             |
|   +-----------------------+     +-----------------------+   |
|   |    Traefik Ingress    |     |   Control Plane API   |   |
|   |      Controller       |     |                       |   |
|   +-----------+-----------+     +-----------------------+   |
|               |                                             |
|       "Service Routing"                                     |
|               |                                             |
|               v                                             |
|   +-----------------------+     +-----------------------+   |
|   | Application Workload  |     |   GCP PD CSI Driver   |   |
|   |                       +---->|                       |   |
|   +-----------------------+     +-----------+-----------+   |
|                                 "Persistent Vol Reqs"       |
+---------------------------------------------|---------------+
                                              |
                                     "Cloud Auth (cloud-sa)"
                                              v
                              +-------------------------------+
                              |       Google Cloud APIs       |
                              | GCP Compute API (Disk Attach) |
                              +-------------------------------+
```

## References
- [Architecture Overview](../architecture/overview.md)
- [Quickstart](../user/quickstart.md)
