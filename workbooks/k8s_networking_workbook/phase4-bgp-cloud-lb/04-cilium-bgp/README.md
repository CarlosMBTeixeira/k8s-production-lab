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
cilium status --wait
kubectl api-resources | grep -i ciliumbgp          # which API version this release serves (edit bgp.yaml.tpl if v2)
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
sleep 5; docker exec lab-frr vtysh -c "show bgp ipv4 unicast $LB/32"   # only nodes with a web pod
kubectl -n lab-cbgp get pods -o wide
( while true; do docker exec lab-client curl -s -m1 http://$LB/ >/dev/null && echo -n . || echo -n X; sleep 0.5; done ) &
sleep 3; docker pause lab-cilium-worker; sleep 20; docker unpause lab-cilium-worker; kill %1; echo
```

With the 9 s hold timer from the PeerConfig, compare the outage to 4.02's
90 s default. Timers are a per-peer knob here.

## 3. Verification

| Check | Expected |
|---|---|
| §2.1 | `cilium bgp peers`: every node Established with `FRR_IP`; FRR has 3 PodCIDRs and `$LB/32`; lab-client gets an answer |
| §2.3 | Local → paths only from nodes with endpoints; outage ≈ hold time (~9 s) |

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
- Hold timers set failover time on a silent node failure; tune them per peer (or use BFD where supported).
