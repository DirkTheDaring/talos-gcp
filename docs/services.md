# How to Expose Services on Talos (GCP)

This guide provides practical steps to expose your applications to the public internet using the deployed infrastructure.

## Option 1: Standard Kubernetes LoadBalancer (Recommended)
This method uses the **GCP Cloud Controller Manager (CCM)** to automatically provision a Google Cloud Load Balancer for your service.

1.  **Define your Service**:
    ```yaml
    apiVersion: v1
    kind: Service
    metadata:
      name: my-app
    spec:
      type: LoadBalancer  # Trigger CCM
      selector:
        app: my-app
      ports:
        - port: 80
          targetPort: 8080
    ```

2.  **Apply**: `kubectl apply -f service.yaml`
3.  **Wait**: Watch `kubectl get svc my-app -w`. It will take 1-2 minutes for `EXTERNAL-IP` to populate.
4.  **Result**: A new GCP Forwarding Rule will be created specifically for this service.

## Option 2: Reuse Script-Created Load Balancer (Cost Saving)
The `talos-gcp` script creates a default TCP Load Balancer pointing to port 80 on all worker nodes.

1.  **Use NodePort / HostPort**:
    Ensure your Ingress Controller (e.g., Traefik) listens on the node's port 80.
    ```yaml
    # Traefik configuration (example)
    ports:
      web:
        hostPort: 80
    ```

2.  **Verify Backend Health**:
    The GCP Load Balancer health check expects a response on port 80 (or the configured HC port).
    Ensure your application or Ingress Controller responds to health checks.

3.  **Connect**:
    Use the Public IP output by the deployment script:
    `./talos-gcp status`

## Option 3: Official Traefik Helm Chart (LoadBalancer)

You can install the official Traefik Helm Chart using the `update-traefik` command. This method uses the **First External IP** allocated by `apply-ingress` as a static `loadBalancerIP` for the Service.

```bash
./talos-gcp update-traefik
```

### Features
*   **Official Helm Chart**: Uses `traefik/traefik`.
*   **Static IP Binding**: Automatically binds to `${CLUSTER_NAME}-ingress-v4-0`.
*   **Conflict Resolution**: Automatically deletes manual Forwarding Rules created by `apply-ingress` on that IP to allow the Cloud Controller Manager (CCM) to take over.
*   **Customization**: You can provide a `traefik-values.yaml` file in the project root to override default settings (e.g. enable Dashboard, Middleware).

### Important: The Handoff
When you run `update-traefik`, it takes ownership of the IP alias `ingress-v4-0`.
**To prevent conflicts, you should remove ports 80 and 443 from `INGRESS_IPV4_CONFIG` in `cluster.env`.**

If you don't, running `apply-ingress` later will recreate the conflicting manual forwarding rules, breaking the CCM-managed LoadBalancer.

### Usage
1.  Run `apply-ingress` to ensure IPs are allocated and Firewall rules exist.
2.  Run `update-traefik` to install Traefik and bind it to the first IP.
3.  Update `cluster.env` to remove 80/443 from the first group.

