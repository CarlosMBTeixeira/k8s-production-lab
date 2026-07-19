#!/bin/bash
# ============================================================================
# fix-network-access.sh — Ensure the WSL2 host allows traffic into the
# Multipass bridge, on both firewall stacks.
# ----------------------------------------------------------------------------
# Two independent, non-persistent fixes, both reset on every WSL2/Docker
# restart:
#
# 1. DOCKER-USER (nftables backend). Docker's FORWARD chain defaults to
#    policy DROP and is reapplied on every Docker daemon restart. Its
#    DOCKER-USER/DOCKER-FORWARD chains don't know about Multipass's
#    mpqemubr0 traffic, so it silently drops — breaking outbound internet
#    from the lab VMs (apt update, image pulls, everything). DOCKER-USER
#    is Docker's own documented insertion point for user rules
#    (docs.docker.com/engine/network/packet-filtering-firewalls/#docker-user).
#
# 2. iptables-legacy FORWARD (Multipass's own stack). Multipass's default
#    rules only accept inbound-to-VM traffic that's a reply to a
#    VM-initiated connection (ctstate RELATED,ESTABLISHED) — brand new
#    connections from outside (e.g. direct from Windows) are rejected by
#    design. Adding an ACCEPT for eth0->mpqemubr0 opens that up, enabling
#    direct Windows access to lab UIs without the SSH tunnel (ADR-029).
#
# Idempotent: checks before inserting, safe to run every session.
# ============================================================================
set -euo pipefail
SUBNET="10.215.138.0/24"

fix_docker_user() {
    echo "|---------------------------------------------------------------------------"
    echo "| Ensuring Docker allows Multipass bridge traffic (DOCKER-USER)"
    echo "|---------------------------------------------------------------------------"
    for direction in -s -d; do
        if ! sudo iptables -C DOCKER-USER "${direction}" "${SUBNET}" -j ACCEPT 2>/dev/null; then
            sudo iptables -I DOCKER-USER "${direction}" "${SUBNET}" -j ACCEPT
            echo "  Added DOCKER-USER rule (${direction} ${SUBNET})"
        else
            echo "  DOCKER-USER rule already present (${direction} ${SUBNET})"
        fi
    done
}

fix_inbound_new_connections() {
    echo "|---------------------------------------------------------------------------"
    echo "| Ensuring new inbound connections to the bridge are allowed (iptables-legacy)"
    echo "|---------------------------------------------------------------------------"
    if ! sudo iptables-legacy -C FORWARD -i eth0 -o mpqemubr0 -d "${SUBNET}" -j ACCEPT 2>/dev/null; then
        sudo iptables-legacy -I FORWARD -i eth0 -o mpqemubr0 -d "${SUBNET}" -j ACCEPT
        echo "  Added iptables-legacy FORWARD rule (eth0 -> mpqemubr0, new connections)"
    else
        echo "  iptables-legacy FORWARD rule already present"
    fi
}

fix_docker_user
fix_inbound_new_connections
