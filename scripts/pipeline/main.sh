#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/01_initial_cluster_setup.sh"
source "${SCRIPT_DIR}/02_kubeadm_join.sh"
source "${SCRIPT_DIR}/03_gateway_api_metallb.sh"
source "${SCRIPT_DIR}/04_cert_manager.sh"

echo ""
echo "==========================================================================="
echo "| Installation complete: cluster + Gateway API + cert-manager."
echo "==========================================================================="

# The RAM budget still doesn't fit everything at once, but since ADR-035
# it does fit ArgoCD *and* the observability stack together: worker-2 was
# removed and its 4G folded into worker-1, so the ~8G of schedulable
# memory sits in one node instead of being split across two. Rancher is
# the one that no longer coexists -- it's the heaviest of the three and
# it isn't what the GitOps/observability study needs.
#
# cert-manager is cluster infra (like Calico/MetalLB), not gated behind
# this choice -- it's small and every app depends on it for TLS (ADR-033).
echo ""
echo "Which application do you want to install?"
echo "  1) Rancher                     (alone -- heaviest of the three)"
echo "  2) ArgoCD"
echo "  3) Observability               (kube-prometheus-stack + Loki + Alloy)"
echo "  4) ArgoCD + Observability      (the GitOps/observability study stack, ADR-035)"
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
    echo "| Both land on worker-1 (the only schedulable node) -- check headroom"
    echo "| with: kubectl describe node worker-1 | grep -A6 'Allocated resources'"
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
