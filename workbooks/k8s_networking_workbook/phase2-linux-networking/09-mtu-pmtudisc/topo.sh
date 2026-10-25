#!/usr/bin/env bash
# ============================================================================
# topo.sh — lab 2.09: client — r1 ==(MTU 1400 "WAN")== r2 — server
#
#   mc  eth0 10.1.1.2/24 ── r1-c 10.1.1.1/24  [mr1]  r1-w 10.9.0.1/30 ═╗
#                                                                     ║ MTU 1400
#   ms  eth0 10.2.2.2/24 ── r2-s 10.2.2.1/24  [mr2]  r2-w 10.9.0.2/30 ═╝
#
#   topo.sh up | serve | down        (root, on netlab-a)
# ============================================================================
set -euo pipefail
NS=(mc mr1 mr2 ms)

down() {
    for n in "${NS[@]}"; do
        if ip netns list | grep -qw "$n"; then
            ip netns pids "$n" | xargs -r kill 2>/dev/null || true
            ip netns del "$n"
        fi
    done
}

up() {
    down
    for n in "${NS[@]}"; do ip netns add "$n"; ip -n "$n" link set lo up; done
    ip link add eth0 netns mc  type veth peer name r1-c netns mr1
    ip link add r1-w netns mr1 type veth peer name r2-w netns mr2
    ip link add r2-s netns mr2 type veth peer name eth0 netns ms

    ip -n mc  addr add 10.1.1.2/24 dev eth0
    ip -n mr1 addr add 10.1.1.1/24 dev r1-c
    ip -n mr1 addr add 10.9.0.1/30 dev r1-w
    ip -n mr2 addr add 10.9.0.2/30 dev r2-w
    ip -n mr2 addr add 10.2.2.1/24 dev r2-s
    ip -n ms  addr add 10.2.2.2/24 dev eth0

    ip -n mr1 link set r1-w mtu 1400
    ip -n mr2 link set r2-w mtu 1400

    for l in "mc eth0" "mr1 r1-c" "mr1 r1-w" "mr2 r2-w" "mr2 r2-s" "ms eth0"; do
        set -- $l; ip -n "$1" link set "$2" up
    done
    for r in mr1 mr2; do ip netns exec $r sysctl -qw net.ipv4.ip_forward=1; done
    ip -n mc  route add default via 10.1.1.1
    ip -n ms  route add default via 10.2.2.1
    ip -n mr1 route add 10.2.2.0/24 via 10.9.0.2
    ip -n mr2 route add 10.1.1.0/24 via 10.9.0.1
    echo "topo 2.09: up"
}

serve() {
    mkdir -p /var/tmp/www
    echo "hello from server" > /var/tmp/www/index.html
    [ -f /var/tmp/www/big.bin ] || head -c 20M /dev/urandom > /var/tmp/www/big.bin
    ip netns pids ms | xargs -r kill 2>/dev/null || true
    setsid ip netns exec ms python3 -m http.server 8080 --directory /var/tmp/www \
        >/var/tmp/ms-http.log 2>&1 < /dev/null &
    sleep 1
    echo "topo 2.09: HTTP on 10.2.2.2:8080"
}

case "${1:-}" in
    up) up ;; down) down ;; serve) serve ;;
    *) echo "usage: $0 up|serve|down"; exit 1 ;;
esac
