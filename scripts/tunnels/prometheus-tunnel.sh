#!/bin/bash
# ============================================================================
# prometheus-tunnel.sh — SSH local-port-forward to Prometheus.
# ----------------------------------------------------------------------------
# Unlike rancher/argocd/grafana (ADR-026/029/030/031), Prometheus has no
# Gateway — kube-prometheus-stack leaves it ClusterIP-only, because the
# chart expects you to reach it through Grafana. So this forwards to the
# Service's ClusterIP rather than a Gateway address.
#
# That works because kube-proxy programs ClusterIP routing in the node's
# own network namespace: cp-1 can reach 10.x.y.z:9090 directly, even
# though nothing outside the cluster can. Verified against this lab.
#
# Preferred over `kubectl port-forward` for two reasons: the ClusterIP is
# stable across pod restarts (a port-forward dies with its pod), and it
# matches the pattern every other tunnel script here already uses.
#
# Plain HTTP, not HTTPS — there is no TLS in front of this.
#
# Usage:   ./scripts/tunnels/prometheus-tunnel.sh
#          LOCAL_PORT=9999 ./scripts/tunnels/prometheus-tunnel.sh
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
KUBECONFIG_LOCAL="${REPO_ROOT}/kubernetes/admin.conf"

NAMESPACE="monitoring"
SERVICE="kube-prometheus-stack-prometheus"
REMOTE_PORT=9090
LOCAL_PORT="${LOCAL_PORT:-9090}"

# ----------------------------------------------------------------------------
# Refuse early if the local port is taken, and say by what. ssh's own error
# for this ("channel_setup_fwd_listener_tcpip: cannot listen to port") comes
# AFTER the banner has already printed, which reads like the tunnel worked.
#
# The usual culprit is a previous tunnel: `ssh -L` survives the script that
# started it, so closing the terminal does not always close the forward.
# ----------------------------------------------------------------------------
port_in_use() {
    ss -tln 2>/dev/null | grep -qE "(127\.0\.0\.1|\[::1\]|0\.0\.0\.0|\*):${LOCAL_PORT}[[:space:]]"
}

if port_in_use; then
    echo "ERROR: localhost:${LOCAL_PORT} is already in use."
    ss -tlnp 2>/dev/null | grep -E ":${LOCAL_PORT}[[:space:]]" | sed 's/^/  /'
    echo
    echo "If it is an old tunnel of this kind, close it with:"
    echo "  pkill -f 'ssh -L ${LOCAL_PORT}:'"
    echo "Otherwise pick a different local port:"
    echo "  LOCAL_PORT=<port> ${0}"
    exit 1
fi

# -q: suppress scp's progress meter, which is noise on a 5 KB file.
scp -q -o StrictHostKeyChecking=no cp-1:~/.kube/config "${KUBECONFIG_LOCAL}"
export KUBECONFIG="${KUBECONFIG_LOCAL}"

ADDR="$(kubectl get svc "${SERVICE}" -n "${NAMESPACE}" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
if [ -z "${ADDR}" ] || [ "${ADDR}" = "None" ]; then
    echo "ERROR: service ${SERVICE} in ${NAMESPACE} has no ClusterIP."
    echo "Is the observability stack installed? (main.sh choice 3 or 4)"
    exit 1
fi

echo "Tunneling localhost:${LOCAL_PORT} -> ${ADDR}:${REMOTE_PORT} (${SERVICE}) via cp-1"
echo "Browse:  http://localhost:${LOCAL_PORT}/"
echo "  Targets   http://localhost:${LOCAL_PORT}/targets      — is every ServiceMonitor up?"
echo "  Alerts    http://localhost:${LOCAL_PORT}/alerts       — did the PrometheusRule load?"
echo "  Rules     http://localhost:${LOCAL_PORT}/api/v1/rules — the same, as JSON"
echo "Ctrl+C to close. (Typing here echoes raw — ssh -N holds the terminal"
echo "and reads nothing, so arrow keys show as ^[[A. Harmless.)"
ssh -L "${LOCAL_PORT}:${ADDR}:${REMOTE_PORT}" cp-1 -N
