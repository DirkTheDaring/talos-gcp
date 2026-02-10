# Accessing the Cluster

The Talos nodes are provisioned in a **Private Subnet** with **NO Public IP addresses**. To ensure security, all access flows through the **Bastion Host** using Google Cloud IAP (Identity-Aware Proxy).

## 1. Quick Access (Interactive)

The script pre-installs `talosctl` and `kubectl` on the Bastion host. This is the easiest way to manage the cluster.

```bash
### 1. Identify Resources
First, export your cluster variables (or check `cluster.env`):
```bash
export CLUSTER_NAME="talos-gcp-cluster"
export ZONE="us-central1-b"
export PROJECT_ID="<your-project-id>"
```

Find the Bastion instance name:
```bash
BASTION_NAME="${CLUSTER_NAME}-bastion"
echo "Bastion: ${BASTION_NAME}"
```

Find the Control Plane IP (target for API access):
```bash
# We target cp-0 directly for the tunnel
CP_0_IP=$(gcloud compute instances describe "${CLUSTER_NAME}-cp-0" \
    --zone "${ZONE}" \
    --project="${PROJECT_ID}" \
    --format='value(networkInterfaces[0].networkIP)')
echo "Control Plane IP: ${CP_0_IP}"
```

### 2. Quick Access (Interactive SSH)
Log in to the Bastion host to run `talosctl` and `kubectl` directly from there.

```bash
gcloud compute ssh "${BASTION_NAME}" \
    --zone "${ZONE}" \
    --project="${PROJECT_ID}" \
    --tunnel-through-iap
```

### 3. Local Access (Port Forwarding)
To use local tools (`Lens`, `k9s`, local `kubectl`) against the private cluster, open a secure tunnel via the Bastion.

**Command:**
```bash
gcloud compute ssh "${BASTION_NAME}" \
    --zone "${ZONE}" \
    --project="${PROJECT_ID}" \
    --tunnel-through-iap \
    -- -L 6443:${CP_0_IP}:6443 -N -q -f
```

*   `-L 6443:${CP_0_IP}:6443`: Forwards local port 6443 to the Control Plane's port 6443.
*   `-N`: Do not execute a remote command (just forward ports).
*   `-q`: Quiet mode.
*   `-f`: Go to background.

**Verify Connectivity:**
```bash
# Point kubectl to localhost
kubectl --kubeconfig=kubeconfig get nodes
```
