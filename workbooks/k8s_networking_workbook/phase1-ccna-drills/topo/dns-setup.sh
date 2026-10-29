#!/usr/bin/env bash
# dns-setup.sh — addresses, and the client's resolver pointed at the lab server.
set -euo pipefail
x() { docker exec "clab-p1d-$1" sh -c "$2"; }
x dns-net 'ip addr add 10.53.0.53/24 dev eth1 2>/dev/null; ip link set eth1 up'
x client  'ip addr add 10.53.0.10/24 dev eth1 2>/dev/null; ip link set eth1 up; printf "nameserver 10.53.0.53\nsearch lab.local\noptions ndots:1\n" > /etc/resolv.conf'
echo "dns: up. Client: docker exec -it clab-p1d-client bash"
