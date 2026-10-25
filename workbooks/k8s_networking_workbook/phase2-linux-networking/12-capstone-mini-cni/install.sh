#!/usr/bin/env bash
# ============================================================================
# install.sh a|b [plugin-file] — put a plugin and its config where a runtime
# looks for them.
#   a → node subnet 10.244.1.0/24     b → node subnet 10.244.2.0/24
#   plugin-file defaults to ./skeleton/lab-cni (your work); pass
#   ./reference/lab-cni to use the reference implementation.
#   MTU=1450 bash install.sh a   for the VXLAN milestone.
# ============================================================================
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
side=${1:?usage: install.sh a|b [plugin-file]}
plugin=${2:-$DIR/skeleton/lab-cni}
case "$side" in a) n=1 ;; b) n=2 ;; *) echo "side must be a or b"; exit 1 ;; esac

install -D -m 0755 "$plugin" /opt/cni/bin/lab-cni
mkdir -p /etc/cni/net.d
cat > /etc/cni/net.d/10-lab.conf <<EOF
{
  "cniVersion": "1.0.0",
  "name": "labnet",
  "type": "lab-cni",
  "bridge": "cni0",
  "subnet": "10.244.$n.0/24",
  "clusterCIDR": "10.244.0.0/16",
  "mtu": ${MTU:-1500}
}
EOF
echo "installed $(basename "$plugin") → /opt/cni/bin/lab-cni; config → /etc/cni/net.d/10-lab.conf (subnet 10.244.$n.0/24, mtu ${MTU:-1500})"
