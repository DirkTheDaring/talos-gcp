# Environment Variable Configuration

This document lists all environment variables that can be used to configure `talos-gcp`. These can be set in your shell environment or provided via a configuration file (`-c config.env`).

## Cluster Identity

| Variable | Default (or Derived From) | Description |
| :--- | :--- | :--- |
| `CLUSTER_NAME` | `talos-gcp-cluster` | The unique name for the cluster. Used as a prefix for all GCP resources (instances, networks, buckets). |
| `PROJECT_ID` | `gcloud config get-value project` | The GCP Project ID where resources will be deployed. Must be set if `gcloud` default is not configured. |
| `REGION` | `us-central1` | The GCP Region for deployment. |
| `ZONE` | `${REGION}-b` | The GCP Zone for instances. Defaults to zone 'b' of the configured region. |
| `BUCKET_NAME` | `${PROJECT_ID}-talos-images` | The GCS bucket name for storing Talos images and secrets. |

## Compute Configuration

| Variable | Default (or Derived From) | Description |
| :--- | :--- | :--- |
| `DEFAULT_MACHINE_TYPE` | `e2-standard-2` | The fallback machine type for all nodes if specific types are not set. |
| `DEFAULT_DISK_SIZE` | `200GB` | The fallback boot disk size for all nodes if specific sizes are not set. |
| `CP_MACHINE_TYPE` | `${MACHINE_TYPE:-$DEFAULT_MACHINE_TYPE}` | Machine type for Control Plane nodes. Use this to override CP size specifically. |
| `WORKER_MACHINE_TYPE` | `${MACHINE_TYPE:-$DEFAULT_MACHINE_TYPE}` | Machine type for Worker nodes. |
| `CP_DISK_SIZE` | `${DEFAULT_DISK_SIZE}` | Boot disk size for Control Plane nodes. |
| `WORKER_DISK_SIZE` | `${DEFAULT_DISK_SIZE}` | Boot disk size for Worker nodes. |
| `CP_COUNT` | `3` | Number of Control Plane nodes to deploy. |
| `WORKER_COUNT` | `1` | Initial number of Worker nodes to deploy. |
| `WORKER_ADDITIONAL_DISKS` | (Empty) | Space-separated list of additional disks to attach to worker nodes. Format: `type:size[:device-name]` (e.g., `pd-ssd:100GB:fast-data`). Device name is optional and defaults to `disk-N`. |

## Mixed Role Versions & Extensions (Advanced)

| Variable | Default (or Derived From) | Description |
| :--- | :--- | :--- |
| `CP_TALOS_VERSION` | `${TALOS_VERSION}` | Specific Talos version for Control Plane. |
| `WORKER_TALOS_VERSION` | `${TALOS_VERSION}` | Specific Talos version for Workers. |
| `CP_EXTENSIONS` | (Empty) | Comma-separated list of system extensions for Control Plane (e.g., `siderolabs/gvisor`). |
| `WORKER_EXTENSIONS` | (Empty) | Comma-separated list of system extensions for Workers. |

## Networking Configuration

| Variable | Default (or Derived From) | Description |
| :--- | :--- | :--- |
| `VPC_NAME` | `${CLUSTER_NAME}-vpc` | Name of the VPC network. In previous versions this defaulted to `talos-vpc`, now it is scoped to `CLUSTER_NAME`. |
| `SUBNET_NAME` | `${CLUSTER_NAME}-subnet` | Name of the subnet. |
| `SUBNET_RANGE` | `10.0.0.0/24` | The CIDR range for the subnet. Ensure this does not overlap if peering VPCs. |
- **`INGRESS_IPV4_CONFIG`** (Default: `""`)
    -   Defines ports to manually forward from the GCP Load Balancer to all worker nodes (e.g., `"80,443"`).
    -   **WARNING**: Leave empty if using `update-traefik` or any Cloud Controller Manager (CCM) `LoadBalancer` service. Setting creating manual rules for ports 80/443 will CONFLICT with the CCM.
    -   **Use Case**: Only set this if running an Ingress Controller via **DaemonSet with `hostPort: 80`** and you need a raw GCP L4 LB pointing to it.
| `INGRESS_IPV6_CONFIG` | (Empty) | Semicolon-separated list of port groups for IPv6 Ingress (Experimental). |

## Talos & Kubernetes Versions

| Variable | Default (or Derived From) | Description |
| :--- | :--- | :--- |
| `TALOS_VERSION` | `v1.12.3` | The version of Talos Linux to install. Used to fetch the `talosctl` binary and image. |
| `KUBECTL_VERSION` | `v1.35.0` | The version of `kubectl` to install on the Bastion host. |
| `ARCH` | `amd64` | Architecture for the images (`amd64` or `arm64`). |

## Other Configuration

| Variable | Default (or Derived From) | Description |
| :--- | :--- | :--- |
| `BASTION_IMAGE_FAMILY` | `ubuntu-2404-lts-amd64` | Image family for the Bastion host. |
| `BASTION_IMAGE_PROJECT` | `ubuntu-os-cloud` | GCP Project for the Bastion image. |
| `LABELS` | `managed-by=talos-script,environment=dev` | Comma-separated key=value pairs for GCP Labels applied to instances. Version labels (`talos-version`, `k8s-version`) are automatically appended. |
| `CLOUDSDK_CORE_DISABLE_PROMPTS`| `1` | Disables interactive prompts from `gcloud`. Set automatically by the script but can be overridden. |

## Cilium Configuration

| Variable | Default (or Derived From) | Description |
| :--- | :--- | :--- |
| `INSTALL_CILIUM` | `true` | Set to `true` to enable Cilium CNI installation (replacing Flannel). Default is enabled. |
| `INSTALL_HUBBLE` | `true` | Set to `true` to enable Hubble (Observability). Requires `INSTALL_CILIUM=true`. Default is enabled. |
| `HUBBLE_FQDN` | `hubble.example.com` | The fully qualified domain name for the Hubble UI Ingress. Used when Cilium is enabled. |

## Configuration File Usage

You can save these variables in a file (e.g., `production.env`) and load them using the `-c` flag:

```bash
./talos-gcp -c production.env create
```

**Note:** Variables in the configuration file take precedence over default values but can still be overridden by exporting environment variables *before* running the script (provided the config file uses `${VAR:-value}` syntax, otherwise the config file values win). In this script, the config file is sourced *after* initial parsing, so it effectively sets the values for the run.
