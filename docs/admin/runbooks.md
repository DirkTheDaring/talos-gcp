# Runbooks

**Purpose**: Step-by-step procedures for common operational tasks and emergency break-glass procedures.  
**Audience**: Administrators  
**Preconditions**: Bash environment, GCP authentication.

---

## Runbook: Restoring Bastion Access

**Context**: You are locked out of the cluster API because the Bastion host ssh keys desynced, or the `roles/compute.osAdminLogin` propagation failed.
**Steps**:
1. Grant yourself explicit OS Admin login for the Project.
   ```bash
   ./talos-gcp grant-admin your.email@example.com
   ```
2. Re-create the bastion. This will tear down the current bastion VM and deploy a fresh one with the latest IAM sync.
   ```bash
   ./talos-gcp recreate-bastion
   ```
**Validation**: Run `./talos-gcp ssh-bastion` and confirm you get a shell.

---

## Runbook: Recovering Lost Credentials

**Context**: A developer lost their local `kubeconfig` or `talosconfig`, but the cluster is still active and healthy.
**Steps**:
1. Run the `get-credentials` command. The CLI will fetch `secrets.yaml` from the `gs://${BUCKET_NAME}/${CLUSTER_NAME}` bucket, regenerate the configs, and place them in the local output directory.
   ```bash
   export CLUSTER_NAME="prod"
   ./talos-gcp get-credentials
   ```
**Validation**: Check `./_out/prod/kubeconfig` exists and is valid.

---

## Runbook: Cleaning Orphaned Resources

**Context**: A deployment or deletion panicked midway, leaving lingering GCP Instances, Firewalls, or static IPs costing money.
**Steps**:
1. Detect left-overs without mutating anything.
   ```bash
   ./talos-gcp orphans
   ```
2. Clean detected orphans forcefully.
   ```bash
   ./talos-gcp orphans clean
   ```

## References
- [Operations & Maintenance](operations.md)
