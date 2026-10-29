# Lab 4.03 — Calico BGP and advertising Service IPs

| | |
|---|---|
| **Objective** | Run Calico without encapsulation, peer the cluster with an upstream router, advertise pod CIDRs, the Service CIDR and external IPs to it, and replace the node full mesh with route reflectors. |
| **Time** | 5 h (week 20) |
| **Where** | kind `lab-calico` + `lib/frr-kind.sh` on the WSL host |
| **Risk** | Safe on kind. **The same steps on k8slab would be RISKY** (cluster-wide BGPConfiguration; a mistake cuts cross-node pod traffic) — that's why this lab is on kind. |

## 1. Prerequisites

- Labs 3.01 (Calico anatomy), 4.01, 4.02. `calicoctl` v3.33.0.

```bash
unset KUBECONFIG; export DATASTORE_TYPE=kubernetes
cd <workbook>/phase4-bgp-cloud-lb/03-calico-bgp
kind create cluster --config ../../setup/kind/calico.yaml
bash install-calico.sh                  # pool 10.244.0.0/16, IPIP Never
calicoctl get ippool -o wide            # check: IPIPMODE Never, VXLANMODE Never
bird() { kubectl -n kube-system exec $(kubectl -n kube-system get pod -l k8s-app=calico-node --field-selector spec.nodeName=$1 -o name) -c calico-node -- birdcl -s /var/run/calico/bird.ctl "${@:2}"; }
```

## 2. Hands-on

### 2.1 Routing without a tunnel

```bash
kubectl apply -f web.yaml && kubectl -n lab-bgp rollout status deploy/web   # first, so the workers have blocks
bird lab-calico-worker show protocols                        # Mesh_<ip> to every other node
docker exec lab-calico-worker ip route | grep bird           # other nodes' /26 via their node IP — no tunl0
```

Calico gives a node a /26 only when its first pod lands there. Before
`web` exists, the workers may have no block, and the route list is short.
The control plane may have none at all if CoreDNS was scheduled onto the
workers, so expect 2 or 3 blocks, and route counts in §2.4 that vary with
that.
The node's own block shows as `blackhole … proto bird`: a catch-all for
unallocated addresses in the block, while each local pod gets a /32 via its
`cali*` veth. The apply also warns that `spec.externalIPs` is deprecated in
Kubernetes 1.37. Calico still advertises it, but treat externalIPs as
legacy.

Compare with 3.01: same BIRD, same blocks, but next hops are node IPs on
the shared L2 instead of `tunl0`. No MTU overhead, no encapsulation — and
it only works because the nodes are L2-adjacent (or the fabric learns the
routes, next step).

### 2.2 Peer with the fabric

```bash
bash ../lib/frr-kind.sh up lab-calico frr.conf.tpl
export FRR_IP=$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' lab-frr)
envsubst < bgp.yaml.tpl | calicoctl apply -f -
sleep 10
docker exec lab-frr vtysh -c 'show bgp summary'               # 3 neighbors, Established
docker exec lab-frr vtysh -c 'show bgp ipv4 unicast'          # pod /26 blocks, 10.96.0.0/16, 10.202.0.0/24 — each from every node
docker exec lab-frr ip route show $(docker exec lab-calico-worker2 ip route | awk '/blackhole/{print $2}')   # worker2's block
bird lab-calico-worker show protocols                         # Mesh_* plus Global_<FRR_IP>
```

Read FRR's table carefully. Every prefix arrives from **every** node, and
each session carries several copies (`PfxRcd` 9 for 5 prefixes; the
sessions negotiate add-path). Each node exports what it learned over the
mesh too, and BIRD rewrites the next hop to itself on eBGP. So FRR ECMPs
worker2's pod block across all three nodes, and two of every three flows
take an extra hop through a node that doesn't hold the block.
`maximum-paths 8` also caps the Service CIDR at 8 of its 9 paths.

Calico's fix for the extra hop is to keep the originating node as next hop:

```bash
calicoctl patch bgppeer lab-frr -p '{"spec":{"keepOriginalNextHop":true}}'; sleep 10   # resets the FRR sessions
docker exec lab-frr ip route show $(docker exec lab-calico-worker2 ip route | awk '/blackhole/{print $2}')   # one next hop: worker2
docker exec lab-frr ip route show 10.96.0.0/16                                                             # still 3: any node serves a ClusterIP
calicoctl patch bgppeer lab-frr -p '{"spec":{"keepOriginalNextHop":false}}'; sleep 10  # back, for §2.3
```

From outside, now with real routes:

```bash
POD=$(kubectl -n lab-bgp get pod -l app=web -o jsonpath='{.items[0].status.podIP}')
VIP=$(kubectl -n lab-bgp get svc web -o jsonpath='{.spec.clusterIP}')
docker exec lab-client curl -s -m3 http://$POD/ | grep Hostname         # a pod IP, routed from outside the cluster
docker exec lab-client curl -s -m3 http://$VIP/ | grep Hostname         # a ClusterIP, from outside the cluster
docker exec lab-client curl -s -m3 http://10.202.0.10/ | grep Hostname  # externalIPs
```

Advertising ClusterIPs is how some on-prem platforms expose Services
without any LoadBalancer controller at all. Advertising pod CIDRs makes
pods first-class on the network — which also means your fabric must accept
and filter them.

### 2.3 Local vs Cluster, at the routing layer

```bash
kubectl -n lab-bgp patch svc web -p '{"spec":{"externalTrafficPolicy":"Local"}}'
sleep 5; docker exec lab-frr vtysh -c 'show bgp ipv4 unicast 10.202.0.10/32' | grep from   # who advertises the /32
kubectl -n lab-bgp get pods -o wide                                                      # who has a web pod
docker exec lab-frr ip route show 10.202.0.10
docker exec lab-client sh -c 'for i in $(seq 30); do curl -s -m1 -o /dev/null -w "%{http_code} " http://10.202.0.10/; done'; echo
```

Calico originates the `/32` only on the two workers that have a web pod.
FRR still gets it from the control plane as well: the control plane learned
it over the mesh and re-exports it with itself as next hop, as in §2.2. So
FRR ECMPs a third of the flows to a node that has **no local endpoint**.
Under `Local`, kube-proxy there drops them. Measured: 11 of 30 requests
`000`. The same option as §2.2 fixes it:

```bash
calicoctl patch bgppeer lab-frr -p '{"spec":{"keepOriginalNextHop":true}}'; sleep 10
docker exec lab-frr ip route show 10.202.0.10                                            # only the two workers
docker exec lab-client sh -c 'for i in $(seq 30); do curl -s -m1 -o /dev/null -w "%{http_code} " http://10.202.0.10/; done'; echo   # 30 × 200
kubectl -n lab-bgp patch svc web -p '{"spec":{"externalTrafficPolicy":"Cluster"}}'
```

"Only nodes with endpoints advertise the /32" holds where routes are
originated. Any node that re-exports with next-hop-self breaks it again.
That includes a full mesh peering with the fabric: check the next hops,
not just the prefix.

### 2.4 Route reflectors instead of a full mesh

A full mesh is N×(N−1)/2 sessions — fine at 3 nodes, not at 300. Make
`lab-calico-worker` a route reflector:

```bash
calicoctl patch node lab-calico-worker -p '{"spec":{"bgp":{"routeReflectorClusterID":"244.0.0.1"}}}'
kubectl label node lab-calico-worker route-reflector=true
calicoctl apply -f rr.yaml
calicoctl patch bgpconfiguration default -p '{"spec":{"nodeToNodeMeshEnabled":false}}'
sleep 10
for n in lab-calico-control-plane lab-calico-worker lab-calico-worker2; do echo "== $n"; bird $n show protocols | grep -E 'Node_|Mesh_'; done
docker exec lab-calico-worker2 ip route | grep bird           # still every block — reflected by the RR
```

Non-RR nodes now have exactly two sessions (RR + FRR). The cluster ID is
what turns a node from "an iBGP peer" into "a reflector".

## 3. Verification

| Check | Expected |
|---|---|
| §2.1 | `ip route` shows `10.244.x.0/26 via <node IP> proto bird` for the other nodes, own block `blackhole`, no tunl0 |
| §2.2 | FRR has 3 pod blocks, 10.96.0.0/16 and 10.202.0.0/24, each from all 3 nodes; lab-client reaches pod IP, ClusterIP and external IP; `keepOriginalNextHop` → pod block has 1 next hop |
| §2.3 | Local without keepOriginalNextHop → /32 via 3 next hops, ~1/3 of requests `000`; with it → 2 next hops (the workers), 30/30 |
| §2.4 | non-RR nodes peer only with the RR (and FRR); routes complete everywhere |

## 4. Break/fix

```bash
bash break.sh          # rebuilds the BGP setup "the new way" on lab-calico (needs frr-kind up)
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

**Done when** `kubectl -n lab-bgp exec client-w2 -- curl -s -m3 http://<server-cp pod IP>/`
answers and the mesh stays **disabled**.

<details><summary>Hint (only after 20 minutes)</summary>

Compare the routing tables of the three nodes. Who's missing what, and who
should have told them?
</details>

Solution: [`solution.md`](solution.md).

## 5. Cleanup

```bash
bash ../lib/frr-kind.sh down lab-calico
kind delete cluster --name lab-calico      # or keep it for 4.08
```

## 6. What I should be able to explain after this

- Calico in BGP mode without encapsulation: per-node blocks advertised by BIRD; works on a flat L2 or when the fabric learns the routes; `serviceClusterIPs` / `serviceExternalIPs` / `serviceLoadBalancerIPs` advertise Services, with `/32`s originated only on nodes with endpoints under `Local` — and why a mesh re-exporting with next-hop-self undoes that unless the peer keeps the original next hop.
- Full mesh vs route reflectors: N² sessions vs N; an RR needs a `routeReflectorClusterID`, otherwise it's just another iBGP peer that won't re-advertise iBGP-learned routes.
- eBGP loop prevention (own AS in the path) is why routes bounced back from the fabric don't paper over a broken iBGP design.
