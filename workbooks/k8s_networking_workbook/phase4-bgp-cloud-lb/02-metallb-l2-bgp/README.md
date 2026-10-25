# Lab 4.02 — MetalLB: L2 vs BGP

| | |
|---|---|
| **Objective** | Give LoadBalancer Services an external IP with MetalLB twice — ARP-announced on the node network, then BGP-advertised to an upstream router — and measure what each does on failure. |
| **Time** | 5 h (week 19) |
| **Where** | kind `lab-plain` + `lib/frr-kind.sh` (FRR router and an outside client) on the WSL host |
| **Risk** | Safe — disposable cluster and containers |

k8slab runs MetalLB in L2 mode for its Gateways (ADR-023). This lab is
that, taken apart, plus the BGP mode production clusters usually use.

## 1. Prerequisites

- Labs 2.02 (ARP), 3.02 (externalTrafficPolicy), 4.01 (BGP).

```bash
unset KUBECONFIG
cd <workbook>/phase4-bgp-cloud-lb/02-metallb-l2-bgp
kind create cluster --config ../../setup/kind/plain.yaml
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.16.1/config/manifests/metallb-native.yaml
kubectl -n metallb-system wait --for=condition=Available deploy/controller --timeout=180s
kubectl -n metallb-system wait --for=condition=Ready pod -l component=speaker --timeout=180s
KIND_NET=$(docker network inspect kind | jq -r '.[0].IPAM.Config[] | select(.Subnet | test("\\.")) | .Subnet')
export L2_START=$(echo $KIND_NET | awk -F. '{print $1"."$2".255.200"}') L2_STOP=$(echo $KIND_NET | awk -F. '{print $1"."$2".255.210"}')
```

(v0.16.1 is the version k8slab pins, ADR-039.)

## 2. Hands-on

### 2.1 L2 mode

```bash
envsubst < metallb-l2.yaml.tpl | kubectl apply -f -
kubectl apply -f web.yaml && kubectl -n lab-lb rollout status deploy/web
LB=$(kubectl -n lab-lb get svc web -o jsonpath='{.status.loadBalancer.ingress[0].ip}'); echo $LB
curl -s http://$LB/ | grep Hostname                       # from the WSL host, on the same L2 (the kind bridge)
docker run --rm --network kind nicolaka/netshoot:v0.13 arping -c3 $LB    # one MAC answers
for n in $(kind get nodes --name lab-plain); do echo "$n $(docker inspect -f '{{(index .NetworkSettings.Networks "kind").MacAddress}}' $n)"; done
kubectl -n lab-lb get events --field-selector involvedObject.name=web | grep -i announc   # "announcing from node …"
```

One speaker owns the IP and answers ARP for it. All traffic for the
Service enters through that one node, then kube-proxy spreads it — L2 mode
is failover, not load balancing.

### 2.2 L2 failover, measured

```bash
OWNER=<the node that announces $LB>
( while true; do curl -s -m1 http://$LB/ >/dev/null && echo -n . || echo -n X; sleep 0.2; done ) &
sleep 3; docker pause $OWNER; sleep 20; docker unpause $OWNER; sleep 3; kill %1; echo
```

Count the `X`s × 0.2 s. MetalLB's memberlist must notice the node is gone,
another speaker takes over and sends gratuitous ARP; clients that ignore
GARP keep the stale MAC until their ARP cache expires. Try it once more
with `ip neigh` on the client side (`docker run --rm -it --network kind nicolaka/netshoot:v0.13`)
to watch the MAC change.

### 2.3 L2 + externalTrafficPolicy: Local

```bash
kubectl -n lab-lb patch svc web -p '{"spec":{"externalTrafficPolicy":"Local"}}'
kubectl -n lab-lb scale deploy/web --replicas=1; sleep 5
kubectl -n lab-lb get pods -o wide; kubectl -n lab-lb get events --field-selector involvedObject.name=web | tail -3
curl -s http://$LB/ | grep -E 'Hostname|RemoteAddr'      # client IP preserved; the announcer moved to the pod's node
kubectl -n lab-lb patch svc web -p '{"spec":{"externalTrafficPolicy":"Cluster"}}'; kubectl -n lab-lb scale deploy/web --replicas=3
```

### 2.4 BGP mode

```bash
kubectl -n metallb-system delete l2advertisement l2; kubectl -n metallb-system delete ipaddresspool l2-pool
bash ../lib/frr-kind.sh up lab-plain frr.conf.tpl          # prints FRR_IP
export FRR_IP=$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' lab-frr)
envsubst < metallb-bgp.yaml.tpl | kubectl apply -f -
kubectl -n lab-lb delete svc web && kubectl apply -f web.yaml     # re-allocate from the BGP pool
LB=$(kubectl -n lab-lb get svc web -o jsonpath='{.status.loadBalancer.ingress[0].ip}'); echo $LB   # 10.200.0.x
docker exec lab-frr vtysh -c 'show bgp summary'                          # 3 dynamic neighbors (*), Established
docker exec lab-frr vtysh -c "show bgp ipv4 unicast $LB/32"              # 3 paths, multipath
docker exec lab-frr ip route show $LB                                    # ECMP: nexthop via 3 node IPs
docker exec lab-client sh -c "for i in \$(seq 9); do curl -s $LB | grep Hostname; done"
```

`lab-client` is on another network: it reaches `$LB` only because FRR
learned a route. ECMP spreads **flows** across nodes by hash — real load
balancing at the fabric. The address exists on no interface anywhere.

### 2.5 BGP failure and Local

```bash
kubectl -n lab-lb patch svc web -p '{"spec":{"externalTrafficPolicy":"Local"}}'
kubectl -n lab-lb scale deploy/web --replicas=1; sleep 5
docker exec lab-frr vtysh -c "show bgp ipv4 unicast $LB/32"     # one path: nodes without endpoints withdrew
kubectl -n lab-lb scale deploy/web --replicas=3; kubectl -n lab-lb patch svc web -p '{"spec":{"externalTrafficPolicy":"Cluster"}}'

W=lab-plain-worker
( while true; do docker exec lab-client curl -s -m1 http://$LB/ >/dev/null && echo -n . || echo -n X; sleep 0.5; done ) &
sleep 3; docker pause $W; sleep 100; docker unpause $W; kill %1; echo
```

A paused node keeps its BGP session "up" until the **hold timer** expires
(MetalLB default 90 s), so roughly a third of new flows keep hashing to a
dead next hop. That's the case for BFD — supported by MetalLB's FRR mode
(`BFDProfile`), not by this native mode. Write down the outage you measured.

## 3. Verification

| Check | Expected |
|---|---|
| §2.1 | `$LB` in the l2 range; one MAC replies to arping; curl works from the WSL host |
| §2.2 | a short burst of X, then dots again from another node |
| §2.4 | FRR: 3 Established dynamic neighbors, `$LB/32` with 3 next hops; lab-client gets answers |
| §2.5 | Local + 1 replica → 1 path; node pause → partial outage for ~hold time |

## 4. Break/fix

Needs §2.4's setup (lab-plain + MetalLB + `frr-kind.sh` up).

```bash
bash break.sh
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

**Done when** `docker exec lab-client curl -s -m3 http://<EXTERNAL-IP>/` answers.

<details><summary>Hint (only after 20 minutes)</summary>

Sessions are Established, so this isn't 4.01's problem. Count the prefixes
FRR receives, then ask MetalLB what it was told to advertise.
</details>

Solution: [`solution.md`](solution.md).

## 5. Cleanup

```bash
bash ../lib/frr-kind.sh down lab-plain
kind delete cluster --name lab-plain       # or keep it for 4.06
```

## 6. What I should be able to explain after this

- L2 mode: one elected speaker answers ARP for each IP; failover = memberlist detection + gratuitous ARP; one node takes all ingress — high availability, not load balancing.
- BGP mode: every eligible node advertises a /32; the router ECMPs flows across them; `externalTrafficPolicy: Local` makes nodes without endpoints withdraw.
- BGP failover is bounded by the hold timer unless BFD is on; L2 failover is bounded by detection plus clients honouring GARP.
