#!/usr/bin/env bash
# topo.sh up [vrid-for-B] | down — drill 11: two routers sharing a virtual IP.
#
#   vh 10.90.0.10 ──┐                ┌── vA 10.90.0.2 ── 10.91.1.0/30 ──┐
#   (gw 10.90.0.1)  ├─ [vsw: br0] ───┤                                  ├── vup  (10.91.0.10 = "the server")
#                   │                └── vB 10.90.0.3 ── 10.91.2.0/30 ──┘
#   VIP 10.90.0.1 — owned by whichever of vA/vB is VRRP master (keepalived)
set -euo pipefail
NS=(vsw vA vB vh vup)
down() {
    for r in A B; do [ -f /var/tmp/k$r.pid ] && kill "$(cat /var/tmp/k$r.pid)" 2>/dev/null; rm -f /var/tmp/k$r*.pid; done
    for n in "${NS[@]}"; do ip netns pids $n 2>/dev/null | xargs -r kill 2>/dev/null || true; ip netns del $n 2>/dev/null || true; done
}
conf() { # name prio vrid
cat > /var/tmp/k$1.conf <<C
vrrp_instance LAB {
    state BACKUP
    interface eth0
    virtual_router_id $3
    priority $2
    advert_int 1
    garp_master_refresh 5
    virtual_ipaddress {
        10.90.0.1/24
    }
}
C
}
start() { ip netns exec v$1 keepalived -P -f /var/tmp/k$1.conf -p /var/tmp/k$1.pid -r /var/tmp/k$1-vrrp.pid; }
up() {
    down
    for n in "${NS[@]}"; do ip netns add $n; ip -n $n link set lo up; done
    ip -n vsw link add br0 type bridge; ip -n vsw link set br0 up
    for n in vA vB vh; do
        ip link add p-$n netns vsw type veth peer name eth0 netns $n
        ip -n vsw link set p-$n master br0 up; ip -n $n link set eth0 up
    done
    ip -n vA addr add 10.90.0.2/24 dev eth0; ip -n vB addr add 10.90.0.3/24 dev eth0
    ip -n vh addr add 10.90.0.10/24 dev eth0; ip -n vh route add default via 10.90.0.1
    ip link add up-a netns vA type veth peer name a netns vup
    ip link add up-b netns vB type veth peer name b netns vup
    ip -n vA addr add 10.91.1.1/30 dev up-a; ip -n vup addr add 10.91.1.2/30 dev a
    ip -n vB addr add 10.91.2.1/30 dev up-b; ip -n vup addr add 10.91.2.2/30 dev b
    for l in "vA up-a" "vB up-b" "vup a" "vup b"; do set -- $l; ip -n $1 link set $2 up; done
    ip -n vup addr add 10.91.0.10/32 dev lo
    ip -n vA route add 10.91.0.10/32 via 10.91.1.2; ip -n vB route add 10.91.0.10/32 via 10.91.2.2
    ip -n vup route add 10.90.0.0/24 nexthop via 10.91.1.1 nexthop via 10.91.2.1
    for r in vA vB; do ip netns exec $r sysctl -qw net.ipv4.ip_forward=1; done
    conf A 150 51; conf B 100 "${1:-51}"
    start A; start B
    sleep 4
    echo "topo 11: up — VIP 10.90.0.1; host vh; server 10.91.0.10"
}
case "${1:-}" in up) up "${2:-51}" ;; down) down ;; *) echo "usage: $0 up [vrid-B]|down"; exit 1 ;; esac
