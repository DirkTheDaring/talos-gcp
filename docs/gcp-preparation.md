# Prerequisites: Configuring GCP

Before running the script, you must prepare your Google Cloud environment.

## 1. Create a Project
1.  Go to the **[New Project Page](https://console.cloud.google.com/projectcreate)** in the Google Cloud Console.
2.  Enter a **Project Name** (e.g., `talos-k8s`).
3.  **Crucial**: Look below the project name field. You will see an **Project ID** (e.g., `talos-k8s-123456`).
    *   *Note this ID down!* You will need it for the script.
    *   You can edit it now, but not later.
4.  Click **Create**.
5.  Wait a moment, then verify your project is selected in the top bar or via the **[Dashboard](https://console.cloud.google.com/home/dashboard)**.

## 2. Enable Billing
1.  Go to **[Billing](https://console.cloud.google.com/billing)**.
2.  Select your new project.
3.  Click **Link a billing account** and follow the prompts.
    *   *Without billing, the deployment will fail immediately.*

## 3. Enable APIs (Optional - Script does this)
The script attempts to enable APIs automatically. If you prefer to do it manually:
1.  Go to **[APIs & Services > Library](https://console.cloud.google.com/apis/library)**.
2.  Enable: `compute.googleapis.com`, `iam.googleapis.com`, `cloudresourcemanager.googleapis.com`.

## 4. Check Quotas
New GCP projects often have low default quotas (e.g., 24 vCPUs globally, but sometimes 0 in specific regions).

1.  Go to **IAM & Admin > Quotas**.
2.  Filter by:
    *   **Metric**: `CPUS` (Compute Engine API)
    *   **Location**: `us-central1` (or your chosen region)
3.  Ensure you have at least **10 vCPUs** available.
    *   *Usage*: 1 Control Plane + 1 Worker + 1 Bastion = 3 VMs * 2 vCPU = 6 vCPU (leaving room for expansion).
4.  If not, select the quota and click **Edit Quotas** to request an increase.

## 5. Permissions
The script creates a custom Service Account and assigns it roles. This requires **Project IAM Admin** permissions.

Ensure your user account has:
*   **Option A (Recommended for Personal Projects)**: `Owner` role.
*   **Option B (Least Privilege)**: `Editor` **AND** `resourcemanager.projectIamAdmin` (Project IAM Admin).

> [!WARNING]
> The `Editor` role alone is **insufficient** because it cannot manage IAM policies.

## 6. GCS Security & IAM
The script creates a GCS bucket to store Talos images and cluster secrets. This bucket is **hardened by default**:
1.  **Uniform Bucket-Level Access**: Enabled. ACLs are disabled. Access is controlled strictly via IAM.
2.  **Public Access Prevention**: Enforced. No public access is possible.

**Consequences:**
*   You must rely on IAM roles for access.
*   The script runner needs `roles/storage.admin` (to create the bucket) or `roles/storage.objectAdmin` (to read/write objects).
*   The `Owner` role includes these permissions.
*   If you use a custom Service Account, ensure it has `roles/storage.objectAdmin` on the bucket.
Install the Google Cloud SDK and authenticate:

```bash
# Login to GCP
gcloud auth login

# Set your project
gcloud config set project YOUR_PROJECT_ID

# Authenticate Application Default Credentials (optional but recommended)
gcloud auth application-default login
```
