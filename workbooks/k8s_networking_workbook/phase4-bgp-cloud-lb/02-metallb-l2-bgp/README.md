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

The MAC that answers arping is the announcing node's MAC on the kind network.
Only the two workers can win: kind labels its control plane
`node.kubernetes.io/exclude-from-external-load-balancers`, and MetalLB
respects that label.

One speaker owns the IP and answers ARP for it. All traffic for the
Service enters through that one node, then kube-proxy spreads it — L2 mode
is failover, not load balancing.

### 2.2 L2 failover, measured

```bash
OWNER=$(kubectl -n lab-lb get events --field-selector involvedObject.name=web --sort-by=.lastTimestamp \
  | grep announc | tail -1 | grep -o 'node "[^"]*"' | cut -d'"' -f2); echo $OWNER
( while true; do curl -s -m1 http://$LB/ >/dev/null && echo -n . || echo -n X; sleep 0.2; done ) &
sleep 3; docker exec $OWNER tc qdisc add dev eth0 root netem loss 100%     # the node's link dies
sleep 20; docker exec $OWNER tc qdisc del dev eth0 root; sleep 3; kill %1; echo
kubectl -n lab-lb get events --field-selector involvedObject.name=web --sort-by=.lastTimestamp | grep announc | tail -2
ip neigh show $LB                                                          # the WSL host's ARP entry for $LB
```

Each `X` costs about 1.2 s (the 1 s curl timeout plus the sleep); each `.`
about 0.2 s. Measured: a solid run of ~7 X's (~8 s) while memberlist
detects the loss and the other worker takes over with a gratuitous ARP.
Then scattered X's: kube-proxy still DNATs some requests to the pod on the
cut-off node, because that node isn't NotReady yet. When the link comes
back, the IP moves **back** to the original node. MetalLB picks the owner
by a deterministic hash of the node names, so a recovered node takes its IPs
back, and that can cause a second, short interruption.

Why not `docker pause`? It only freezes the node's processes. The node's
kernel keeps answering ARP and forwarding traffic through its iptables
rules, so the IP doesn't move. Only requests that land on the frozen pods
fail, and you get scattered X's from the start. That's a failure mode too:
a node that's hung but still on the network.

### 2.3 L2 + externalTrafficPolicy: Local

```bash
kubectl -n lab-lb patch svc web -p '{"spec":{"externalTrafficPolicy":"Local"}}'
kubectl -n lab-lb scale deploy/web --replicas=1; sleep 5
kubectl -n lab-lb get pods -o wide; kubectl -n lab-lb get events --field-selector involvedObject.name=web | tail -3
curl -s http://$LB/ | grep -E 'Hostname|RemoteAddr'      # RemoteAddr 172.18.0.1 = the WSL host on the kind bridge: client IP preserved; the announcer moved to the pod's node
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
docker exec lab-frr vtysh -c 'show bgp summary'                          # 3 dynamic neighbors (*), Established; the control plane's PfxRcd is 0
docker exec lab-frr vtysh -c "show bgp ipv4 unicast $LB/32"              # 2 paths (the workers), multipath
docker exec lab-frr ip route show $LB                                    # ECMP: nexthop via the 2 worker IPs
docker exec lab-client sh -c "for i in \$(seq 12); do curl -s $LB | grep RemoteAddr; done" | sort | uniq -c
kubectl -n metallb-system logs -l component=speaker --tail=100 | grep 'skipping should announce' | head -1   # why not the control plane
```

`lab-client` is on another network: it reaches `$LB` only because FRR
learned a route. ECMP spreads **flows** across nodes by hash, so the load
balancing happens in the fabric. The address exists on no interface
anywhere. MetalLB hands out the pool's first address, `10.200.0.0`; as a /32
that's a normal host address.

All three nodes have a session, but only the workers advertise. The control
plane carries the `exclude-from-external-load-balancers` label, and the
speaker logs exactly that. `RemoteAddr` shows which node each flow came in
through: a worker's node IP (`172.18.0.x`) or its pod-CIDR gateway
(`10.244.x.1`), because externalTrafficPolicy Cluster SNATs. You should see
both workers. That's only because `frr-kind.sh` sets
`net.ipv4.fib_multipath_hash_policy=1` (hash on the 5-tuple) in lab-frr.
With the Linux default `0`, the hash uses only source and destination IP,
so every flow from a single client goes to the same node. A real fabric
with one big client behaves the same way.

### 2.5 BGP failure and Local

```bash
kubectl -n lab-lb patch svc web -p '{"spec":{"externalTrafficPolicy":"Local"}}'
kubectl -n lab-lb scale deploy/web --replicas=1; sleep 5
docker exec lab-frr vtysh -c "show bgp ipv4 unicast $LB/32"     # one path: nodes without endpoints withdrew
kubectl -n lab-lb scale deploy/web --replicas=3; kubectl -n lab-lb patch svc web -p '{"spec":{"externalTrafficPolicy":"Cluster"}}'

kubectl -n lab-lb rollout status deploy/web; sleep 5
docker exec lab-frr vtysh -c 'show bgp neighbors' | grep -m1 'Hold time is'   # negotiated hold time
W=lab-plain-worker                     # pick the worker with 2 of the 3 pods: kubectl -n lab-lb get pods -o wide
docker pause $W; T0=$(date +%s)
for i in $(seq 75); do
  P=$(docker exec lab-frr vtysh -c "show bgp ipv4 unicast $LB/32" | grep -o '[0-9] available')
  E=$(kubectl -n lab-lb get endpointslice -l kubernetes.io/service-name=web -o json | jq '[.items[].endpoints[] | select(.conditions.ready)] | length')
  OK=0; for j in 1 2 3 4; do docker exec lab-client curl -s -m1 http://$LB/ >/dev/null && OK=$((OK+1)); done
  echo "$(( $(date +%s)-T0 ))s paths=$P ready_eps=$E ok=$OK/4"
done | uniq -f1 -c
docker unpause $W
```

One line per second: BGP paths on lab-frr, ready endpoints, and how many of
4 requests worked. Measured with 2 of the 3 pods on the paused worker:

| t | paths | ready endpoints | ok | Why |
|---|---|---|---|---|
| 0–9 s | 2 | 3 | 1–3/4 | the session looks up; half the flows hash to the frozen node |
| ~9–11 s | 1 | 3 | | **hold timer** expires, lab-frr withdraws the path |
| 11–50 s | 1 | 3 | 0–3/4 | the remaining worker still DNATs 2 of 3 flows to the frozen pods |
| ~51 s | 1 | 1 | 4/4 | node controller marks the node unreachable (50 s grace), endpoints go not-ready |

The hold time is **9 s**, not MetalLB's default 90 s. BGP negotiates the
lower of the two proposals, and lab-frr runs `frr defaults datacenter`
(3/9 s). With a 90 s router you'd see the first row last 90 s. That part is
what BFD fixes, and MetalLB supports BFD only in its FRR mode
(`BFDProfile`), not in this native mode. BFD does nothing for rows 3–4:
those are Kubernetes' node failure detection. A dead node's pods stay
endpoints until the node controller gives up on it. Write down both numbers
you measured.

## 3. Verification

| Check | Expected |
|---|---|
| §2.1 | `$LB` in the l2 range; one worker's MAC replies to arping; curl works from the WSL host |
| §2.2 | ~8 s of X, scattered X until the endpoints settle, the other worker announcing; the IP moves back after recovery |
| §2.4 | FRR: 3 Established dynamic neighbors (control plane PfxRcd 0), `$LB/32` with 2 next hops; lab-client answered via both workers |
| §2.5 | Local + 1 replica → 1 path; node pause → path withdrawn at ~9 s (hold), full recovery at ~51 s (endpoints) |

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
- BGP failover is bounded by the hold timer (the lower of both sides' proposals) unless BFD is on; L2 failover is bounded by memberlist detection plus clients honouring GARP. In both, a dead node's pods stay Service endpoints until the node controller's grace period (~50 s) — the longer half of the outage.
