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

# RAM budget on this lab only comfortably fits one application at a time
# (see ADR-031) until the host gets more memory, planned for later this
# year. Ask which one to install instead of chaining all three
# unconditionally. cert-manager is cluster infra (like Calico/MetalLB),
# not gated behind this choice -- it's small and every app depends on it
# for TLS (ADR-033).
echo ""
echo "Which application do you want to install?"
echo "  1) Rancher"
echo "  2) ArgoCD"
echo "  3) Observability (kube-prometheus-stack + Loki)"
echo "  4) None -- just the cluster + Gateway API + cert-manager"
read -r -p "Choice [1/2/3/4]: " APP_CHOICE

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
    echo ""
    echo "Skipping application install -- cluster + Gateway API + cert-manager only."
else
    echo "Unknown choice: $APP_CHOICE"
    exit 1
fi
