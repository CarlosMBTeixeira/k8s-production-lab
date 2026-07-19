#!/bin/bash
# ============================================================================
# rancher-tunnel.sh — SSH local-port-forward to the Rancher Gateway.
# ----------------------------------------------------------------------------
# Direct L3 routing from Windows to the Multipass bridge (10.215.138.0/24)
# hits a VM-side return-path wall (see ADR-029) — the fix is an SSH tunnel
# through cp-1 instead, which stays entirely on the WSL2 side of the
# network (no cross-subnet routing needed) and relies on WSL2's default
# localhost-forwarding to reach Windows.
#
# Gateway/rancher and HTTPRoute/rancher have no 'hostname' restriction, so
# there's no SNI/Host-header matching to fight — just open
# https://localhost:<port>/ and accept the self-signed cert warning.
#
# Usage: ./scripts/tunnels/rancher-tunnel.sh
# Leave running; Ctrl+C to close the tunnel.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
KUBECONFIG_LOCAL="${REPO_ROOT}/kubernetes/admin.conf"
LOCAL_PORT=8443

scp -o StrictHostKeyChecking=no cp-1:~/.kube/config "${KUBECONFIG_LOCAL}"
export KUBECONFIG="${KUBECONFIG_LOCAL}"

ADDR="$(kubectl get gateway/rancher -n cattle-system -o jsonpath='{.status.addresses[0].value}')"
if [ -z "${ADDR}" ]; then
    echo "ERROR: Gateway/rancher has no address."
    exit 1
fi

echo "Tunneling localhost:${LOCAL_PORT} -> ${ADDR}:443 via cp-1"
echo "Browse: https://localhost:${LOCAL_PORT}/  (accept the self-signed cert warning)"
echo "Ctrl+C to close."
ssh -L "${LOCAL_PORT}:${ADDR}:443" cp-1 -N
