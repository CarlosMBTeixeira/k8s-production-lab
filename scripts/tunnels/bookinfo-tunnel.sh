#!/bin/bash
# ============================================================================
# bookinfo-tunnel.sh — SSH local-port-forward to Bookinfo's Istio ingress
# Gateway (class istio, deployed by istiod as bookinfo-gateway-istio).
# Plain HTTP on :80 -- this is the mesh's front door, not a lab UI (ADR-038).
# Local port 8447.
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
KUBECONFIG_LOCAL="${REPO_ROOT}/kubernetes/admin.conf"
LOCAL_PORT="${LOCAL_PORT:-8447}"
scp -q -o StrictHostKeyChecking=no cp-1:~/.kube/config "${KUBECONFIG_LOCAL}"
export KUBECONFIG="${KUBECONFIG_LOCAL}"
ADDR="$(kubectl get gateway/bookinfo-gateway -n bookinfo -o jsonpath='{.status.addresses[0].value}')"
if [ -z "${ADDR}" ]; then
    echo "ERROR: Gateway/bookinfo-gateway has no address."
    exit 1
fi
echo "Tunneling localhost:${LOCAL_PORT} -> ${ADDR}:80 via cp-1"
echo "Browse: http://localhost:${LOCAL_PORT}/productpage"
echo "Ctrl+C to close."
ssh -L "${LOCAL_PORT}:${ADDR}:80" cp-1 -N
