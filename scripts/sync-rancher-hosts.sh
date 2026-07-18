#!/bin/bash
# ============================================================================
# sync-rancher-hosts.sh — Keep rancher.lab pointed at the current Gateway IP.
# ----------------------------------------------------------------------------
# MetalLB assigns a new IP to Gateway/rancher on every cluster rebuild
# (same problem sync-ssh-config.sh solves for VM IPs — same fix: a managed
# block, rewritten idempotently, everything else in the file untouched).
#
# Updates:
#   1. WSL2 /etc/hosts (always — this process can sudo on the Linux side).
#   2. Windows hosts file via /mnt/c (best-effort — writing it requires an
#      elevated Windows session; if WSL wasn't launched as Admin, this
#      write fails by OS design, not a bug. Falls back to printing the
#      line to add manually.)
# Then validates with a curl against https://rancher.lab/healthz.
#
# Usage: ./scripts/sync-rancher-hosts.sh
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
KUBECONFIG_LOCAL="${REPO_ROOT}/kubernetes/admin.conf"

MARKER_START="# === K8S LAB RANCHER BEGIN (managed by sync-rancher-hosts.sh) ==="
MARKER_END="# === K8S LAB RANCHER END ==="
RANCHER_HOSTNAME="rancher.lab"

# ----------------------------------------------------------------------------
# Fetch a fresh kubeconfig (ADR-024: never trust a possibly-stale local one)
# and resolve the current Gateway address.
# ----------------------------------------------------------------------------
echo "|---------------------------------------------------------------------------"
echo "| Fetching kubeconfig + current Gateway address"
echo "|---------------------------------------------------------------------------"

scp -o StrictHostKeyChecking=no cp-1:~/.kube/config "${KUBECONFIG_LOCAL}" || {
    echo "ERROR: could not fetch kubeconfig from cp-1. Is the cluster up?"
    exit 1
}
export KUBECONFIG="${KUBECONFIG_LOCAL}"

ADDR="$(kubectl get gateway/rancher -n cattle-system -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)"
if [ -z "${ADDR}" ]; then
    echo "ERROR: Gateway/rancher has no address yet. Is Rancher installed? (scripts/pipeline/04_rancher.sh)"
    exit 1
fi
echo "  Gateway address: ${ADDR}"

# ----------------------------------------------------------------------------
# Reusable: rewrite the managed block in a given hosts file.
# ----------------------------------------------------------------------------
sync_hosts_file() {
    local target_file="$1"
    local use_sudo="$2"   # "sudo" or ""

    if [ ! -w "$(dirname "${target_file}")" ] && [ "${use_sudo}" != "sudo" ]; then
        return 1
    fi

    local tmp_file
    tmp_file=$(mktemp)

    if [ "${use_sudo}" = "sudo" ]; then
        sudo touch "${target_file}" 2>/dev/null || return 1
        sudo awk -v start="$MARKER_START" -v end="$MARKER_END" '
            $0 == start { skip = 1; next }
            $0 == end   { skip = 0; next }
            !skip       { print }
        ' "${target_file}" > "${tmp_file}" 2>/dev/null || return 1
    else
        awk -v start="$MARKER_START" -v end="$MARKER_END" '
            $0 == start { skip = 1; next }
            $0 == end   { skip = 0; next }
            !skip       { print }
        ' "${target_file}" > "${tmp_file}" 2>/dev/null || return 1
    fi

    printf '%s\n%s  %s\n%s\n' "$MARKER_START" "$ADDR" "$RANCHER_HOSTNAME" "$MARKER_END" >> "${tmp_file}"

    if [ "${use_sudo}" = "sudo" ]; then
        sudo mv "${tmp_file}" "${target_file}" 2>/dev/null || { rm -f "${tmp_file}"; return 1; }
    else
        mv "${tmp_file}" "${target_file}" 2>/dev/null || { rm -f "${tmp_file}"; return 1; }
    fi
    return 0
}

# ----------------------------------------------------------------------------
# 1. WSL2 /etc/hosts
# ----------------------------------------------------------------------------
echo
echo "|---------------------------------------------------------------------------"
echo "| Updating WSL2 /etc/hosts"
echo "|---------------------------------------------------------------------------"
if sync_hosts_file "/etc/hosts" "sudo"; then
    echo "  ✅ /etc/hosts updated (${ADDR} -> ${RANCHER_HOSTNAME})"
else
    echo "  ❌ Could not update /etc/hosts — add manually:"
    echo "     ${ADDR}  ${RANCHER_HOSTNAME}"
fi

# ----------------------------------------------------------------------------
# 2. Windows hosts file (best-effort, needs an elevated WSL session)
# ----------------------------------------------------------------------------
echo
echo "|---------------------------------------------------------------------------"
echo "| Updating Windows hosts file (best-effort)"
echo "|---------------------------------------------------------------------------"
WIN_HOSTS="/mnt/c/Windows/System32/drivers/etc/hosts"
if sync_hosts_file "${WIN_HOSTS}" ""; then
    echo "  ✅ Windows hosts file updated (${ADDR} -> ${RANCHER_HOSTNAME})"
else
    echo "  ⚠️  Could not write Windows hosts file (needs an elevated WSL/Windows"
    echo "     session — this is expected if you didn't launch as Admin)."
    echo "     Add this line manually to C:\\Windows\\System32\\drivers\\etc\\hosts:"
    echo "       ${ADDR}  ${RANCHER_HOSTNAME}"
fi

# ----------------------------------------------------------------------------
# 3. Validate
# ----------------------------------------------------------------------------
echo
echo "|---------------------------------------------------------------------------"
echo "| Validating"
echo "|---------------------------------------------------------------------------"
CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://${RANCHER_HOSTNAME}/healthz")
if [ "${CODE}" = "200" ]; then
    echo "  ✅ https://${RANCHER_HOSTNAME}/healthz -> 200"
else
    echo "  ❌ https://${RANCHER_HOSTNAME}/healthz -> ${CODE} (expected 200)"
fi

echo
echo "|---------------------------------------------------------------------------"
echo "| Rancher UI: https://${RANCHER_HOSTNAME}"
echo "|---------------------------------------------------------------------------"
