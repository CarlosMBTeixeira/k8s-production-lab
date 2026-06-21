#!/bin/bash
# ===================================================================================
# 01_initial_cluster_setup.sh — One-shot bootstrap of the K8s lab from a clean state.
# -----------------------------------------------------------------------------------
# Runs the full provisioning pipeline in order:
#   1. Launch 4 Multipass VMs via lab-management.sh + health check
#   2. Run site.yml (apt, ansible-user, swap, kernel, containerd, K8s repo)
#   3. kubeadm init on the primary control plane (cp-1)
#   4. Install Calico CNI
#   5. Print final cluster state
#
# Run from anywhere; the script anchors to its own location.
# Fails fast — any step's failure aborts the rest.
# ============================================================================

set -euo pipefail

# Anchor to the repo root regardless of where the script is invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

# ----------------------------------------------------------------------------
# Pretty section header so the operator can follow along in long output.
# ----------------------------------------------------------------------------
section() {
    echo
    echo "============================================================"
    echo "  $1"
    echo "============================================================"
}

# ----------------------------------------------------------------------------
# Step 1: Launch the 4 VMs and confirm Ansible can reach them.
# ----------------------------------------------------------------------------
launch_machines() {
    section "| Step 1/5: Launching VMs"
    bash scripts/lab-management.sh build
    ansible all -m ping
}

# ----------------------------------------------------------------------------
# Step 2: Configure the 4 nodes (8 roles via site.yml).
# ----------------------------------------------------------------------------
configure_the_four_nodes() {
    section "| Step 2/5: Configuring nodes (site.yml)"
    ansible-playbook ansible/site.yml
}

# ----------------------------------------------------------------------------
# Step 3: Bootstrap the K8s control plane on cp-1.
# ----------------------------------------------------------------------------
bootstrap_control_plane_1() {
    section "| Step 3/5: Bootstrapping K8s control plane (kubeadm init)"
    ansible-playbook ansible/playbooks/09-kubeadm-init.yml
}

# ----------------------------------------------------------------------------
# Step 4: Install Calico CNI so the node transitions to Ready.
# ----------------------------------------------------------------------------
install_cni() {
    section "| Step 4/5: Installing Calico CNI"
    ansible-playbook ansible/playbooks/10-cni-calico.yml
}

# ----------------------------------------------------------------------------
# Step 5: Print the final cluster state for the operator to verify.
# ----------------------------------------------------------------------------
check_final_state() {
    section "| Step 5/5: Final cluster state"
    ssh cp-1 "kubectl get nodes -o wide"
    echo
    ssh cp-1 "kubectl get pods -A"
}

# ============================================================================
# Pipeline.
# ============================================================================
launch_machines
configure_the_four_nodes
bootstrap_control_plane_1
install_cni
check_final_state

echo
echo "============================================================"
echo "  Pipeline complete. Cluster Ready in cp-1."
echo "============================================================"
