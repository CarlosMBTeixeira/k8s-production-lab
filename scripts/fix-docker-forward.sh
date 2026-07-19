#!/bin/bash
# ============================================================================
# fix-docker-forward.sh — Ensure Docker's DOCKER-USER chain allows the
# Multipass bridge subnet through.
# ----------------------------------------------------------------------------
# Docker manages the nftables-backed FORWARD chain independently of
# Multipass's own iptables-legacy rules. On every Docker daemon restart
# (which happens on every Windows/WSL2 reboot), FORWARD's default policy
# is DROP and only Docker's own DOCKER-USER/DOCKER-FORWARD chains are
# consulted — Multipass's mpqemubr0 traffic is not covered by either, so
# it silently drops. This blocks outbound internet from the lab VMs
# (breaks apt update, kubeadm image pulls, everything) and is the likely
# cause of the Windows-to-VM return-path issue documented as unsolved.
#
# DOCKER-USER is the chain Docker explicitly reserves for user-added
# rules (docs.docker.com/network/packet-filtering-firewalls/#docker-user)
# — this is the correct insertion point, not iptables-legacy and not the
# raw FORWARD chain (Docker rewrites those on every restart).
#
# Idempotent: checks before inserting, safe to run every session.
# ============================================================================
set -euo pipefail
SUBNET="10.215.138.0/24"
add_rule_if_missing() {
    local direction="$1"
    if ! sudo iptables -C DOCKER-USER "${direction}" "${SUBNET}" -j ACCEPT 2>/dev/null; then
        sudo iptables -I DOCKER-USER "${direction}" "${SUBNET}" -j ACCEPT
        echo "  Added DOCKER-USER rule (${direction} ${SUBNET})"
    else
        echo "  DOCKER-USER rule already present (${direction} ${SUBNET})"
    fi
}
echo "|---------------------------------------------------------------------------"
echo "| Ensuring Docker allows Multipass bridge traffic (DOCKER-USER)"
echo "|---------------------------------------------------------------------------"
add_rule_if_missing -s
add_rule_if_missing -d
