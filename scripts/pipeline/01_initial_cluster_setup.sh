#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

section() {
    echo
    echo "============================================================"
    echo "  $1"
    echo "============================================================"
}

launch_machines() {
    section "| Step 1/7: Launching VMs"
    bash scripts/lab-management.sh build
    ansible all -m ping
}

configure_the_four_nodes() {
    section "| Step 2/7: Configuring nodes (site.yml)"
    ansible-playbook ansible/site.yml
}

deploy_kube_vip() {
    section "| Step 3/7: Deploying kube-vip (VIP for control plane)"
    ansible-playbook ansible/playbooks/08-kube-vip.yml
}

bootstrap_control_plane_1() {
    section "| Step 4/7: Bootstrapping K8s control plane (kubeadm init)"
    ansible-playbook ansible/playbooks/09-kubeadm-init.yml
}

install_cni() {
    section "| Step 5/7: Installing Calico CNI"
    ansible-playbook ansible/playbooks/10-cni-calico.yml
}

join_second_control_plane() {
    section "| Step 6/7: Joining cp-2 as second control plane"
    ansible-playbook ansible/playbooks/11-controlplane-join.yml
}

check_final_state() {
    section "| Step 7/7: Final cluster state"
    ssh cp-1 "kubectl get nodes -o wide"
    echo
    ssh cp-1 "kubectl get pods -A"
}

launch_machines
configure_the_four_nodes
deploy_kube_vip
bootstrap_control_plane_1
install_cni
join_second_control_plane
check_final_state

echo
echo "============================================================"
echo "  Pipeline complete. HA control plane (cp-1 + cp-2) Ready."
echo "============================================================"
