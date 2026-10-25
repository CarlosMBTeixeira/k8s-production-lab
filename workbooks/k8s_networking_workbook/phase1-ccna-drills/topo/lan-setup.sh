#!/usr/bin/env bash
# lan-setup.sh — a bridge in each switch (eth1-3 + eth5 on sw1; eth1-3 on sw2),
# hosts in 10.0.10.0/24. eth4 (the second inter-switch link) is left OUT of
# the bridges on purpose: with both links bridged and no STP, you'd have a loop.
set -euo pipefail
x() { docker exec "clab-p1l-$1" sh -c "$2"; }
x sw1 'ip link add br0 type bridge 2>/dev/null; ip link set br0 up; for p in eth1 eth2 eth3 eth5; do ip link set $p master br0; ip link set $p up; done; ip link set eth4 up'
x sw2 'ip link add br0 type bridge 2>/dev/null; ip link set br0 up; for p in eth1 eth2 eth3; do ip link set $p master br0; ip link set $p up; done; ip link set eth4 up'
n=1; for h in h1 h2 h3 h4; do x $h "ip addr add 10.0.10.$n/24 dev eth1 2>/dev/null; ip link set eth1 up"; n=$((n+1)); done
x r1 'ip link set eth1 up'
echo "lan: up. Switch shell: docker exec -it clab-p1l-sw1 bash   (bridge fdb show br br0)"
