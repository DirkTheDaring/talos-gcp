# Feature Map

**Purpose**: Enumerate user-visible features and capabilities derived from code out-of-the-box.  
**Audience**: Reviewers / Security Auditors  

---

### Identity-Aware Bastion
- **Where implemented**: `lib/bastion.sh`
- **Description**: Secure access proxy utilizing GCP Identity-Aware Proxy (IAP). Prevents exposing SSH to the public internet. Relies strictly on Google IAM (`roles/compute.osAdminLogin`, `roles/compute.osLogin`).
- **How to verify**: Attempt `ssh admin@bastion-ip` without IAP; it should timeout. Test `gcloud compute ssh --tunnel-through-iap` for success.

### Scheduled Suspend/Resume
- **Where implemented**: `lib/schedule.sh`
- **Description**: Cost savings by actively shutting down (Suspended State) VM instances during off-hours. Controlled via `WORK_HOURS_START`, `WORK_HOURS_STOP`, and `WORK_HOURS_DAYS`.
- **How to verify**: Run `./talos-gcp update-schedule`. Inspect the VM schedules attached to the instances in the Google Cloud Console.

### IP Alias Native Routing
- **Where implemented**: `lib/controlplane.sh`
- **Description**: Uses dummy network interfaces (`dummy0`) to catch Internal Load Balancer traffic, avoiding proxy layers completely.
- **How to verify**: `kubectl get nodes -o wide` and trace requests hitting the API via the `10.100.0.9` internal LB IP. 

### Immutable Infrastructure Bootstrapping
- **Where implemented**: `talos-gcp`, `lib/config.sh`
- **Description**: Nodes are provisioned with Talos Linux (immutable read-only OS). Setup occurs through declarative manifests.
- **How to verify**: Attempt to SSH into a Worker or Control Plane. It will fail. Use `talosctl dmesg` to verify OS integrity.

### Multi-Cluster Isolation
- **Where implemented**: Native `CLUSTER_NAME` tagging system across `lib/`.
- **Description**: The ability to deploy completely isolated clusters in the same GCP project. Each has distinct VPCs, Subnets, Routers, NATs, and GCP Storage buckets.
- **How to verify**: `export CLUSTER_NAME=cluster-b`, run `./talos-gcp create`, and use `./talos-gcp list-clusters` to visualize VPC bounds.

### Out-of-the-box Ingress (Traefik) + CNI (Cilium)
- **Where implemented**: `lib/traefik.sh`, `lib/cni.sh`
- **Description**: Cilium manages BPF networking, and Traefik serves public L7 traffic.
- **How to verify**: Run `./talos-gcp update-traefik`. Check Traefik external IP via `kubectl -n traefik get svc`.

## References
- [Verification Guide](verification.md)
