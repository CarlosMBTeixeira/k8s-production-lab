#!/usr/bin/env bash
# routed-setup.sh — host addresses, forwarding on the routers, an HTTP server on h2.
# Routers start with interface addresses only: NO routes. The drills add them.
set -euo pipefail
x() { docker exec "clab-p1r-$1" sh -c "$2"; }
for r in r1 r2 r3; do x $r 'sysctl -qw net.ipv4.ip_forward=1'; done
x h1 'ip addr add 172.16.1.10/24 dev eth1 2>/dev/null; ip route replace 172.16.0.0/12 via 172.16.1.1; ip route replace 10.0.0.0/8 via 172.16.1.1'
x h2 'ip addr add 172.16.2.10/24 dev eth1 2>/dev/null; ip route replace 172.16.0.0/12 via 172.16.2.1; ip route replace 10.0.0.0/8 via 172.16.2.1'
x h2 'mkdir -p /srv; echo "hello from h2" > /srv/index.html; (cd /srv && nohup python3 -m http.server 80 >/dev/null 2>&1 &)'
echo "routed: up. Routers have no routes yet. vtysh: docker exec -it clab-p1r-r1 vtysh"
