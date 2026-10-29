# Lab 4.04 — Cilium BGP control plane

| | |
|---|---|
| **Objective** | Run Cilium in native routing mode, peer it with the fabric through its BGP control plane, and advertise PodCIDRs and LoadBalancer IPs from LB IPAM — the Cilium version of labs 4.02 + 4.03. |
| **Time** | 4 h (week 20) — **first to cut** if behind (4.03 covers the concepts) |
| **Where** | a fresh kind `lab-cilium` + `lib/frr-kind.sh` on the WSL host |
| **Risk** | Safe — disposable cluster |

## 1. Prerequisites

- Labs 3.07, 4.02, 4.03.

```bash
unset KUBECONFIG
cd <workbook>/phase4-bgp-cloud-lb/04-cilium-bgp
kind delete cluster --name lab-cilium 2>/dev/null; kind create cluster --config ../../setup/kind/cilium.yaml
cilium install \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=lab-cilium-control-plane --set k8sServicePort=6443 \
  --set ipam.mode=kubernetes \
  --set routingMode=native --set autoDirectNodeRoutes=true --set ipv4NativeRoutingCIDR=10.244.0.0/16 \
  --set bgpControlPlane.enabled=true
cilium status --wait                               # may return with "pods not ready" — run `cilium status` again a minute later
kubectl api-resources | grep -i ciliumbgp          # cilium.io/v2 — what bgp.yaml.tpl uses (1.20 also still serves v2alpha1)
```

`routingMode=native` + `autoDirectNodeRoutes`: no VXLAN; each node gets
routes to the others' PodCIDRs because they share an L2 — the Calico
"IPIP Never" setup from 4.03, Cilium-style.

## 2. Hands-on

### 2.1 Peer and advertise

```bash
bash ../lib/frr-kind.sh up lab-cilium frr.conf.tpl
export FRR_IP=$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' lab-frr)
kubectl label nodes --all bgp=on
envsubst < bgp.yaml.tpl | kubectl apply -f -
kubectl apply -f web.yaml && kubectl -n lab-cbgp rollout status deploy/web
LB=$(kubectl -n lab-cbgp get svc web -o jsonpath='{.status.loadBalancer.ingress[0].ip}'); echo $LB    # from LB IPAM: 10.203.0.x
cilium bgp peers                                           # per node: peer, state, uptime, families
cilium bgp routes advertised ipv4 unicast                  # what each node sends
kubectl get ciliumbgpnodeconfigs -o yaml | grep -A6 'status:' | head -30
docker exec lab-frr vtysh -c 'show bgp ipv4 unicast'       # 10.244.x.0/24 per node + $LB/32 ×3
docker exec lab-client curl -s -m3 http://$LB/ | grep Hostname
```

Unlike MetalLB in 4.02, Cilium also advertises the LB IP from the control
plane, so you get three paths, not two. Each node advertises only its own
PodCIDR and Service routes; there is no mesh re-exporting other nodes'
routes as in 4.03. `Received 4` per node is FRR sending the whole table
back; the nodes drop it on their own AS.

### 2.2 The object model

| Object | Answers |
|---|---|
| `CiliumBGPClusterConfig` | which nodes speak BGP, as which ASN, to which peers |
| `CiliumBGPPeerConfig` | how to talk to a peer: timers, auth, graceful restart, which families, which advertisements (by label) |
| `CiliumBGPAdvertisement` | what to announce: PodCIDR, Service LoadBalancerIP/ClusterIP/ExternalIP, by Service selector |
| `CiliumBGPNodeConfig` | generated per node — its status is where per-node session state lives |
| `CiliumLoadBalancerIPPool` | where LB IPs come from (allocation), independent of who advertises them |

Same two halves as MetalLB in 4.02: allocation (pool) and announcement
(advertisement) — plus the selector glue between the objects, which is
where Cilium BGP configs usually break.

### 2.3 Local, and a node going away

```bash
kubectl -n lab-cbgp patch svc web -p '{"spec":{"externalTrafficPolicy":"Local"}}'
sleep 5; docker exec lab-frr vtysh -c "show bgp ipv4 unicast $LB/32" | grep from   # only nodes with a web pod
kubectl -n lab-cbgp get pods -o wide
docker exec lab-client sh -c "for i in \$(seq 20); do curl -s -m1 -o /dev/null -w '%{http_code} ' http://$LB/; done"; echo   # 20 × 200
```

Unlike 4.03, nothing re-exports here: the /32 really comes only from the
nodes with an endpoint, and every request works.

Now a node with a web pod goes silent. One line per second shows the BGP
paths on lab-frr and how many of 4 requests worked:

```bash
tl() { T0=$(date +%s); for i in $(seq $1); do
  P=$(docker exec lab-frr vtysh -c "show bgp ipv4 unicast $LB/32" | grep -o '[0-9] available')
  OK=0; for j in 1 2 3 4; do docker exec lab-client curl -s -m1 http://$LB/ >/dev/null && OK=$((OK+1)); done
  echo "$(( $(date +%s)-T0 ))s paths=$P ok=$OK/4"; done | uniq -f1 -c; }
docker pause lab-cilium-worker; tl 40; docker unpause lab-cilium-worker
```

Measured: the path is withdrawn at ~7 s (hold time 9 s, set in the
PeerConfig), and every request works after that. Under `Local`, the
outage is the hold time, because each remaining path leads to a node with
a live local endpoint.

Repeat under `Cluster`:

```bash
sleep 20; kubectl -n lab-cbgp patch svc web -p '{"spec":{"externalTrafficPolicy":"Cluster"}}'; sleep 15
docker pause lab-cilium-worker; tl 70; docker unpause lab-cilium-worker
```

Measured: the path is withdrawn at ~12 s, but failures continue until
~49 s. Each surviving node still load-balances to the pod on the paused
node until Kubernetes stops listing it as an endpoint (the node
controller's 50 s grace period), as in 4.02 §2.5. BGP timers and BFD only
shorten the first part. `Local` avoids the second part: a node never sends
the traffic to another node's pod.

## 3. Verification

| Check | Expected |
|---|---|
| §2.1 | `cilium bgp peers`: every node Established with `FRR_IP`; FRR has 3 PodCIDRs and `$LB/32`; lab-client gets an answer |
| §2.3 | Local → 2 paths, 20/20; pause under Local → withdrawn at ≤ 9 s, then all OK; under Cluster → withdrawn ~12 s, failures until ~50 s (endpoints) |

## 4. Break/fix

Needs §2.1's setup.

```bash
bash break.sh
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

**Done when** `docker exec lab-client curl -s -m3 http://$LB/` answers and
FRR shows sessions from all three nodes.

<details><summary>Hint (only after 20 minutes)</summary>

FRR has no neighbors at all. Which object decides which nodes run BGP?
</details>

Solution: [`solution.md`](solution.md).

## 5. Cleanup

```bash
bash ../lib/frr-kind.sh down lab-cilium
kind delete cluster --name lab-cilium
```

## 6. What I should be able to explain after this

- Cilium's BGP control plane: ClusterConfig (who/ASN/peers) → PeerConfig (how, which families/advertisements) → Advertisement (what), with per-node state in CiliumBGPNodeConfig; LB IPAM allocates, BGP announces.
- Native routing with auto direct node routes removes the overlay when nodes share an L2; BGP extends that to routed fabrics by advertising PodCIDRs.
- Hold timers set failover time on a silent node failure; tune them per peer (or use BFD where supported) — and with `Cluster` policy the dead node's pods stay endpoints for ~50 s anyway; `Local` makes the BGP withdrawal the whole outage.
