# Operations & Maintenance

**Purpose**: Document day-to-day operations and scaling procedures for the Talos cluster.  
**Audience**: Administrators  
**Preconditions**: Access to GCP and Bash environment where `./talos-gcp` CLI is available.

---

## 1. Node Scaling
Scaling worker nodes is an idempotent operation driven by the `WORKER_COUNT` environment variable in conjunction with the `./talos-gcp apply` command.

### Steps to Scale Workers
1. Export the desired total node counts.
   ```bash
   export WORKER_COUNT=5
   ```
2. Apply changes. To disable interactive confirmation, pass the `--yes` flag.
   ```bash
   ./talos-gcp apply --yes
   ```
**Validation**: Running `kubectl get nodes` will reflect the new cluster size once provisioning and bootstrapping conclude.

## 2. Work Hours Scheduling (Suspend & Resume)
To save cloud costs, the cluster can be bound to GCP Instance Schedules, putting nodes into SUSPENDED state outside working hours.

### Enabling the Schedule
1. Put scheduling variables in your cluster config (or export them):
   ```bash
   export WORK_HOURS_START="08:00"
   export WORK_HOURS_STOP="18:00"
   export WORK_HOURS_DAYS="Mon-Fri"
   ```
2. Apply the schedule:
   ```bash
   ./talos-gcp update-schedule
   ```

### Disabling the Schedule
1. Unset the configuration variables:
   ```bash
   unset WORK_HOURS_START WORK_HOURS_STOP
   ```
2. Run `./talos-gcp update-schedule` to remove the GCP Resource Policy from all instances.

## 3. Storage Verification
If deploying workloads requiring Persistent Volumes (PVs), GCP PD CSI Drivers are pre-installed. You can run automated verifications against storage functionality using the diagnostic commands.

```bash
./talos-gcp verify-storage
```

```bash
export CLUSTER_NAME="prod"
./talos-gcp get-credentials
```

## 4. Diagnostics & Reporting
The `talos-gcp` suite includes a comprehensive diagnostic module that validates CCM logs, internal connectivity, IAM bindings, and cluster IPAM. 

```bash
# General diagnostic sweep
./talos-gcp diagnose

# CCM specific network diagnostics
./talos-gcp diagnose-ccm
```

### Ops Telemetry & Diagnostics Diagram
While a centralized enterprise log vault does not currently exist, diagnostics happen natively between instances, local outputs, and limited Prometheus services.

```ascii
+-------------------------------------------------------------+
|                     Diagnostic Tools                        |
|   +-----------------------+     +-----------------------+   |
|   |  talos-gcp diagnose   |     |  talos-gcp orphans    |   |
|   +-----------+-----------+     +-----------+-----------+   |
|               |                             |               |
|          "API Checks"              "Cloud API Queries"      |
|               |                             |               |
|               v                             v               |
+---------------+-----------------------------+---------------+
                |                             |
+-------------------------------------------------------------+
|                     Cluster Operations      |               |
|                                             |               |
|   +-----------------------+     +-----------v-----------+   |
|   |     Control Plane     |     |   GCP Health Checks   |   |
|   |        (6443)         +---->|          (80)         |<--+
|   +-----------^-----------+     +-----------------------+   |
|               |                                             |
|   +-----------------------+     +-----------------------+   |
|   |   Application Logic   |     |     Worker Nodes      |   |
|   |     (Traefik/App)     |     |                       |   |
|   +-----------^-----------+     +-----------------------+   |
|               |                             |               |
|               +-----------+-----------------+               |
|                           |                                 |
|   +-----------------------v-----------------------------+   |
|   |   Cilium CNI (Metrics) & Rook-Ceph (Prometheus)     |   |
|   +-----------------------------------------------------+   |
+-------------------------------------------------------------+
```

## References
- [Interfaces Reference](../reference/interfaces.md)
- [Runbooks](runbooks.md)
