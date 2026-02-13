#!/bin/bash
show_help() {
    # Use generic colors if not defined (fallback)
    : "${BLUE:=\e[34m}"
    : "${GREEN:=\e[32m}"
    : "${YELLOW:=\e[33m}"
    : "${NC:=\e[0m}"

    cat <<EOF
${BLUE}Talos GCP Deployment Script${NC}
${BLUE}===========================${NC}

${YELLOW}Usage:${NC} ./talos-gcp [OPTIONS] <COMMAND>

${YELLOW}Options:${NC}
  ${GREEN}-c, --config <file>${NC}     Specify a configuration file (default: cluster.env)
  ${GREEN}-h, --help${NC}              Show this help message

${YELLOW}Commands:${NC}
  ${BLUE}--- Cluster Lifecycle ---${NC}
  ${GREEN}create${NC}                  Create the entire cluster infrastructure (Network, Bastion, CP, Workers)
  ${GREEN}destroy${NC}                 Destroy the entire cluster infrastructure
  ${GREEN}apply${NC}                   Apply configuration changes (e.g. machine type updates, scaling)
  ${GREEN}start${NC}                   Start all cluster instances (Control Plane & Workers)
  ${GREEN}stop${NC}                    Stop all cluster instances (Control Plane & Workers)

  ${BLUE}--- Cluster Management ---${NC}
  ${GREEN}status${NC}                  Check the status of the cluster (Online/Offline)
  ${GREEN}list-clusters${NC}           List all deployed clusters in the project
  ${GREEN}get-credentials${NC}         Fetch 'talosconfig' and 'kubeconfig' for the cluster
  ${GREEN}upgrade${NC}                 (Placeholder) Upgrade Talos version

  ${BLUE}--- Access & Connectivity ---${NC}
  ${GREEN}ssh <node>${NC}              SSH into a specific node (via Bastion)
  ${GREEN}ssh-bastion${NC}             SSH into the Bastion host
  ${GREEN}access-info${NC}             Display connection details (Tunnel ports, Config paths)
  ${GREEN}verify-access <email>${NC}   Verify if a user has necessary IAM roles and API access
  ${GREEN}grant-access <email>${NC}    Grant developer access (IAP, GCS, OS Login) to a user
  ${GREEN}revoke-access <email>${NC}   Revoke developer access from a user
  ${GREEN}grant-admin <email>${NC}     Grant admin access (Instance Admin, Network User, etc.) to a user
  ${GREEN}list-access${NC}             List users with assigned permissions
  ${GREEN}list-admins${NC}             List users with Admin permissions

  ${BLUE}--- Networking ---${NC}
  ${GREEN}public-ip${NC}               Get the Public IP of the Bastion (if applicable)
  ${GREEN}list-ports${NC}              List currently configured worker port ranges
  ${GREEN}update-ports${NC}            Update worker port firewall rules from configuration
  ${GREEN}update-traefik${NC}          Update Traefik load balancer configuration
  
  ${BLUE}--- Debugging & Maintenance ---${NC}
  ${GREEN}diagnose${NC}                Run a suite of diagnostic checks on the cluster
  ${GREEN}verify-connectivity${NC}     Verify internal cluster connectivity (PingMESH)
  ${GREEN}verify-storage${NC}          Verify CSI Driver and Persistent Volume functionality
  ${GREEN}recreate-bastion${NC}        Destroy and recreate the Bastion host
  ${GREEN}update-labels${NC}           Update labels on GCP instances
  ${GREEN}list-instances${NC}          List all GCP instances associated with the cluster
  ${GREEN}orphans${NC}                 List orphan resources (disks/IPs) not attached to the cluster
  ${GREEN}orphans clean${NC}           Cleanup orphan resources
  ${GREEN}update-cilium${NC}           Update Cilium CNI configuration
  ${GREEN}update-schedule${NC}         Update the instance schedule (shutdown/startup times)

${YELLOW}Examples:${NC}
  ./talos-gcp create
  ./talos-gcp destroy
  ./talos-gcp -c clusters/prod.env status
  ./talos-gcp ssh small-cp-0
  ./talos-gcp grant-access user@example.com

EOF
}

usage() {
    show_help
}
