# Networking & Service Exposure on GCP with Talos

This document explains the networking constraints of Google Cloud Platform (GCP) and how to correctly expose Kubernetes Services in your Talos cluster.

## 1. The L2 Announcement Constraint
**Important:** Cilium L2 Announcements (ARP/GARP) **do not work** for Public IPs on GCP.

### Why?
GCP Virtual Private Clouds (VPCs) are Software Defined Networks (SDN). They operate at Layer 3 (IP routing) and do not simulate a traditional Layer 2 Ethernet broadcast domain.
*   **ARP is ignored**: Broadcasts for "Who has IP X?" are not propagated to the edge routers/internet gateway.
*   **Routing is Explicit**: Traffic is delivered to an instance only if a specific GCP API resource (Forwarding Rule, Route, or Alias IP) maps that IP to the instance.

**Do not attempt** to use `CiliumL2AnnouncementPolicy` to "claim" a Public IP on GCP. It will fail silently (traffic will never arrive).

## 2. Recommended Strategy: LoadBalancer (CCM)
The standard and most robust way to expose a service is to let the **GCP Cloud Controller Manager (CCM)** handle it.

### Usage
```yaml
apiVersion: v1
kind: Service
metadata:
  name: traefik
  namespace: kube-system
spec:
  type: LoadBalancer
  loadBalancerIP: 35.x.x.x  # Optional: Request specific static IP
  ports:
    - port: 80
      targetPort: 80
```

### How it works
1.  Kubernetes requests a LoadBalancer.
2.  CCM detects the request.
3.  CCM calls the GCP API to create:
    *   **Forwarding Rule**: The Public IP.
    *   **Target Pool** (or Backend Service): The list of Nodes.
    *   **Firewall Rules**: Allow traffic to the nodes.

## 3. Alternative Strategy: NodePort + Managed LB
If you want to save costs or reuse the Load Balancer created by the deployment script.

### Usage
1.  Configure your Service as `type: NodePort`.
2.  Ensure your DaemonSet/Deployment binds to a known HostPort (e.g., 80) OR relies on the NodePort (e.g., 32080).
3.  **Manual Step**: Update the GCP Backend Service (created by the script) to check the correct port on the nodes.

*Note: The `talos-gcp` script sets up a basic TCP Proxy Load Balancer pointing to port 80 on Workers. If Traefik listens on HostPort 80, this works out-of-the-box.*

## 4. Control Plane Networking: VIP & KubePrism
This deployment utilizes a split-horizon networking strategy to handle Control Plane traffic correctly within GCP's constraints.

### The Architecture
1.  **VIP (Virtual IP)**: An Internal TCP Load Balancer (`10.0.0.2` by default) provides a single stable endpoint for the Kubernetes API Server.
2.  **KubePrism**: A local load balancer running on `localhost:7445` on every node.

### Why do we need `vip-alias`?
GCP Internal Load Balancers (ILB) have a limitation where backend instances cannot access the Load Balancer IP itself (Hairpinning).
*   **Worker Nodes**: They are *not* backends for the Control Plane ILB. They access the VIP (`10.0.0.2`) standardly via the GCP SDN. Traffic flows: `Worker -> GCP Network -> Control Plane Node`.
*   **Control Plane Nodes**: They *are* backends. If `cp-0` tries to talk to `10.0.0.2`, the packet would loop back to itself, which the network stack often drops.
*   **The Fix**: A DaemonSet (`vip-alias`) runs **only on Control Plane nodes**. It assigns `10.0.0.2` to a local dummy interface (`dummy0`). This forces traffic to stay local (loopback), bypassing the network hair-pin issue.

### Why `dummy0` instead of `lo`?
If we attach the VIP to the main Loopback interface (`lo`), the Kubelet or Cloud Controller Manager might incorrectly detect this IP (`10.0.0.2`) as the Node's primary address. This causes GCP validation failures because `10.0.0.2` belongs to a forwarding rule, not an instance. Using `dummy0` keeps the route local but deprioritizes it for node registration.

## 5. Troubleshooting: Split-Brain Routing (Connectivity Failure)

**Symptom:**
- Pods on one node cannot reach Pods/Services on another node.
- `kubectl debug` connectivity tests fail with `i/o timeout`.
- `curl` to `kubernetes.default.svc` fails with timeout.

**Root Cause:**
This occurs when the Kubernetes Controller Manager (KCM) and the GCP Cloud Controller Manager (CCM) **disagree** on the PodCIDR allocated to a node.
1.  **GCP (CCM):** Assigns an Alias IP (e.g., `172.20.14.0/24`) to the node's network interface.
2.  **Kubernetes (KCM):** Assigns a *different* PodCIDR (e.g., `172.20.7.0/24`) to the Node spec because it's configured to allocate CIDRs independently.
3.  **Conflict:**
    - The Node thinks it owns `172.20.7.0/24`. CNI (Cilium) configures routes for this range.
    - The VPC Network thinks the node owns `172.20.14.0/24` and routes traffic for that range to it.
    - **Result:** Traffic for `172.20.7.x` is dropped by the VPC because it doesn't match the Alias IP. Traffic for `172.20.14.x` arrives but has no local routes on the node.

**The Fix:**
We utilize the **Single Source of Truth** pattern:
1.  **Disable KCM Allocation:** We set `--allocate-node-cidrs=false` on the `kube-controller-manager`.
2.  **Enable CCM Allocation:** The `gcp-cloud-controller-manager` is configured to allocate CIDRs and sync them to the Node spec.
3.  **Verify:** The startup script now runs `verify_gcp_alignment` to confirm that `kubectl get node <node> -o jsonpath='{.spec.podCIDR}'` matches `gcloud compute instances describe <node> ... aliasIpRanges`.

**Manual Recovery:**
If this state occurs (e.g., after a misconfiguration), you must manually align the Alias IPs to match Kubernetes:
```bash
# 1. Get the PodCIDR K8s thinks the node has
CIDR=$(kubectl get node <node> -o jsonpath='{.spec.podCIDR}')

# 2. Force GCP to match
gcloud compute instances network-interfaces update <node> \
    --zone <zone> \
    --aliases "pods:${CIDR}"
```
