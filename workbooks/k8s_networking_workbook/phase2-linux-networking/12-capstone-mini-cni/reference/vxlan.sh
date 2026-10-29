#!/usr/bin/env bash
# ============================================================================
# reference/vxlan.sh a|b [down] — milestone 4, the Flannel VXLAN model by hand.
#
# Per node: a VXLAN device "lab.42" (VNI 42, port 8472, no learning) holding
# the address <podCIDR>.0/32 and a fixed MAC. For each remote node:
#   route  <remote podCIDR> via <remote>.0 dev lab.42 onlink   (L3: which VTEP IP)
#   neigh  <remote>.0 lladdr <remote VTEP MAC>                 (no ARP across the tunnel)
#   fdb    <remote VTEP MAC> dst <remote node IP>               (which underlay IP)
# Flannel learns the remote MAC and node IP from node annotations; here they
# are derived from the side letter.
# Pods need MTU 1450 now:  MTU=1450 bash install.sh a, then re-add the pods.
# ============================================================================
set -euo pipefail
source /workbook/setup/netlab.env
UP=$(ip -o route show default | awk '{print $5}')
side=${1:?a|b}
case "$side" in
  a) ME=$A_IP N=1 PEER=$B_IP P=2 ;;
  b) ME=$B_IP N=2 PEER=$A_IP P=1 ;;
esac
mac() { printf '0e:00:00:00:%02x:00' "$1"; }

ip link del lab.42 2>/dev/null || true
bash "$(dirname "$0")/hostgw.sh" "$side" down
[ "${2:-}" = down ] && exit 0

ip link add lab.42 type vxlan id 42 dstport 8472 local "$ME" dev "$UP" nolearning
ip link set lab.42 address "$(mac $N)" mtu 1450 up
ip addr add "10.244.$N.0/32" dev lab.42
ip route add "10.244.$P.0/24" via "10.244.$P.0" dev lab.42 onlink
ip neigh replace "10.244.$P.0" lladdr "$(mac $P)" dev lab.42 nud permanent
bridge fdb append "$(mac $P)" dev lab.42 dst "$PEER" self permanent
ip -d link show lab.42 | head -3
ip route get "10.244.$P.2"
