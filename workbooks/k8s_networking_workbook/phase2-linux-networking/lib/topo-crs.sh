#!/usr/bin/env bash
# ============================================================================
# topo-crs.sh — the client / router / server topology reused by Phase 2.
# Run as root on netlab-a.  Lab 2.03 builds this by hand first; later labs
# call this script so they start from a known state.
#
#   client                 router                       server
#   c-eth0 10.1.1.2/24 ── r-c   10.1.1.1/24
#                          r-s1 10.2.2.1/24 ────────── s1 10.2.2.2/24
#                          r-s2 10.3.3.1/24 ────────── s2 10.3.3.2/24
#   default via 10.1.1.1                                default via 10.2.2.1
#
#   topo-crs.sh up       build (tears down first)
#   topo-crs.sh serve    HTTP on server:8080 serving /var/tmp/www (small + 20 MB file)
#   topo-crs.sh down     kill processes in the namespaces, delete them
# ============================================================================
set -euo pipefail
NS=(client router server)

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

    ip link add c-eth0 netns client type veth peer name r-c  netns router
    ip link add r-s1   netns router type veth peer name s1   netns server
    ip link add r-s2   netns router type veth peer name s2   netns server

    ip -n client addr add 10.1.1.2/24 dev c-eth0
    ip -n router addr add 10.1.1.1/24 dev r-c
    ip -n router addr add 10.2.2.1/24 dev r-s1
    ip -n router addr add 10.3.3.1/24 dev r-s2
    ip -n server addr add 10.2.2.2/24 dev s1
    ip -n server addr add 10.3.3.2/24 dev s2

    for l in "client c-eth0" "router r-c" "router r-s1" "router r-s2" "server s1" "server s2"; do
        set -- $l; ip -n "$1" link set "$2" up
    done

    ip netns exec router sysctl -qw net.ipv4.ip_forward=1
    # Loose rp_filter everywhere, explicitly: a new netns inherits IPv4 conf
    # from the root ns, and labs must not depend on what that happens to be.
    for n in "${NS[@]}"; do ip netns exec "$n" sysctl -qw net.ipv4.conf.all.rp_filter=2; done
    ip -n client route add default via 10.1.1.1
    ip -n server route add default via 10.2.2.1
    echo "topo-crs: up"
}

serve() {
    mkdir -p /var/tmp/www
    echo "hello from server" > /var/tmp/www/index.html
    [ -f /var/tmp/www/big.bin ] || head -c 20M /dev/urandom > /var/tmp/www/big.bin
    ip netns pids server | xargs -r kill 2>/dev/null || true
    setsid ip netns exec server python3 -m http.server 8080 --directory /var/tmp/www \
        >/var/tmp/server-http.log 2>&1 < /dev/null &
    sleep 1
    echo "topo-crs: HTTP on 10.2.2.2:8080 (index.html, big.bin)"
}

case "${1:-}" in
    up) up ;; down) down ;; serve) serve ;;
    *) echo "usage: $0 up|serve|down"; exit 1 ;;
esac
