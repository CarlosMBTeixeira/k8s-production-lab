#!/bin/bash
# ============================================================================
# alloy-tunnel.sh — SSH local-port-forward to Grafana Alloy's UI.
# ----------------------------------------------------------------------------
# Alloy (ADR-032, replacing Promtail) exposes a component graph on :12345.
# It is the single most useful page for debugging log collection: it shows
# each component's health, how many targets discovery matched, and what
# loki.write is actually sending — i.e. it answers "why are there no logs
# from namespace X?" without reading any config.
#
# Alloy is a DaemonSet, so the Service load-balances across one pod per
# node. Logs from a given pod are collected by the Alloy instance on the
# SAME node, so a per-node view matters: set POD to pin the tunnel to one
# instance instead of taking whichever the Service picks.
#
#   kubectl get pods -n monitoring -l app.kubernetes.io/name=alloy -o wide
#   POD=alloy-xxxxx ./scripts/tunnels/alloy-tunnel.sh
#
# Usage:   ./scripts/tunnels/alloy-tunnel.sh
#          POD=alloy-mkh5v ./scripts/tunnels/alloy-tunnel.sh
#          LOCAL_PORT=12999 ./scripts/tunnels/alloy-tunnel.sh
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
KUBECONFIG_LOCAL="${REPO_ROOT}/kubernetes/admin.conf"

NAMESPACE="monitoring"
SERVICE="alloy"
REMOTE_PORT=12345
LOCAL_PORT="${LOCAL_PORT:-12345}"

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

if [ -n "${POD:-}" ]; then
    # Pod IPs are routable from the node for the same reason ClusterIPs
    # are — Calico programs them into the host's routing table.
    ADDR="$(kubectl get pod "${POD}" -n "${NAMESPACE}" -o jsonpath='{.status.podIP}' 2>/dev/null || true)"
    TARGET="pod ${POD} on $(kubectl get pod "${POD}" -n "${NAMESPACE}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo '?')"
else
    ADDR="$(kubectl get svc "${SERVICE}" -n "${NAMESPACE}" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
    TARGET="service ${SERVICE} (whichever pod it picks — set POD= to pin one)"
fi

if [ -z "${ADDR}" ] || [ "${ADDR}" = "None" ]; then
    echo "ERROR: no address for ${TARGET} in ${NAMESPACE}."
    echo "Is the observability stack installed? (main.sh choice 3 or 4)"
    exit 1
fi

echo "Tunneling localhost:${LOCAL_PORT} -> ${ADDR}:${REMOTE_PORT} — ${TARGET} — via cp-1"
echo "Browse:  http://localhost:${LOCAL_PORT}/graph"
echo "  discovery.kubernetes.pods  — how many targets were matched"
echo "  discovery.relabel.pods     — the labels being attached (the Loki schema)"
echo "  loki.write.default         — whether writes are actually landing"
echo "Ctrl+C to close. (Typing here echoes raw — ssh -N holds the terminal"
echo "and reads nothing, so arrow keys show as ^[[A. Harmless.)"
ssh -L "${LOCAL_PORT}:${ADDR}:${REMOTE_PORT}" cp-1 -N
