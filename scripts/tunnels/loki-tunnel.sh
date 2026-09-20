#!/bin/bash
# ============================================================================
# loki-tunnel.sh — SSH local-port-forward to Loki's HTTP API.
# ----------------------------------------------------------------------------
# Loki is ClusterIP-only (ADR-032) and has no UI of its own — Grafana's
# Explore view is the UI. This tunnel is for talking to the API directly,
# which is the faster way to answer "what labels actually exist?" and to
# check ingestion without a browser.
#
# Forwards to the Service ClusterIP via cp-1, same reasoning as
# prometheus-tunnel.sh. Plain HTTP; auth_enabled is false in this lab, so
# no X-Scope-OrgID tenant header is needed (it IS needed on any
# multi-tenant Loki, including OpenShift's LokiStack).
#
# Usage:   ./scripts/tunnels/loki-tunnel.sh
#          LOCAL_PORT=3999 ./scripts/tunnels/loki-tunnel.sh
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
KUBECONFIG_LOCAL="${REPO_ROOT}/kubernetes/admin.conf"

NAMESPACE="monitoring"
SERVICE="loki"
REMOTE_PORT=3100
LOCAL_PORT="${LOCAL_PORT:-3100}"

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

cat <<BANNER
Tunneling localhost:${LOCAL_PORT} -> ${ADDR}:${REMOTE_PORT} (${SERVICE}) via cp-1

Browse:  http://localhost:${LOCAL_PORT}/services
           every Loki module and its state -- in SingleBinary mode all 15
           (ingester, distributor, querier, compactor, ...) run in ONE
           process, which is the thing to see before session 6's LokiStack
  Ready    http://localhost:${LOCAL_PORT}/ready
  Config   http://localhost:${LOCAL_PORT}/config
             the running config -- what loki-values.yaml actually became
  Labels   http://localhost:${LOCAL_PORT}/loki/api/v1/labels
             the schema, and Alloy decides it, not Loki
  Metrics  http://localhost:${LOCAL_PORT}/metrics

Note: http://localhost:${LOCAL_PORT}/ returns 404 -- Loki serves no index
page, and there is no query UI here. Grafana's Explore view is the UI.

For the API from another terminal:

  curl -s localhost:${LOCAL_PORT}/ready
  curl -s localhost:${LOCAL_PORT}/loki/api/v1/labels | jq -r '.data[]'
  curl -s localhost:${LOCAL_PORT}/loki/api/v1/label/namespace/values | jq -r '.data[]'
  curl -sG localhost:${LOCAL_PORT}/loki/api/v1/query_range \\
       --data-urlencode 'query={namespace="monitoring"} |= "error"' \\
       --data-urlencode 'limit=5' | jq '.data.result[].values[][1]'

The labels call is the one to run first.

Ctrl+C to close. (Typing here echoes raw -- ssh -N holds the terminal and
reads nothing, so arrow keys show as ^[[A. Harmless.)
BANNER
ssh -L "${LOCAL_PORT}:${ADDR}:${REMOTE_PORT}" cp-1 -N
