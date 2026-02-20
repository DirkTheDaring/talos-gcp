# Glossary

**Purpose**: Provide clear definitions for terminology used across our documentation.  
**Audience**: All Audiences  

### A
- **Alias IP**: A Google Cloud networking feature allowing secondary IP ranges to be inherently routed to specific Virtual Machine interfaces without complex internal BGP updates.
- **Architecture Decision Record (ADR)**: A structured historical document capturing the context and intent behind significant system changes.

### B
- **Bastion Host**: A secure proxy machine serving strictly as an access pivot. Admin traffic must flow through it to reach internal hidden networks.

### C
- **CCM (Cloud Controller Manager)**: The abstraction layer bridging Kubernetes routing and LoadBalancer generation against native Google Cloud API implementations.
- **CSI (Container Storage Interface)**: Standardized methodology for mounting Block and File storage inside Kubernetes (here via GCP PD).

### I
- **IAP (Identity-Aware Proxy)**: Google's BeyondCorp utility granting SSH encrypted tunnels into private VMs using OAuth and IAM roles rather than public static keys.
- **Idempotent**: An operation that yields the same result regardless of how many times you run it (e.g. `apply`).
- **ILB (Internal Load Balancer)**: A layer 4 pass-through proxy in GCP that balances cluster API state entirely off the internet.

### T
- **Talos Linux**: An immutable, minimal, and secure operating system designed specifically and exclusively to run Kubernetes.

## References
- [Architecture Overview](../architecture/overview.md)
