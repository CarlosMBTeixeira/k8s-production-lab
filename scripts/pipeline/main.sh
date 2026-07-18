#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/01_initial_cluster_setup.sh"
source "${SCRIPT_DIR}/02_kubeadm_join.sh"
source "${SCRIPT_DIR}/03_gateway_api_metallb.sh"
source "${SCRIPT_DIR}/04_rancher.sh"

echo ""
echo "===================================================================="
echo "| Pipeline complete: cluster + Gateway API + Rancher."
echo "| Run ./scripts/rancher-tunnel.sh to access Rancher in the browser."
echo "===================================================================="
