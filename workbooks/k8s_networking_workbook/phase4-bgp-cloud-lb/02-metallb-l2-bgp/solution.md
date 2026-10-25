# Lab 4.02 — solution

## What was injected

<!--FAULT-->
```bash
export KUBECONFIG="$HOME/.kube/config"
K="kubectl --context kind-lab-plain"
$K -n metallb-system get deploy controller >/dev/null || { echo "MetalLB not installed on lab-plain"; exit 1; }
docker inspect lab-frr >/dev/null 2>&1 || { echo "lab-frr not running: bash ../lib/frr-kind.sh up lab-plain frr.conf.tpl"; exit 1; }
FRR_IP=$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' lab-frr)
$K -n metallb-system delete l2advertisement --all >/dev/null 2>&1 || true
$K -n metallb-system delete bgpadvertisement --all >/dev/null 2>&1 || true
$K -n metallb-system delete ipaddresspool --all >/dev/null 2>&1 || true
$K delete ns lab-lb --ignore-not-found --wait=true >/dev/null
# --- the fault ---
$K apply -f - >/dev/null <<YAML
apiVersion: metallb.io/v1beta2
kind: BGPPeer
metadata: {name: lab-frr, namespace: metallb-system}
spec: {myASN: 64512, peerASN: 65000, peerAddress: ${FRR_IP}}
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: {name: bgp-pool-v2, namespace: metallb-system}
spec: {addresses: ["10.200.0.0/28"]}
---
apiVersion: metallb.io/v1beta1
kind: BGPAdvertisement
metadata: {name: bgp, namespace: metallb-system}
spec: {ipAddressPools: [bgp-pool]}
YAML
$K apply -f "$LAB_DIR/web.yaml" >/dev/null
$K -n lab-lb rollout status deploy/web --timeout=120s >/dev/null
sleep 5
LB=$($K -n lab-lb get svc web -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
cat <<T

TICKET  After the "pool cleanup" in metallb-system, web in lab-lb has
        EXTERNAL-IP ${LB:-<pending?>}, all 3 BGP sessions on lab-frr are
        Established, but from outside:
          docker exec lab-client curl -m3 http://${LB}/    → timeout
T
```
<!--/FAULT-->

The pool was "renamed" to `bgp-pool-v2` (the Service got its IP from it),
but the BGPAdvertisement still lists `bgp-pool`. MetalLB allocates from a
pool without needing an advertisement, so the Service looks perfect — and
nothing advertises its IP. Sessions stay Established with zero prefixes.

## Diagnosis path

| Beat | Answer |
|---|---|
| Hypothesis | IP assigned + sessions up + unreachable → the route never reached FRR. |
| Tool | `docker exec lab-frr vtysh -c 'show bgp summary'` |
| Expected if right | neighbors Established, `PfxRcd` 0. |
| Tool 2 | `kubectl -n metallb-system get ipaddresspool,bgpadvertisement -o yaml \| grep -E 'name:\|ipAddressPools\|addresses' ` |
| Expected if right | the Service's IP is in `bgp-pool-v2`; the advertisement names `bgp-pool` (which doesn't exist). |
| Tool 3 | `kubectl -n metallb-system logs -l component=speaker --tail=50 \| grep -i -E 'advertis\|withdraw'` |
| Expected if right | no "advertising" lines for the Service's IP. |
| What would have told me sooner | Check **both** halves of a LoadBalancer: allocation (`status.loadBalancer`) and announcement (router's received prefixes / MetalLB's `metallb_bgp_announced_prefixes_total`). A Service that has an IP is only half working. |

## Fix

```bash
kubectl -n metallb-system patch bgpadvertisement bgp --type merge -p '{"spec":{"ipAddressPools":["bgp-pool-v2"]}}'
sleep 3; docker exec lab-frr vtysh -c 'show bgp ipv4 unicast'
docker exec lab-client curl -s -m3 http://$(kubectl -n lab-lb get svc web -o jsonpath='{.status.loadBalancer.ingress[0].ip}')/ | grep Hostname
```

## Why it matters later

Same split for every LB implementation: Calico (IPPool vs BGPConfiguration
`serviceLoadBalancerIPs`), Cilium (LB IPAM pool vs `CiliumBGPAdvertisement`
selector, lab 4.04). Allocation and advertisement are always two objects.
