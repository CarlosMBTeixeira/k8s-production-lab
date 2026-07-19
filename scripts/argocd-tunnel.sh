#!/bin/bash
# ============================================================================
# argocd-tunnel.sh — SSH local-port-forward to the ArgoCD Gateway.
# Same pattern as rancher-tunnel.sh (ADR-029/030). Local port 8444, so it
# can run alongside the Rancher tunnel (8443) without colliding.
# ----------------------------------------------------------------------------
# CLI login through this tunnel: argocd login localhost:8444 --insecure --grpc-web
# (--grpc-web is the standard workaround for the ArgoCD CLI behind a
# generic reverse proxy rather than a passthrough/GRPCRoute setup.)
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
KUBECONFIG_LOCAL="${REPO_ROOT}/kubernetes/admin.conf"
LOCAL_PORT=8444

scp -o StrictHostKeyChecking=no cp-1:~/.kube/config "${KUBECONFIG_LOCAL}"
export KUBECONFIG="${KUBECONFIG_LOCAL}"

ADDR="$(kubectl get gateway/argocd -n argocd -o jsonpath='{.status.addresses[0].value}')"
if [ -z "${ADDR}" ]; then
    echo "ERROR: Gateway/argocd has no address."
    exit 1
fi

echo "Tunneling localhost:${LOCAL_PORT} -> ${ADDR}:443 via cp-1"
echo "Browse: https://localhost:${LOCAL_PORT}/  (accept the self-signed cert warning)"
echo "CLI:    argocd login localhost:${LOCAL_PORT} --insecure --grpc-web"
echo "Ctrl+C to close."
ssh -L "${LOCAL_PORT}:${ADDR}:443" cp-1 -N
