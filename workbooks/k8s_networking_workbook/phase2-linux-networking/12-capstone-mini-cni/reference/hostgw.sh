#!/usr/bin/env bash
# reference/hostgw.sh a|b [down] — milestone 3, routed mode ("host-gw").
# Each node routes the other node's pod CIDR via the other node's IP. Works
# only because both VMs share one L2 segment (the Multipass bridge) — the same
# limitation Flannel host-gw and Calico without encapsulation have.
set -euo pipefail
source /workbook/setup/netlab.env
case "${1:?a|b}" in a) PEER=$B_IP; CIDR=10.244.2.0/24 ;; b) PEER=$A_IP; CIDR=10.244.1.0/24 ;; esac
if [ "${2:-}" = down ]; then ip route del "$CIDR" via "$PEER" 2>/dev/null || true; exit 0; fi
ip route replace "$CIDR" via "$PEER"
ip route get "${CIDR%.0/24}.2"
