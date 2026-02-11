#!/bin/bash

show_help() {
    cat <<EOF
${BLUE}Talos GCP Deployment Script${NC}
Usage: ${GREEN}./talos-gcp${NC} [OPTIONS] <COMMAND>

${YELLOW}Commands:${NC}
  ${GREEN}create${NC}             Full cluster deployment (Phases 1-5).
  ${GREEN}destroy${NC}            Destroy all cluster resources (Instances, Networking, etc.).
  ${GREEN}apply${NC}              Apply changes to worker count (Scale up/down).
  ${GREEN}stop${NC}               Stop all control plane and worker nodes.
  ${GREEN}public-ip${NC}          Show the Public IP of the Control Plane Load Balancer.
  ${GREEN}recreate-bastion${NC}  Destroy and recreate the Bastion host (e.g. to apply config changes).
  ${GREEN}grant-admin${NC}       Grant 'roles/compute.osAdminLogin' to a user (GCP IAM).
  ${GREEN}list-admins${NC}       List all users with 'roles/compute.osAdminLogin' (Bastion Admins).
  ${GREEN}diagnose${NC}           Run a suite of health checks (APIs, Ports, Routes).
  ${GREEN}status${NC}             Show current cluster status (Node versions, Talos API check).
  ${GREEN}list-clusters${NC}      List all Talos clusters in the project with version info.
  ${GREEN}list-instances${NC}     List instances for the current cluster (Name, Zone, IPs).
  ${GREEN}list-ports${NC}         List public forwarding rules (Load Balancers) and their ports.
  ${GREEN}update-ports${NC}       Update Ingress Ports based on INGRESS_IPV4_CONFIG in cluster.env.
  ${GREEN}ssh [CMD]${NC}          SSH into the Bastion host. Optional: Run a command directly.
  ${GREEN}get-credentials${NC}    Fetch 'kubeconfig' and 'talosconfig' from GCS bucket.
  ${GREEN}update-cilium${NC}      Update Cilium Helm chart and instance labels.
  ${GREEN}update-labels${NC}      Detect runtime versions (Talos/K8s/Cilium) and update Instance Labels.
  ${GREEN}verify-storage${NC}     Run a PVC storage test.

${YELLOW}Options:${NC}
  ${GREEN}-c, --config <FILE>${NC}  Load configuration from a specific file (default: cluster.env).
  ${GREEN}-h, --help${NC}           Show this help message.

${YELLOW}Environment Variables (Overrides):${NC}
  These variables can be set to target specific clusters or regions, overriding the config file.

  ${GREEN}CLUSTER_NAME${NC}       Name of the cluster (default: talos-gcp-cluster).
  ${GREEN}PROJECT_ID${NC}         GCP Project ID.
  ${GREEN}REGION${NC}             GCP Region (e.g., us-central1).
  ${GREEN}ZONE${NC}               GCP Zone (e.g., us-central1-b).
  ${GREEN}CILIUM_VERSION${NC}     Version of Cilium to install/update (default: 1.18.6).

${YELLOW}Examples:${NC}
  # Create a default cluster
  ./talos-gcp create

  # List instances for a specific cluster
  CLUSTER_NAME="test-cluster" ./talos-gcp list-instances

  # Update Cilium on a specific cluster
  CLUSTER_NAME="prod-cluster" ./talos-gcp update-cilium

  # Load a specific config file
  ./talos-gcp -c my-cluster.env status
EOF
    exit 0
    exit 0
}

usage() {
    show_help
}
