#!/usr/bin/env bash
# install-calico.sh — Calico v3.33.0 (same manifest as k8slab, ADR-039) on
# kind lab-calico, with the pool set to kind's podSubnet and NO encapsulation:
# nodes share one L2, so pure BGP routing works — the datacenter model.
set -euo pipefail
V=v3.33.0
K="kubectl --context kind-lab-calico"
curl -fsSL "https://raw.githubusercontent.com/projectcalico/calico/$V/manifests/calico.yaml" \
  | sed -e 's|# - name: CALICO_IPV4POOL_CIDR|- name: CALICO_IPV4POOL_CIDR|' \
        -e 's|#   value: "192.168.0.0/16"|  value: "10.244.0.0/16"|' \
        -e '/name: CALICO_IPV4POOL_IPIP/{n;s/"Always"/"Never"/}' > /tmp/lab-calico.yaml
grep -A1 -E 'name: CALICO_IPV4POOL_(CIDR|IPIP|VXLAN)$' /tmp/lab-calico.yaml
$K apply -f /tmp/lab-calico.yaml >/dev/null
# kind nodes inherit the WSL host's rp_filter (2 = loose); Felix refuses to run
# with loose RPF unless told it's acceptable. It is, in a lab.
$K -n kube-system set env ds/calico-node FELIX_IGNORELOOSERPF=true >/dev/null
$K -n kube-system rollout status ds/calico-node --timeout=300s
$K wait --for=condition=Ready node --all --timeout=300s
