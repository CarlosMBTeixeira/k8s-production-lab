#!/usr/bin/env bash
# topo.sh up|down — drill 12: dual-stack h6a ── r6 ── h6b
#   h6a  fd00:1::10/64  10.6.1.10/24      r6  fd00:1::1 / fd00:2::1, 10.6.1.1 / 10.6.2.1
#   h6b  fd00:2::10/64  10.6.2.10/24
set -euo pipefail
NS=(h6a r6 h6b)
down() { for n in "${NS[@]}"; do ip netns pids $n 2>/dev/null | xargs -r kill 2>/dev/null || true; ip netns del $n 2>/dev/null || true; done; }
up() {
    down
    for n in "${NS[@]}"; do ip netns add $n; ip -n $n link set lo up; done
    ip link add eth0 netns h6a type veth peer name r-a netns r6
    ip link add r-b netns r6 type veth peer name eth0 netns h6b
    for l in "h6a eth0" "r6 r-a" "r6 r-b" "h6b eth0"; do set -- $l; ip -n $1 link set $2 up; done
    ip -n h6a addr add fd00:1::10/64 dev eth0 nodad; ip -n h6a addr add 10.6.1.10/24 dev eth0
    ip -n r6  addr add fd00:1::1/64 dev r-a nodad;   ip -n r6  addr add 10.6.1.1/24 dev r-a
    ip -n r6  addr add fd00:2::1/64 dev r-b nodad;   ip -n r6  addr add 10.6.2.1/24 dev r-b
    ip -n h6b addr add fd00:2::10/64 dev eth0 nodad; ip -n h6b addr add 10.6.2.10/24 dev eth0
    ip netns exec r6 sysctl -qw net.ipv6.conf.all.forwarding=1 net.ipv4.ip_forward=1
    ip -n h6a -6 route add default via fd00:1::1; ip -n h6a route add default via 10.6.1.1
    ip -n h6b -6 route add default via fd00:2::1; ip -n h6b route add default via 10.6.2.1
    sleep 2
    echo "topo 12: up"
}
case "${1:-}" in up) up ;; down) down ;; *) echo "usage: $0 up|down"; exit 1 ;; esac
