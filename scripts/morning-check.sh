#!/bin/bash
# ============================================================================
# morning-check.sh — Validate lab state at the start of a session.
# ----------------------------------------------------------------------------
# Runs a series of quick health checks on the lab foundation. If any check
# fails, the script prints what failed and exits non-zero. Run this at the
# start of every session before doing any new work, or as part of the
# lab-management.sh build/rebuild flow.
#
# Usage: ./scripts/morning-check.sh
# ============================================================================

set -uo pipefail
ERRORS=0

# Helper that runs a command silently and reports success or failure.
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

echo "|---------------------------------------------------------------------------"
echo "| Lab health check — $(date '+%H:%M %d-%m-%Y')"
echo "|---------------------------------------------------------------------------"

echo "WSL2 host:"
check "systemd is PID 1"                "[ \"\$(ps -p 1 -o comm=)\" = 'systemd' ]"
check "Multipass daemon responding"     "multipass version"
check "FORWARD rules on mpqemubr0"      "sudo iptables -L FORWARD -n -v | grep -q mpqemubr0"

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

echo ""
echo "Repo:"
check "git status clean"                "cd ~/k8slab && [ -z \"\$(git status --porcelain)\" ]"
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
