#!/usr/bin/env bash
# ============================================================================
# topo.sh — lab 2.10: a "node" (netlab-a's root ns) with three backend pods
# and one client pod on a bridge, like a bridge-based CNI (cni0).
#
#   svc0 10.50.0.1/24 (root ns = the node)
#     ├── vb1 ── b1 10.50.0.11  HTTP :8080 → "b1"
#     ├── vb2 ── b2 10.50.0.12  HTTP :8080 → "b2"
#     ├── vb3 ── b3 10.50.0.13  HTTP :8080 → "b3"
#     └── vcl ── cl 10.50.0.20  (client pod)
#
#   topo.sh up      build + start backends, ip_forward=1
#   topo.sh down    remove namespaces, svc0, every LAB-* nat chain, the IPVS service
# ============================================================================
set -euo pipefail
VIP=10.96.100.10

clean_rules() {
    iptables -t nat -D PREROUTING  -j LAB-SERVICES    2>/dev/null || true
    iptables -t nat -D OUTPUT      -j LAB-SERVICES    2>/dev/null || true
    iptables -t nat -D POSTROUTING -j LAB-POSTROUTING 2>/dev/null || true
    for c in $(iptables -t nat -S | awk '/^-N LAB-/{print $2}'); do iptables -t nat -F "$c"; done
    for c in $(iptables -t nat -S | awk '/^-N LAB-/{print $2}'); do iptables -t nat -X "$c"; done
    command -v ipvsadm >/dev/null && ipvsadm -D -t $VIP:80 2>/dev/null || true
    ip link del kube-ipvs0 2>/dev/null || true
}

down() {
    for n in b1 b2 b3 cl; do
        if ip netns list | grep -qw "$n"; then
            ip netns pids "$n" | xargs -r kill 2>/dev/null || true
            ip netns del "$n"
        fi
    done
    ip link del svc0 2>/dev/null || true
    clean_rules
}

up() {
    down
    ip link add svc0 type bridge
    ip addr add 10.50.0.1/24 dev svc0
    ip link set svc0 up
    sysctl -qw net.ipv4.ip_forward=1
    add_pod() { # name ip
        ip netns add "$1"
        ip link add "v$1" type veth peer name eth0 netns "$1"
        ip link set "v$1" master svc0 up
        ip -n "$1" addr add "$2/24" dev eth0
        ip -n "$1" link set eth0 up; ip -n "$1" link set lo up
        ip -n "$1" route add default via 10.50.0.1
    }
    for i in 1 2 3; do
        add_pod b$i 10.50.0.1$i
        mkdir -p /var/tmp/svc/b$i; echo "b$i" > /var/tmp/svc/b$i/index.html
        setsid ip netns exec b$i python3 -m http.server 8080 --directory /var/tmp/svc/b$i \
            >/var/tmp/svc/b$i.log 2>&1 < /dev/null &
    done
    add_pod cl 10.50.0.20
    sleep 1
    echo "topo 2.10: up (backends 10.50.0.11-13:8080, client cl 10.50.0.20, VIP to build: $VIP:80)"
}

case "${1:-}" in
    up) up ;; down) down ;; clean-rules) clean_rules ;;
    *) echo "usage: $0 up|down|clean-rules"; exit 1 ;;
esac
