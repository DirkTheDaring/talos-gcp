# Installation Guide

**Purpose**: Provide cluster administrators with comprehensive setup protocols and dependency requirements.  
**Audience**: Administrators  
**Preconditions**: GCP privileges adequate for creating IAM policies, VPCs, Bastions, and GCS buckets.

---

## 1. Prerequisites and Dependencies
Before deploying, confirm you possess the following binaries in your local `PATH`:
- `gcloud`: Google Cloud CLI
- `talosctl`: Talos CLI
- `kubectl`: Kubernetes CLI
- `gsutil`: Google Cloud Storage CLI
- `jq`: JSON processor
- `curl`, `envsubst`

## 2. GCP Project Initialization
You must ensure the compute and networking APIs are active. 
```bash
gcloud services enable compute.googleapis.com
gcloud services enable iam.googleapis.com
gcloud services enable iap.googleapis.com
```

Ensure a billing account is linked to your `PROJECT_ID`.

## 3. Configuration Management Approach
Instead of modifying `lib/config.sh` directly, securely declare your layout using environment files (`.env`). Canonical templates outline all possibilities:
- **`examples/talos.env`**: A clean base template suitable for most starting points.
- **`clusters/rook-ceph.env`**: A reference for storage-heavy deployments.

You can copy these or create your own (e.g. `prod.env`) injected at runtime:
```bash
cp examples/talos.env prod.env
# Example edits inside prod.env:
export CLUSTER_NAME="prod-cluster"
export CP_COUNT=3
export WORKER_COUNT=5
```

Execute initialization:
```bash
./talos-gcp -c prod.env create
```

## 4. Multi-Cluster Isolation
This repository fully supports multi-cluster isolation on the same project bounding resources strictly by the `CLUSTER_NAME` prefix. Each cluster utilizes:
- A unique VPC (`${CLUSTER_NAME}-vpc`).
- A unique State Bucket Subfolder (`gs://${BUCKET_NAME}/${CLUSTER_NAME}/secrets.yaml`).
- Unique IAM Service Accounts.

Ensure you explicitly define `CLUSTER_NAME` for subsequent ops (e.g., `destroy`, `apply`) to target the correct clusters.

---
## Validation
- Execute `./talos-gcp status` to see VM states.
- Execute `./talos-gcp list-instances` to inspect GCP-level active VMs.
- Ensure GCS buckets accurately contain the Talos `secrets.yaml` backups for disaster recovery.

## References
- [Configuration Reference](../reference/configuration.md)
- [Operations Guide](operations.md)
