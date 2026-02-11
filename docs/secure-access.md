# Secure Access Guide (Identity-Aware Bastion)

This cluster uses a hardened, Identity-Aware security model (Pure IAM). There are no static SSH keys to share. Access is granted based on your Google Identity (Email) and IAM roles.

## Roles & Permissions

Access is controlled entirely by Google Cloud IAM. No manual user creation on the bastion is required.

### 1. Cluster Admin
**Full Shell Access** to the Bastion + Kubernetes.
*   **IAM Role**: `roles/compute.osAdminLogin`
*   **Capabilities**: Full `sudo` access, interactive shell, port forwarding.
*   **Access Logic**: The bastion checks if you can run `sudo`. If yes, you get a shell.

### 2. Cluster User
**Restricted Access**. Can **ONLY** use **Port Forwarding** (tunneling) to reach the Kubernetes API.
*   **IAM Role**: `roles/compute.osLogin` **AND** `roles/iap.tunnelResourceAccessor`
*   **Capabilities**: Port forwarding (tunneling) only. **Interactive shell is BLOCKED.**
*   **Access Logic**: The bastion checks if you can run `sudo`. If no, your shell is restricted.

---

## Connection Guide

To access the Kubernetes API, you must open a secure tunnel via the bastion.

### Prerequisites
1.  **Google Cloud CLI (`gcloud`)** installed and authenticated (`gcloud auth login`).
2.  **IAM permissions** granted to your Google Account (ask an Admin).

### Step 1: Open the Tunnel

Run the following command. **Note the `-N` flag**—it is crucial for non-admin users.

```bash
# Replace 'dietmar_kling_gmail_com' with your actual OS Login username
# (Run 'gcloud compute os-login describe-profile' to find it)

gcloud compute ssh talos-gcp-cluster-bastion \
    --project=api-project-651935823088 \
    --zone=us-central1-b \
    --tunnel-through-iap \
    -- -N -L 6443:10.0.0.5:6443
```

**Key Flags:**
*   **`-N`**: **REQUIRED for non-admins.** Tells SSH "no remote command". If you omit this, the connection will close immediately because the restricted shell denies interactive sessions.
*   **`-L 6443:10.0.0.5:6443`**: Forwards your local port `6443` to the Cluster's Internal IP `10.0.0.5`.

**Expected Behavior:**
*   The command will appear to **hang/wait**. This is **NORMAL**.
*   It means the tunnel is **OPEN** and listening.
*   **Do not close this terminal window.**

### Step 2: Access Kubernetes

In a separate terminal, point `kubectl` to your local port:

```bash
# Verify connection
kubectl get nodes --server=https://localhost:6443 --insecure-skip-tls-verify
```

---

## SSH Config (Optional Convenience)

For a smoother experience (e.g., just running `ssh k8s-tunnel`), add this to your local `~/.ssh/config`.

**Note:** You must replace `YOUR_USERNAME` with your full OS Login username (e.g., `dietmar_kling_gmail_com`).

```ssh
# Kubernetes API Tunnel
Host k8s-tunnel
    HostName talos-gcp-cluster-bastion
    User YOUR_USERNAME
    # Use gcloud as a proxy wrapper to handle IAP and keys automatically
    ProxyCommand gcloud compute ssh %r@%h --zone=us-central1-b --project=api-project-651935823088 --tunnel-through-iap -- -W %h:%p
    LocalForward 6443 10.0.0.5:6443
    RequestTTY no
    ExitOnForwardFailure yes
```

**Usage:**
1.  **Open Tunnel**: `ssh -N k8s-tunnel` (Keeps terminal open)
2.  **Access**: `kubectl get nodes` (pointed at local port)

---

## Troubleshooting

### "Connection closed by remote host" / "Interactive shell is disabled"
*   **Cause**: You tried to SSH without `-N` (interactive mode), but you are a standard user.
*   **Fix**: Non-admins cannot run commands. You must use `-N` for port forwarding.

### "Permission denied (publickey)"
*   **Cause**: Missing `roles/compute.osLogin` or OS Login keys not synced.
*   **Fix**: Verify your role. Run `gcloud compute os-login describe-profile` to force a local key sync.

### "Connection failed" (IAP)
*   **Cause**: Missing `roles/iap.tunnelResourceAccessor`.
*   **Fix**: Ask an admin to grant the IAP Tunneler role to your account.
