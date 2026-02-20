# Verification Guide

**Purpose**: Provide methods to prove that the features listed in the Feature Map work as intended.  
**Audience**: Reviewers / Security Auditors / QA  
**Preconditions**: Target cluster is fully provisioned and `kubeconfig` is active.

---

## Validating Security Roles (IAM)
The cluster removes traditional ssh-keys. GCP OS Login is strictly enforced.

**Steps**:
1. Without `roles/compute.osAdminLogin`, attempt to gain a pure shell into the Bastion:
   ```bash
   # Should fail
   gcloud compute ssh ${CLUSTER_NAME}-bastion --tunnel-through-iap
   ```
2. Verify you can only port-forward if granted `roles/compute.osLogin`:
   ```bash
   gcloud compute ssh ${CLUSTER_NAME}-bastion --tunnel-through-iap -- -N -L 6443:10.100.0.9:6443
   ```

## Validating Persistent Storage (CSI)
GCP Compute Persistent Disk CSI Driver is utilized.
**Steps**:
1. Run the native diagnostic command:
   ```bash
   ./talos-gcp verify-storage
   ```
This will spin up a pod requesting a PersistentVolumeClaim, confirm it bounds, writes data, and exits.

## Validating Load Balancing & Ingress
Because Talos configures a pass-through Internal Load Balancer, we verify API connectivity correctly routes.
**Steps**:
1. Ensure the ILB is pingable locally from the Bastion.
   ```bash
   ./talos-gcp ssh-bastion -- curl -k https://10.100.0.9:6443/version
   ```
2. If `update-traefik` was run, identify the external IP of Traefik.
   ```bash
   kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
   ```
   Hit this IP externally on port 80 to verify it returns a HTTP 404 (default Traefik response for unmatched routes).

## Validating Automated Subnets
Multi-cluster isolation relies on dedicated VPCs.
**Steps**:
1. Open Google Cloud Console or run:
   ```bash
   gcloud compute networks list | grep ${CLUSTER_NAME}
   ```
2. Confirm the exact internal subnet mapping matches the defined `/20` blocks per isolated `CLUSTER_NAME`.

## References
- [Feature Map](features.md)
