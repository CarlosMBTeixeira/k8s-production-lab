#!/usr/bin/env bash
# post-deploy.sh — host addressing, routes, resolvers and the private
# endpoint's NAT, after `containerlab deploy -t topo.clab.yml`. Root, on netlab-c.
set -euo pipefail
x() { docker exec "clab-cloud-$1" sh -c "$2"; }
x a1       'ip addr add 10.10.1.10/24 dev eth1; ip route replace default via 10.10.1.1; echo "nameserver 10.10.2.53" > /etc/resolv.conf'
x o1       'ip addr add 172.20.1.10/24 dev eth1; ip route replace default via 172.20.1.1; echo "nameserver 172.20.2.53" > /etc/resolv.conf'
x b1       'ip addr add 10.20.1.10/24 dev eth1; ip route replace default via 10.20.1.1'
x dnsc-net 'ip addr add 10.10.2.53/24 dev eth1; ip route replace default via 10.10.2.1'
x dnso-net 'ip addr add 172.20.2.53/24 dev eth1; ip route replace default via 172.20.2.1'
# pe = the private endpoint: an IP in VPC-A whose traffic is carried to the
# provider's service over the provider's own backbone, not over routing.
x pe 'ip addr add 10.10.3.10/24 dev eth1; ip addr add 10.99.0.1/30 dev eth2
      ip route replace default via 10.10.3.1; ip route add 10.20.1.0/24 via 10.99.0.2
      sysctl -qw net.ipv4.ip_forward=1
      iptables -t nat -A PREROUTING -d 10.10.3.10 -p tcp --dport 80 -j DNAT --to-destination 10.20.1.10:80
      iptables -t nat -A POSTROUTING -o eth2 -j MASQUERADE'
echo "post-deploy: done. Try: docker exec clab-cloud-a1 curl -s 10.20.1.10"
