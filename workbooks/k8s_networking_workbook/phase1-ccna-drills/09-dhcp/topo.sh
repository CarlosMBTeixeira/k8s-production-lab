#!/usr/bin/env bash
# topo.sh up|down — drill 09: one L2 segment (bridge inside namespace dsw) with
#   dgw  10.80.0.1   the gateway (and "the outside": 10.81.0.1 on its lo)
#   dsrv 10.80.0.2   the DHCP server (dnsmasq, DHCP only)
#   dcli             a client with no address
set -euo pipefail
NS=(dsw dgw dsrv dcli drog)
down() {
    for f in /var/tmp/dsrv.pid /var/tmp/drog.pid; do [ -f $f ] && kill "$(cat $f)" 2>/dev/null; rm -f $f; done
    for n in "${NS[@]}"; do ip netns pids $n 2>/dev/null | xargs -r kill 2>/dev/null || true; ip netns del $n 2>/dev/null || true; done
}
port() { # ns ifname-in-ns
    ip link add "p-$1" netns dsw type veth peer name "$2" netns "$1"
    ip -n dsw link set "p-$1" master br0 up; ip -n "$1" link set "$2" up; ip -n "$1" link set lo up
}
up() {
    down
    for n in dsw dgw dsrv dcli; do ip netns add $n; done
    ip -n dsw link add br0 type bridge; ip -n dsw link set br0 up
    port dgw eth0; port dsrv eth0; port dcli eth0
    ip -n dgw addr add 10.80.0.1/24 dev eth0; ip -n dgw addr add 10.81.0.1/32 dev lo
    ip -n dsrv addr add 10.80.0.2/24 dev eth0
    # --no-ping: by default dnsmasq pings a new address before offering it and
    # delays the Offer ~3 s, so the client re-sends Discover and the capture
    # shows Discover/Offer twice instead of a clean DORA.
    ip netns exec dsrv dnsmasq --interface=eth0 --bind-interfaces --port=0 --user=root --group=root --no-ping \
        --dhcp-range=10.80.0.100,10.80.0.150,255.255.255.0,2m \
        --dhcp-option=option:router,10.80.0.1 --dhcp-option=option:dns-server,10.80.0.53 \
        --dhcp-leasefile=/var/tmp/dsrv.leases --pid-file=/var/tmp/dsrv.pid \
        --log-dhcp --log-facility=/var/tmp/dsrv.log
    echo "topo 09: up (server 10.80.0.2, pool .100-.150, gateway .1, outside 10.81.0.1)"
}
case "${1:-}" in up) up ;; down) down ;; *) echo "usage: $0 up|down"; exit 1 ;; esac
