# System Architecture & Design Decisions

This document outlines the key architectural decisions and configurations for the Talos on GCP deployment, specifically focusing on networking and storage patterns that are unique to this environment.

## Networking

### Control Plane High Availability (Internal Load Balancer)

The cluster uses a Google Cloud **Internal TCP/UDP Load Balancer (L4 ILB)** to distribute traffic to the Control Plane nodes (Kubernetes API).

**Key Characteristics:**
-   **Type:** L4 Pass-through (No proxying).
-   **Traffic Flow:** The Load Balancer forwards packets to the backend instances *without* changing the Destination IP. 
-   **Destination IP:** Packets arrive at the Control Plane node with the Destination IP set to the **Load Balancer's Internal IP** (e.g., `10.100.0.9`), *not* the node's own Internal IP (e.g., `10.100.0.15`).

### IP Aliasing (The `dummy0` Interface)

**Why is this necessary?**
By default, a Linux kernel (and thus Talos) drops packets destined for an IP address that is not configured on any of its local interfaces. Since the ILB passes traffic with the LB's IP as the destination, the Control Plane nodes would normally reject these packets, causing Health Checks and API requests to fail.

**The Solution:**
We configure an "IP Alias" on each Control Plane node.
1.  **Interface:** We create a dummy interface named `dummy0`.
2.  **Address:** We assign the Load Balancer's IP (`10.100.0.9/32`) to this interface.

**Result:**
When a packet arrives destined for `10.100.0.9`, the kernel sees that `10.100.0.9` is a local address (on `dummy0`) and accepts the packet. The Kubernetes API Server, binding to `0.0.0.0` or `::`, then processes the request.

**Implementation Details:**
This configuration is applied via the `controlplane.yaml` machine configuration text patch in `talos-gcp`:

```yaml
machine:
  network:
    interfaces:
      - interface: dummy0
        addresses:
          - 10.100.0.9/32  # The ILB IP
```

---

## Storage Architecture

### CSI Driver (GCP Persistent Disk)

Stateful workloads use the **GCP Compute Persistent Disk CSI Driver**. 

**Why is it configured this way?**
Talos Linux is immutable and has a read-only file system. Standard CSI installation methods often attempt to write to host paths (like `/etc/kubernetes` or `/var/lib/kubelet`) that are either read-only or structured differently in Talos.

**Customizations:**
1.  **Privileged Access:** The CSI driver requires access to the host's `/dev` and `/sys` directories to attach and mount disks. We enforce a `privileged` Pod Security Standard on the `gce-pd-csi-driver` namespace to allow this.
2.  **Service Account:** The driver authenticates to the GCP API using a Kubernetes Secret (`cloud-sa`) containing the Google Service Account JSON key. This Service Account must have `roles/compute.instanceAdmin.v1` and `roles/iam.serviceAccountUser` to attach disks to the nodes.
3.  **Udev Patch (`/etc/udev`, `/lib/udev`, `/run/udev`)**:
    *   **The Conflict**: The official Google CSI driver DaemonSet attempts to mount host paths `/etc/udev` and `/lib/udev` to manipulate udev rules for device attachment. It also mounts `/run/udev` for socket access.
    *   **Talos Constraint**: Talos Linux is an immutable operating system. Directories like `/etc` and `/lib` are read-only (SquashFS). Additionally, Talos manages device nodes differently and does not expose a standard `udev` socket in `/run/udev`.
    *   **The Fix**: A custom Python patch script runs during deployment to **remove these specific volumes and volumeMounts** from the CSI driver manifest.
    *   **Why it works**: Talos's kernel and udev implementation automatically handle the attachment and recognition of GCP Persistent Disks. The CSI driver functions correctly without these mounts in the Talos environment, whereas leaving them in causes Pod failures due to "Read-only file system" errors.

## IP Address Management (IPAM) policy

### Single Source of Truth: Google Cloud
To ensure native routing works reliably, we enforce a strict **Single Source of Truth** policy for IP Address Management.

**The Decision:**
- **Authority:** Google Cloud Platform (GCP) is the sole authority for PodCIDR allocation.
- **Mechanism:** The GCP Cloud Controller Manager (CCM) allocates PodCIDRs to nodes and updates the Node resource.
- **Restriction:** The Kubernetes Controller Manager (KCM) is strictly **forbidden** from allocating PodCIDRs (`--allocate-node-cidrs=false`).

**Why? (Split-Brain Routing Prevention)**
If both KCM and CCM attempt to allocate PodCIDRs, they often disagree. KCM might assign `10.244.0.0/24` while GCP assigns `10.244.1.0/24` via Alias IPs. This creates a "Split-Brain" state where:
1.  **Kubernetes thinks:** Node A has `10.244.0.0/24`.
2.  **The Network (GCP VPC) routes:** `10.244.1.0/24` to Node A.
3.  **Result:** Traffic is blackholed.

By disabling KCM allocation, we force Kubernetes to accept whatever IP range the Cloud Provider (GCP) has assigned to the VM's network interface as an Alias IP.
