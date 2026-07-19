#!/bin/bash
# ============================================================================
# morning-check.sh — Validate lab state at the start of a session.
# ----------------------------------------------------------------------------
# Runs a series of quick health checks on the lab foundation. If any check
# fails, the script prints what failed and exits non-zero. Run this at the
# start of every session before doing any new work, or as part of the
# lab-management.sh build/rebuild flow.
#
# Some lines are 'info' rather than 'check': they report state visually
# but do NOT contribute to the exit code. The git working-tree status is
# the canonical example — having uncommitted changes is normal during
# active development and should never block automation (e.g. 01_initial_cluster_setup.sh).
#
# Usage: ./scripts/morning-check.sh
# ============================================================================

set -uo pipefail

ERRORS=0

# Helper that runs a command silently and reports success or failure.
# Failures bump ERRORS and surface in the script's exit code.
check() {
    local name="$1"
    local cmd="$2"
    if eval "$cmd" >/dev/null 2>&1; then
        echo "  ✅ $name"
    else
        echo "  ❌ $name"
        ERRORS=$((ERRORS+1))
    fi
}

# Helper that reports state but does NOT contribute to ERRORS. Used for
# advisory signals where the operator should know the state but the
# automation pipeline should not abort. Symbol is ⚠️  (warning), not ❌.
info() {
    local name="$1"
    local cmd="$2"
    if eval "$cmd" >/dev/null 2>&1; then
        echo "  ✅ $name"
    else
        echo "  ⚠️  $name (informational, does not block)"
    fi
}

echo "|---------------------------------------------------------------------------"
echo "| Lab health check — $(date '+%H:%M %d-%m-%Y')"
echo "|---------------------------------------------------------------------------"

echo "WSL2 host:"
check "systemd is PID 1"                "[ \"\$(ps -p 1 -o comm=)\" = 'systemd' ]"
check "Multipass daemon responding"     "multipass version"
# ADR-029 (resolved 2026-07-19): direct Windows access to lab UIs now
# works once fix-network-access.sh has (re)applied these two rules —
# both non-persistent, reset on every WSL2/Docker restart. The SSH
# tunnel (scripts/tunnels/) remains the no-setup-required fallback.
check "Docker allows Multipass bridge (DOCKER-USER)" "sudo iptables -C DOCKER-USER -s 10.215.138.0/24 -j ACCEPT >/dev/null 2>&1 && sudo iptables -C DOCKER-USER -d 10.215.138.0/24 -j ACCEPT >/dev/null 2>&1"
check "New inbound connections to bridge allowed (iptables-legacy)" "sudo iptables-legacy -C FORWARD -i eth0 -o mpqemubr0 -d 10.215.138.0/24 -j ACCEPT >/dev/null 2>&1"
echo ""

echo "VMs:"
for vm in controlplane-1 controlplane-2 worker-1 worker-2; do
    check "$vm running"                 "multipass info $vm | grep -q 'State.*Running'"
done
echo ""

echo "SSH access:"
for alias in cp-1 cp-2 w-1 w-2; do
    check "ssh $alias works"            "ssh -o ConnectTimeout=5 $alias 'true'"
done
echo "Clock sync:"
HOST_EPOCH_FOR_CHECK=$(date -u +%s)
for alias in cp-1 cp-2 w-1 w-2; do
    vm_epoch=$(ssh -o ConnectTimeout=5 "$alias" 'date -u +%s' 2>/dev/null)
    if [ -z "$vm_epoch" ]; then
        drift_ok="false"
    else
        drift=$((vm_epoch - HOST_EPOCH_FOR_CHECK))
        abs_drift=${drift#-}
        if [ "$abs_drift" -lt 30 ]; then
            drift_ok="true"
        else
            drift_ok="false"
        fi
    fi
    check "$alias clock drift < 30s" "[ \"$drift_ok\" = \"true\" ]"
done
echo ""

echo "Repo:"
# git status clean is INFO (not a check): uncommitted changes are normal
# during active development and must not block the pipeline. The visual
# cue still helps the operator notice forgotten work.
info  "git status clean"                "cd ~/k8slab && [ -z \"\$(git status --porcelain)\" ]"
# Being out of sync with origin IS a check: it usually means the operator
# forgot to push or pull, and continuing risks divergent history.
check "in sync with origin"             "cd ~/k8slab && git fetch --quiet && [ \"\$(git rev-parse HEAD)\" = \"\$(git rev-parse @{u})\" ]"
echo ""

echo "|---------------------------------------------------------------------------"
if [ "$ERRORS" -eq 0 ]; then
    echo "| All checks passed. Ready for the session."
else
    echo "| $ERRORS check(s) failed. Investigate before continuing."
fi
echo "|---------------------------------------------------------------------------"

exit $ERRORS
