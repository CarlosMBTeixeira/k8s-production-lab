#!/bin/bash
# ============================================================================
# kiali-tunnel.sh — SSH local-port-forward to the Kiali Gateway (Envoy
# Gateway, class eg). Same pattern as grafana-tunnel.sh (ADR-029, ADR-038).
# Local port 8446 (8443 Rancher, 8444 ArgoCD, 8445 Grafana).
# Login token: kubectl -n istio-system create token kiali-login --duration 8h
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
KUBECONFIG_LOCAL="${REPO_ROOT}/kubernetes/admin.conf"
LOCAL_PORT="${LOCAL_PORT:-8446}"
scp -q -o StrictHostKeyChecking=no cp-1:~/.kube/config "${KUBECONFIG_LOCAL}"
export KUBECONFIG="${KUBECONFIG_LOCAL}"
ADDR="$(kubectl get gateway/kiali -n istio-system -o jsonpath='{.status.addresses[0].value}')"
if [ -z "${ADDR}" ]; then
    echo "ERROR: Gateway/kiali has no address."
    exit 1
fi
echo "Tunneling localhost:${LOCAL_PORT} -> ${ADDR}:443 via cp-1"
echo "Browse: https://localhost:${LOCAL_PORT}/  (accept the self-signed cert warning)"
echo "Token:  kubectl -n istio-system create token kiali-login --duration 8h"
echo "Ctrl+C to close."
ssh -L "${LOCAL_PORT}:${ADDR}:443" cp-1 -N
