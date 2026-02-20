# Talos on GCP Deployment

Welcome to the **Talos on GCP** deployment documentation. This repository provides an automated, immutable Kubernetes cluster on Google Cloud using Talos Linux, an Internal Load Balancer, and Google IAP (Identity-Aware Proxy) for secure access.

## Architecture Snapshot

```ascii
+----------------------------------------------------------------------------------------------------+
| GCP Project (talos-vpc / 10.100.0.0/20)                                                              |
|                                                                                                    |
|   +-----------------+           +-----------------------+            +---------------------+       |
|   |  Bastion Host   |           |     Control Plane     |            |     Worker Nodes    |       |
|   | (talos-bastion) |---------->| (talos-controlplane*) |----------->|   (talos-worker*)   |       |
|   |  [Internal IP]  |           |     [Internal IP]     |            |    [Internal IP]    |       |
|   +--------^--------+           +-----------^-----------+            +----------|----------+       |
|            |                                |api (6443)                         |                  |
|       (IAP Tunnel)                          |                                   v                  |
|            ^                              (ILB)                            (Cloud NAT)             |
|            |                                ^                                   |                  |
|  +---------+---------+          +-----------+-----------+                       v                  |
|  |   Admin User      |          |   Internal LoadBalancer |                  (Internet)            |
|  | (gcloud ssh ...)  |          |      (Internal IP)      |                                        |
|  +-------------------+          +-----------------------+                                          |
+----------------------------------------------------------------------------------------------------+
```

## Who are you?

Choose the path that best matches your role:

### 1. [User (Developer / Operator)](user/quickstart.md)
You want to get a cluster running immediately and interact with the Kubernetes API.
- [Quickstart](user/quickstart.md): Spin up and tear down a cluster.
- [Troubleshooting](user/troubleshooting.md): Resolve common connection or deployment issues.

### 2. Administrator
You manage the infrastructure, node lifecycles, and cluster access.
- [Installation Guide](admin/installation.md): Deep-dive into dependencies and setup.
- [Operations & Maintenance](admin/operations.md): Manage node scaling, upgrades, and lifecycle scheduling.
- [Runbooks](admin/runbooks.md): Step-by-step procedures for common operational tasks (e.g. restoring access, recreating bastions).

### 3. Reviewer (Security & Feature Audit)
You need to verify capabilities, compliance, and features.
- [Feature Map](reviewer/features.md): Explore what the cluster provides out of the box.
- [Verification Guide](reviewer/verification.md): How to test and prove the features work correctly.

### 4. Architect
You want to understand the system design, network topography, and technical decisions.
- [Architecture Overview](architecture/overview.md): System context, components, and data flow diagrams.
- [Architecture Decision Records (ADRs)](architecture/decisions/README.md): Historical log of technical decisions.

## Quick References

- [Configuration Reference](reference/configuration.md): All supported environment variables.
- [Interfaces Reference](reference/interfaces.md): API / CLI surface overview.
- [Glossary](reference/glossary.md): Terminology used across these docs.
- [Contributing to Documentation](CONTRIBUTING_DOCS.md): Guidelines to keep our docs fresh and drift-free.
