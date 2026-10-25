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
calicoctl get ippool -o wide            # check: ENCAPSULATION none
bird() { kubectl -n kube-system exec $(kubectl -n kube-system get pod -l k8s-app=calico-node --field-selector spec.nodeName=$1 -o name) -c calico-node -- birdcl -s /var/run/calico/bird.ctl "${@:2}"; }
```

## 2. Hands-on

### 2.1 Routing without a tunnel

```bash
bird lab-calico-worker show protocols                        # Mesh_<ip> to every other node
docker exec lab-calico-worker ip route | grep bird           # other nodes' /26 via their node IP — no tunl0
kubectl apply -f web.yaml && kubectl -n lab-bgp rollout status deploy/web
```

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
docker exec lab-frr vtysh -c 'show bgp ipv4 unicast'          # pod /26 blocks, 10.96.0.0/16 (x3, ECMP), 10.202.0.10/32 or /24
bird lab-calico-worker show protocols                         # Mesh_* plus Node_<FRR_IP> / global peer
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
sleep 5; docker exec lab-frr vtysh -c 'show bgp ipv4 unicast 10.202.0.10/32'   # /32 only from nodes with a web pod
kubectl -n lab-bgp get pods -o wide
kubectl -n lab-bgp patch svc web -p '{"spec":{"externalTrafficPolicy":"Cluster"}}'
```

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
| §2.1 | `ip route` shows `10.244.x.0/26 via <node IP> proto bird`, no tunl0 |
| §2.2 | FRR has pod blocks, 10.96.0.0/16 with 3 paths, 10.202.0.x; lab-client reaches pod IP, ClusterIP and external IP |
| §2.3 | Local → /32 only from nodes with endpoints |
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

- Calico in BGP mode without encapsulation: per-node blocks advertised by BIRD; works on a flat L2 or when the fabric learns the routes; `serviceClusterIPs` / `serviceExternalIPs` / `serviceLoadBalancerIPs` advertise Services, with `/32`s only from nodes with endpoints under `Local`.
- Full mesh vs route reflectors: N² sessions vs N; an RR needs a `routeReflectorClusterID`, otherwise it's just another iBGP peer that won't re-advertise iBGP-learned routes.
- eBGP loop prevention (own AS in the path) is why routes bounced back from the fabric don't paper over a broken iBGP design.
