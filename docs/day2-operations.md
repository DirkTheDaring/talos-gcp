# Day 2 Operations

This guide describes how to manage and update a running Talos GCP cluster.

## Updating Configuration

Configuration for the cluster is primarily managed through the `cluster.env` file (or environment variables). You can change settings such as worker counts, machine types, or network firewall rules even after the cluster has been deployed.

### 1. Modify Configuration
Edit your `cluster.env` file to change the desired settings.

**Example: Open WebRTC Ports on Workers**
To open TCP and UDP ports 30000-32767 for WebRTC:

```bash
# In cluster.env
WORKER_OPEN_TCP_PORTS="30000-32767"
WORKER_OPEN_UDP_PORTS="30000-32767"
WORKER_OPEN_SOURCE_RANGES="0.0.0.0/0"
```

**Example: Close Custom Ports**
To verify the ports are closed, simply unset the variables or leave them empty:

```bash
# In cluster.env
WORKER_OPEN_TCP_PORTS=""
WORKER_OPEN_UDP_PORTS=""
```

### 2. Apply Changes
Run the `apply` command to reconcile the state of the cluster with your configuration.

```bash
./talos-gcp apply
```

The script will:
1.  **Validate Dependencies & Config**: Ensure tools are present and config is valid.
2.  **Reconcile Networking**:
    *   Create or update firewall rules (e.g., custom worker ports).
    *   Delete unused rules (e.g., if you removed the port config).
3.  **Reconcile Workers**:
    *   Create new worker instances if `WORKER_COUNT` increased.
    *   Delete (prune) worker instances if `WORKER_COUNT` decreased.

### 3. Verify
Check the status of your cluster:

```bash
./talos-gcp status
```

You can also verify firewall rules directly via `gcloud`:

```bash
gcloud compute firewall-rules list --filter="name~talos-gcp-cluster-worker-custom"
```
