# Architecture Overview

**Purpose**: High-level map of the cluster architecture and internal network design.  
**Audience**: Architects / Senior Engineers  

---

## 1. System Boundary and Context
The Talos GCP Deployment isolates a fully functional Kubernetes cluster entirely inside a Google Virtual Private Cloud (VPC). Users cannot hit the Kubernetes API or node SSH points from the public internet.

```ascii
+----------------------------------------------------------------------------------------------------+
| GCP Project (talos-vpc / 10.100.0.0/20)                                                              |
|                                                                                                    |
|   +-----------------+           +-----------------------+            +---------------------+       |
|   |  Bastion Host   |           |     Control Plane     |            |     Worker Nodes    |       |
|   | (talos-bastion) |---------->| (talos-controlplane*) |----------->|   (talos-worker*)   |       |
|   |  [Internal IP]  |           |     [Internal IP]     |            |    [Internal IP]    |       |
|   +--------^--------+           +-----------^-----------+            +----------|----------+       |
|            |                                |api (6443)                         |                  |
|       (IAP Tunnel)                          |                                   v                  |
|            ^                              (ILB)                            (Cloud NAT)             |
|            |                                ^                                   |                  |
|  +---------+---------+          +-----------+-----------+                       v                  |
|  |   Admin User      |          |   Internal LoadBalancer |                  (Internet)            |
|  | (gcloud ssh ...)  |          |      (Internal IP)      |                                        |
|  +-------------------+          +-----------------------+                                          |
+----------------------------------------------------------------------------------------------------+
```

## 2. Component and Service Modules
The script (`talos-gcp`) wraps Talos's native API and `gcloud` commands to create a deterministic deployment.

```ascii
+-----------------------+
|    talos-gcp CLI      |
+----+----+----------+--+
     |    |          |
     |    |          | Reads
     |    |          v
     |    |   +------+----------------+
     |    |   | Cluster Config (.env) |
     |    |   +-----------------------+
     |    |
     |    | Provisions
     |    v 
     |  +-------------------------+      Creates      +-------------------------+
     |  |     GCP Compute API     |------------------>|      VM Instances       |
     |  +-------------------------+                   +------------+------------+
     |                                                             ^
     | Bootstraps                                                  |
     v                                                             | Controls
+-------------------------+                                        |
|      Talos OS API       |----------------------------------------+
+-------------------------+
```

## 3. Deployment Topography
Deployment mimics a standard high-availability control plane but relies heavily on Google's L4 pass-through internal load balancing combined with Alias IPs.

```ascii
+----------------------------------------------------------------------------------------------------+
|  GCP us-central1 (default region)                                                                  |
|                                                                                                    |
|  +----------------------------------------------------------------------------------+              |
|  |  VPC: ${CLUSTER_NAME}-vpc                                                        |              |
|  |                                                                                  |              |
|  |  +-----------------------+                  +-----------------------+            |              |
|  |  |   Cloud NAT (Egress)  |                  | Subnet: 10.100.0.0/20 |            |              |
|  |  +-----------------------+                  +-----------+-----------+            |              |
|  |                                                         |                        |              |
|  |  +---------------------------------------------------+  |  +------------------+  |              |
|  |  | Control Plane Instance Group                      |  |  | Worker IG        |  |  +--------+  |
|  |  |                                                   |  +->|                  |  |  | Cloud  |  |
|  |  |  [ talos-cp-1 (dummy0 IP: 10.100.0.9) ] <------+  |  |  | [talos-worker-1] |  |  | Storage|  |
|  |  |                                                |  |  |  |                  |  |  | (GCS)  |  |
|  |  |  [ talos-cp-2 (dummy0 IP: 10.100.0.9) ] <---+  |  |  |  | [talos-worker-2] |  |  +--------+  |
|  |  +---------------------------------------------|--|--+  |  +------------------+  |              |
|  |                                                |  |     |                        |              |
|  |               +-----------------------+        |  |     |                        |              |
|  |               |  Internal LB (ILB)    |--------+  |     |                        |              |
|  |               |   IP: 10.100.0.9      |-----------+     |                        |              |
|  |               +-----------------------+                 |                        |              |
|  +---------------------------------------------------------+                        |              |
+-------------------------------------------------------------------------------------+
```

### IPAM Allocation Split-Brain Prevention
GCP Cloud Controller Manager (CCM) strictly manages PodCIDR allocation via `--allocate-node-cidrs=true`. This bridges IP alias secondary ranges on VMs with Kubernetes.

## 4. Initialization Workflow
The central job flow occurs when an admin issues `./talos-gcp create`.

```ascii
 Admin        talos-gcp        Google Cloud         talosctl
   |              |                  |                 |
(1)|-- create --->|                  |                 |
   |              |(2) source config |                 |
   |              |---(3) provision VPC/Subnet/NAT---->|
   |              |---(4) provision Bastion VM-------->|
   |              |                  |                 |
   |              |-------(5) Generate configs ------->|
   |              |                  |                 |
   |              |---(6) Upload secrets to GCS ------>|
   |              |---(7) Provision CP Instance Group->|
   |              |---(8) Provision Worker Nodes ----->|
   |              |                  |                 |
   |              |----------(9) bootstrap ----------->|
   |              |<-------(10) bootstrap success -----|
   |              |-------(11) Fetch kubeconfig ------>|
   |<-- Ready! ---|                  |                 |
```

## References
- [Architecture Decision Records](decisions/README.md)
