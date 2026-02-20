# Troubleshooting

**Purpose**: Assist users in identifying and resolving common errors they might encounter.  
**Audience**: Users / Application Developers  
**Preconditions**:  You have attempted to run `./talos-gcp` commands or connect to an existing cluster.

---

## Known Issues and Resolutions

### Error: `dial tcp 127.0.0.1:6443: connect: connection refused`
**Symptom**: `kubectl` or `talosctl` commands fail to connect to the cluster.
**Cause**: The IAP tunnel proxy to the Bastion host is either not running, or closed unexpectedly.
**Steps**:
1. Check if the ssh Bastion tunnel is running in the background.
2. Restart the tunnel in a separate terminal:
   ```bash
   ./talos-gcp ssh-bastion -- -N -L 6443:10.100.0.9:6443
   ```
3. Ensure you have the `roles/iap.tunnelResourceAccessor` IAM permission.

### Error: Nodes stuck in `NotReady` or missing PodCIDRs
**Symptom**: Nodes never go to `Ready` via `kubectl get nodes`. Network pods might be crash looping.
**Cause**: The GCP Cloud Controller Manager (CCM) failed to assign PodCIDRs.
**Steps**:
1. Run `./talos-gcp diagnose-ccm` to check CCM logs.
2. Confirm that `ALLOCATE_NODE_CIDRS` was `true` during cluster creation.
3. Validate that the service account (`cloud-sa`) has correct GCP permissions (`roles/compute.networkUser` / `viewer`).

### Error: Cannot ssh into Bastion (Permission Denied)
**Symptom**: `./talos-gcp ssh` hangs or states "Permission Denied (publickey)".
**Cause**: Missing Google OS Login roles.
**Steps**:
1. You must be assigned `roles/compute.osAdminLogin` (for full shell) or `roles/compute.osLogin` (for proxy only). 
2. Ask your Administrator to run:
   ```bash
   ./talos-gcp grant-admin <your-email>
   ```

### Error: `Orphaned Resources Detected`
**Symptom**: Re-creating the cluster fails or indicates existing networking components.
**Cause**: A previous `./talos-gcp destroy` command failed midway or was cancelled.
**Steps**:
1. Detect left-overs: `./talos-gcp orphans`
2. Clean them aggressively: `./talos-gcp orphans clean`

---

## How to get help
If none of this works, you can run a general diagnostic check which checks IAM rules and cluster states:
```bash
./talos-gcp diagnose
```
Include output from this command when requesting assistance from the infrastructure team.
