#!/bin/bash
# ============================================================================
# fix-vm-clocks.sh — Detect and correct VM clock drift.
# ----------------------------------------------------------------------------
# VM guest clocks can silently drift under host CPU pressure (KVM vCPU
# scheduling pauses), even while `timedatectl` reports "synchronized: yes"
# on the guest -- the daemon trusts its last successful check, not
# continuous verification. Confirmed during the observability stack
# install (2026-07-19): 3 of the then-4 VMs were ~20 minutes behind despite
# reporting synchronized, breaking TLS certificate validation on a
# Gateway whose cert had just been generated on the WSL2 host.
#
# Checks each VM's clock against the WSL2 host's clock and forces an
# NTP resync (systemd-timesyncd restart) on any VM drifted more than
# DRIFT_THRESHOLD_SECONDS. Idempotent / safe to run every session.
# ============================================================================
set -uo pipefail

DRIFT_THRESHOLD_SECONDS=30

# Topology comes from lab-config.sh (ADR-036): checking a worker that was
# never built reports a false failure every run.
source "$(dirname "$0")/lab-config.sh"
read -r -a VMS <<< "$(lab_ssh_aliases)"

echo "|---------------------------------------------------------------------------"
echo "| Checking VM clock drift"
echo "|---------------------------------------------------------------------------"

HOST_EPOCH=$(date -u +%s)

for vm in "${VMS[@]}"; do
    VM_EPOCH=$(ssh -o ConnectTimeout=5 "${vm}" 'date -u +%s' 2>/dev/null)
    if [ -z "${VM_EPOCH}" ]; then
        echo "  ⚠️  ${vm}: unreachable, skipping."
        continue
    fi
    DRIFT=$((VM_EPOCH - HOST_EPOCH))
    ABS_DRIFT=${DRIFT#-}
    if [ "${ABS_DRIFT}" -gt "${DRIFT_THRESHOLD_SECONDS}" ]; then
        echo "  ⚠️  ${vm}: drifted ${DRIFT}s, forcing resync..."
        ssh "${vm}" 'sudo systemctl restart systemd-timesyncd'
        sleep 3
        NEW_VM_EPOCH=$(ssh "${vm}" 'date -u +%s')
        NEW_DRIFT=$((NEW_VM_EPOCH - HOST_EPOCH))
        echo "     now drifted ${NEW_DRIFT}s"
    else
        echo "  ✅ ${vm}: drift ${DRIFT}s (within ${DRIFT_THRESHOLD_SECONDS}s threshold)"
    fi
done
