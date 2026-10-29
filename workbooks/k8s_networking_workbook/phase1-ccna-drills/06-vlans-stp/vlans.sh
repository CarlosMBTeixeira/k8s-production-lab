#!/usr/bin/env bash
# vlans.sh — drill 06's VLAN layout on topo/lan (run after lan-setup.sh):
#   VLAN 10: h1 (sw1 eth1), h3 (sw2 eth1)   10.0.10.0/24, gateway 10.0.10.254
#   VLAN 20: h2 (sw1 eth2), h4 (sw2 eth2)   10.0.20.0/24, gateway 10.0.20.254
#   trunk sw1 eth3 ↔ sw2 eth3 (10, 20) · trunk sw1 eth5 → r1 (router-on-a-stick)
set -euo pipefail
x() { docker exec "clab-p1l-$1" sh -c "$2"; }
access() { x "$1" "bridge vlan add dev $2 vid $3 pvid untagged; bridge vlan del dev $2 vid 1"; }
trunk()  { x "$1" "bridge vlan add dev $2 vid 10; bridge vlan add dev $2 vid 20; bridge vlan del dev $2 vid 1"; }
for s in sw1 sw2; do x $s 'ip link set br0 type bridge vlan_filtering 1'; done
access sw1 eth1 10; access sw1 eth2 20; trunk sw1 eth3; trunk sw1 eth5
access sw2 eth1 10; access sw2 eth2 20; trunk sw2 eth3
x h1 'ip addr flush dev eth1; ip addr add 10.0.10.1/24 dev eth1; ip route replace default via 10.0.10.254'
x h3 'ip addr flush dev eth1; ip addr add 10.0.10.3/24 dev eth1; ip route replace default via 10.0.10.254'
x h2 'ip addr flush dev eth1; ip addr add 10.0.20.2/24 dev eth1; ip route replace default via 10.0.20.254'
x h4 'ip addr flush dev eth1; ip addr add 10.0.20.4/24 dev eth1; ip route replace default via 10.0.20.254'
x r1 'sysctl -qw net.ipv4.ip_forward=1
      ip link add link eth1 name eth1.10 type vlan id 10 2>/dev/null; ip link add link eth1 name eth1.20 type vlan id 20 2>/dev/null
      ip addr add 10.0.10.254/24 dev eth1.10 2>/dev/null; ip addr add 10.0.20.254/24 dev eth1.20 2>/dev/null
      ip link set eth1.10 up; ip link set eth1.20 up'
echo "vlans: done"
