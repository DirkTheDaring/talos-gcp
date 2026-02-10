# Secure Cluster Access (No SSH Shell)

This guide explains how to access your Talos cluster securely without exposing public IPs or relying on legacy SSH bastion shells.

## Why this approach?

Traditional bastion hosts often require:
1.  **Public IPs**: Increasing the attack surface.
2.  **SSH Key Management**: Rotating keys for multiple users is difficult.
3.  **Port 22 Exposure**: Constant scanning by bots.

Our approach uses Google Cloud's **Identity-Aware Proxy (IAP) TCP Forwarding**.

### Benefits
*   **Zero Public IPs**: Nodes have only private RFC1918 addresses.
*   **IAM Authentication**: Access is granted via Google Cloud IAM roles (`roles/iap.tunnelResourceAccessor`), not SSH keys.
*   **Auditability**: Every connection is logged in Cloud Audit Logs.
*   **No Shell Access**: Users get direct TCP access to the Kubernetes/Talos API, but no shell on the underlying OS, enforcing the principle of least privilege.

---

## How to Connect

You can forward local ports directly to the private Control Plane nodes via IAP.

### 1. Talos Admin Access (talosctl)
The Talos API listens on port `50000`. To manage nodes:

```bash
# 1. Start a background tunnel to the first control plane node
gcloud compute start-iap-tunnel talos-controlplane-0 50000 \
    --local-host-port=localhost:50000 \
    --zone=us-central1-b &

# 2. Run talosctl against localhost
talosctl -n localhost:50000 dashboard
```

### 2. Kubernetes API Access (kubectl)
If you disabled the Public LoadBalancer (or want a private channel), you can tunnel to port `6443`:

```bash
# 1. Start a background tunnel
gcloud compute start-iap-tunnel talos-controlplane-0 6443 \
    --local-host-port=localhost:6443 \
    --zone=us-central1-b &

# 2. Use kubectl with a modified config
# (This sed command temporarily points your config to localhost)
kubectl --kubeconfig=<(sed 's/server: .*/server: https:\/\/localhost:6443/' kubeconfig) get nodes
```

> **Note**: Replace `us-central1-b` with your actual `ZONE`.
