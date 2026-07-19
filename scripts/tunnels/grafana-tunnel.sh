#!/bin/bash
# ============================================================================
# grafana-tunnel.sh — SSH local-port-forward to the Grafana Gateway.
# Same pattern as rancher-tunnel.sh/argocd-tunnel.sh (ADR-029/030/031).
# Local port 8445 (8443 Rancher, 8444 ArgoCD already taken).
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
KUBECONFIG_LOCAL="${REPO_ROOT}/kubernetes/admin.conf"
LOCAL_PORT=8445
scp -o StrictHostKeyChecking=no cp-1:~/.kube/config "${KUBECONFIG_LOCAL}"
export KUBECONFIG="${KUBECONFIG_LOCAL}"
ADDR="$(kubectl get gateway/grafana -n monitoring -o jsonpath='{.status.addresses[0].value}')"
if [ -z "${ADDR}" ]; then
    echo "ERROR: Gateway/grafana has no address."
    exit 1
fi
echo "Tunneling localhost:${LOCAL_PORT} -> ${ADDR}:443 via cp-1"
echo "Browse: https://localhost:${LOCAL_PORT}/  (accept the self-signed cert warning)"
echo "Ctrl+C to close."
ssh -L "${LOCAL_PORT}:${ADDR}:443" cp-1 -N
