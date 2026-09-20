#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Node topology is a variable, not a branch difference (ADR-036). Ask here,
# once, before anything is built -- lab-management.sh and every later script
# inherit the answer through the exported LAB_WORKERS and .lab-topology.
# Set LAB_WORKERS in the environment to skip the prompt entirely:
#   LAB_WORKERS=2 bash scripts/pipeline/main.sh
source "${SCRIPT_DIR}/../lab-config.sh"
lab_choose_topology
LAB_WORKER_COUNT="$(lab_workers)"

source "${SCRIPT_DIR}/01_initial_cluster_setup.sh"
source "${SCRIPT_DIR}/02_kubeadm_join.sh"
source "${SCRIPT_DIR}/03_gateway_api_metallb.sh"
source "${SCRIPT_DIR}/04_cert_manager.sh"

echo ""
echo "==========================================================================="
echo "| Installation complete: cluster + Gateway API + cert-manager."
echo "==========================================================================="

# Whether ArgoCD and the observability stack can coexist depends on the
# topology chosen above (ADR-035, ADR-036). Both stacks together are
# ~3.5Gi; that fits reliably in one 8G worker and unreliably across two
# 4G ones, because the scheduler cannot split a pod across nodes.
#
# cert-manager is cluster infra (like Calico/MetalLB), not gated behind
# this choice -- it's small and every app depends on it for TLS (ADR-033).
if [ "${LAB_WORKER_COUNT}" -eq 1 ]; then
    COMBO_NOTE="the GitOps/observability study stack -- recommended on this topology"
else
    COMBO_NOTE="NOT recommended on ${LAB_WORKER_COUNT} workers -- expect Pending/OOMKilled"
fi

echo ""
echo "Application to install    [topology: $(lab_topology_line)]"
echo "  1) Rancher                     (alone -- heaviest of the three)"
echo "  2) ArgoCD"
echo "  3) Observability               (kube-prometheus-stack + Loki + Alloy)"
echo "  4) ArgoCD + Observability      (${COMBO_NOTE})"
echo "  5) Network Policies            (monitoring namespace, requires Observability already installed)"
echo "  6) None -- just the cluster + Gateway API + cert-manager"
read -r -p "Choice [1/2/3/4/5/6]: " APP_CHOICE

if [ "$APP_CHOICE" = "1" ]; then
    source "${SCRIPT_DIR}/05_rancher.sh"
    echo ""
    echo "==========================================================================="
    echo "| Installation complete: Rancher."
    echo "| Run ./scripts/tunnels/rancher-tunnel.sh to access Rancher in the browser."
    echo "==========================================================================="
elif [ "$APP_CHOICE" = "2" ]; then
    source "${SCRIPT_DIR}/06_argocd.sh"
    echo ""
    echo "==========================================================================="
    echo "| Installation complete: ArgoCD."
    echo "| Run ./scripts/tunnels/argocd-tunnel.sh to access ArgoCD in the browser."
    echo "==========================================================================="
elif [ "$APP_CHOICE" = "3" ]; then
    source "${SCRIPT_DIR}/07_observability.sh"
    echo ""
    echo "==========================================================================="
    echo "| Installation complete: Observability (Prometheus/Grafana/Loki)."
    echo "| Run ./scripts/tunnels/grafana-tunnel.sh to access Grafana in the browser."
    echo "==========================================================================="
elif [ "$APP_CHOICE" = "4" ]; then
    # Guard, not a block: two 4G workers can technically hold both stacks,
    # it just stops being reliable. Make the operator say so out loud
    # rather than discovering it as an OOMKill mid-exercise.
    if [ "${LAB_WORKER_COUNT}" -ne 1 ]; then
        echo ""
        echo "  WARNING: ${LAB_WORKER_COUNT} workers x $(lab_worker_memory). ArgoCD + the observability"
        echo "  stack total ~3.5Gi and need that memory in ONE schedulable node."
        echo "  Rebuild with LAB_WORKERS=1 for the workbook (ADR-035)."
        read -r -p "  Continue anyway? [y/N]: " COMBO_CONFIRM
        [ "${COMBO_CONFIRM}" = "y" ] || [ "${COMBO_CONFIRM}" = "Y" ] || { echo "Aborted."; exit 1; }
    fi
    # Order matters: ArgoCD first, so that the observability stack can
    # later be handed over to it as an Application (study topic 3)
    # without reinstalling anything. Each script is self-contained --
    # both fetch their own kubeconfig (ADR-024) and both prompt for
    # their own admin password, so expect two password prompts.
    source "${SCRIPT_DIR}/06_argocd.sh"
    source "${SCRIPT_DIR}/07_observability.sh"
    echo ""
    echo "==========================================================================="
    echo "| Installation complete: ArgoCD + Observability."
    echo "| ArgoCD:  ./scripts/tunnels/argocd-tunnel.sh   -> https://localhost:8444/"
    echo "| Grafana: ./scripts/tunnels/grafana-tunnel.sh  -> https://localhost:8445/"
    echo "| Check headroom with:"
    echo "|   kubectl describe node -l '!node-role.kubernetes.io/control-plane' \\"
    echo "|     | grep -A6 'Allocated resources'"
    echo "==========================================================================="
elif [ "$APP_CHOICE" = "5" ]; then
    source "${SCRIPT_DIR}/08_network_policies.sh"
    echo ""
    echo "==========================================================================="
    echo "| Installation complete: Network Policies (monitoring)."
    echo "==========================================================================="
elif [ "$APP_CHOICE" = "6" ]; then
    echo ""
    echo "Skipping application install -- cluster + Gateway API + cert-manager only."
else
    echo "Unknown choice: $APP_CHOICE"
    exit 1
fi
