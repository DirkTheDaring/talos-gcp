# Quickstart

**Purpose**: Guide a user to spin up a first successful Talos cluster on GCP and connect to it.  
**Audience**: Users / Application Developers  
**Preconditions**: 
- A GCP project is active and billed.
- `gcloud`, `talosctl`, `jq`, `gsutil`, and `kubectl` are installed.
- You are authenticated (`gcloud auth login` or via Service Account).

---

## Steps

### 1. Initialize Configuration
Export the mandatory environment variables or place them in a `cluster.env` file. By default, the `PROJECT_ID` is inferred from `gcloud config get-value project`.

```bash
# Optional: scope the deployment to a unique name
export CLUSTER_NAME="my-talos-cluster"

# Check your current GCP project setup
gcloud config get-value project
```

### 2. Create the Cluster
Use the `talos-gcp` CLI to provision the entire stack. This handles VPCs, Bastions, Internal Load Balancers, and Talos VMs natively.

```bash
./talos-gcp create
```

**What happens?**
- GCP infrastructural resources are created.
- A hardened Bastion host is launched.
- A `secrets.yaml` is generated and backed up to GCP Storage (`gs://${PROJECT_ID}-talos-images/${CLUSTER_NAME}/secrets.yaml`).
- 1 Control Plane and 1 Worker node are deployed (default configuration).
- The cluster bootstraps.

### 3. Get Credentials
Once completed, the script places your configuration files in `_out/${CLUSTER_NAME}/`. You will use the Identity-Aware Proxy (IAP) Bastion tunnel to securely access the hidden cluster API.

```bash
# Verify credentials exist
ls -l _out/${CLUSTER_NAME}/kubeconfig
ls -l _out/${CLUSTER_NAME}/talosconfig

# Export to your active shell
export KUBECONFIG="$(pwd)/_out/${CLUSTER_NAME}/kubeconfig"
export TALOSCONFIG="$(pwd)/_out/${CLUSTER_NAME}/talosconfig"
```

### 4. Open the IAP Tunnel
Because the API (port 6443) is internal-only, you must proxy your local connection through the Bastion host via `gcloud`:

```bash
# This sets up a proxy tunnel. Keep this running in a separate terminal.
./talos-gcp ssh-bastion -- -N -L 6443:10.100.0.9:6443
```
*(Note: `10.100.0.9` is the default Internal Load Balancer IP created for the Control Plane).*

### 5. Verify Successful Boot
In your original terminal, use `kubectl` to confirm cluster health. Since you are tunneling to your local port 6443, you must direct `kubectl` to hit localhost:

```bash
kubectl --server=https://127.0.0.1:6443 get nodes -o wide
```
You should see one control plane and one worker node listed as `Ready`.

### 6. Clean Up
To remove all resources associated with the cluster:

```bash
./talos-gcp destroy
```

---

## Validation
- `kubectl get nodes` returns Node objects.
- `talosctl --nodes <control-plane-internal-ip> version` successfully responds.

## Troubleshooting
- Refer to [Troubleshooting Handbook](troubleshooting.md).

## References
- [Interfaces Reference](../reference/interfaces.md)
- [Configuration Reference](../reference/configuration.md)
