# Lab 3.03 — kube-proxy IPVS and nftables modes

| | |
|---|---|
| **Objective** | Implement the same Service with kube-proxy in iptables, IPVS and nftables modes, read each datapath, and measure how each scales with hundreds of Services. |
| **Time** | 5 h (week 11) |
| **Where** | kind on the WSL host: `lab-plain`, `lab-ipvs`, `lab-nft` — one at a time |
| **Risk** | Safe — disposable kind clusters |

## 1. Prerequisites

- Labs 2.10, 3.02. k8slab can stay down; this lab runs on kind.

```bash
unset KUBECONFIG
cd <workbook>/phase3-k8s-networking/03-kube-proxy-modes
dbg() { docker run --rm -i --net container:$1 --privileged nicolaka/netshoot:v0.13 "${@:2}"; }   # tools in a node's netns
```

For each mode, the same bring-up:

```bash
kind create cluster --config ../../setup/kind/<file>.yaml
kubectl apply -f web.yaml && kubectl -n lab-modes rollout status deploy/web
kubectl -n lab-modes wait --for=condition=Ready pod/client
VIP=$(kubectl -n lab-modes get svc web -o jsonpath='{.spec.clusterIP}')
```

## 2. Hands-on

### 2.1 Baseline: iptables (`plain.yaml` → `lab-plain`)

```bash
kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep '^mode'
docker exec lab-plain-worker iptables-save -t nat | grep -c '^-A KUBE'      # rule count
docker exec lab-plain-worker curl -s localhost:10249/metrics | grep -E '^kubeproxy_sync_proxy_rules_duration_seconds_(sum|count)'
```

Now 300 more Services and measure again:

```bash
bash many-services.sh 300; sleep 30
docker exec lab-plain-worker iptables-save -t nat | grep -c '^-A KUBE'
docker exec lab-plain-worker curl -s localhost:10249/metrics | grep -E '^kubeproxy_sync_proxy_rules_duration_seconds_(sum|count)'
time kubectl -n lab-modes exec client -- curl -s -o /dev/null web-300
```

Record: rules before/after, average sync time (sum/count) before/after.
`kind delete cluster --name lab-plain`.

### 2.2 IPVS (`kube-proxy-ipvs.yaml` → `lab-ipvs`)

```bash
kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep -A6 '^ipvs:'
dbg lab-ipvs-worker ip -br addr show kube-ipvs0 | head -3      # every ClusterIP, as a local /32
dbg lab-ipvs-worker ipvsadm -Ln -t $VIP:80                     # virtual server + 3 real servers, "Masq"
dbg lab-ipvs-worker ipset list -n                              # KUBE-CLUSTER-IP, KUBE-LOOP-BACK, …
docker exec lab-ipvs-worker iptables-save -t nat | grep -c '^-A KUBE'   # small and constant
kubectl -n lab-modes exec client -- sh -c 'for i in $(seq 9); do curl -s web | grep Hostname; done'   # strict rotation
```

Scale and measure exactly as in 2.1. The iptables rule count barely moves;
ipsets grow instead, and the virtual-server table is a hash. Also check
strict ARP (lab 2.10 §2.5):
`kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep strictARP`.
MetalLB in L2 mode requires it to be `true` with IPVS.

`kind delete cluster --name lab-ipvs`.

### 2.3 nftables (`kube-proxy-nftables.yaml` → `lab-nft`)

GA since Kubernetes 1.33; the long-term replacement for both.

```bash
docker exec lab-nft-worker nft list tables                     # table ip kube-proxy (and ip6)
docker exec lab-nft-worker nft list map ip kube-proxy service-ips | head   # VIP . proto . port : goto service-…
docker exec lab-nft-worker nft list ruleset | grep -A6 'chain service-.*lab-modes/web/tcp/http'   # numgen random mod 3 vmap
docker exec lab-nft-worker iptables-save -t nat | grep -c '^-A KUBE'      # ~0: nothing in iptables
```

One map lookup per packet regardless of the number of Services, and
incremental updates instead of rewriting the whole table. Scale and measure
again. Note where iptables-mode tooling now lies to you: `iptables-save` on
this node shows nothing about Services (lab 2.04's lesson, on a real node).

### 2.4 Your comparison

| | iptables | IPVS | nftables |
|---|---|---|---|
| Rules/objects for 1 Service | | | |
| …for 301 Services | | | |
| Avg sync time, 1 → 301 Services | | | |
| Load-balancing algorithm | random (cascade) | rr/lc/sh/… | random (numgen) |
| Where to look on a node | `iptables-save -t nat` | `ipvsadm -Ln`, `ipset` | `nft list table ip kube-proxy` |

Fill it from your measurements. This table is a reference-track blog post.

## 3. Verification

| Check | Expected |
|---|---|
| §2.1 | KUBE rules grow by several per Service; sync time grows |
| §2.2 | `kube-ipvs0` holds the VIPs; `ipvsadm` shows 3 real servers; KUBE iptables rules stay roughly constant |
| §2.3 | the `service-ips` map has an element for `$VIP . tcp . 80`; no KUBE-SVC chains in iptables |

## 4. Break/fix

Runs against a fresh `lab-ipvs` cluster.

```bash
kind create cluster --config ../../setup/kind/kube-proxy-ipvs.yaml   # if not up
bash break.sh
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

**Done when** 30 requests from `client` spread across all three web pods,
and you changed one setting.

<details><summary>Hint (only after 20 minutes)</summary>

Two different settings produce this symptom. One lives on the Service, the
other doesn't.
</details>

Solution: [`solution.md`](solution.md).

## 5. Cleanup

```bash
kind delete cluster --name lab-plain; kind delete cluster --name lab-ipvs; kind delete cluster --name lab-nft
```

## 6. What I should be able to explain after this

- iptables mode walks a rule list per new connection and rewrites the whole table on each sync, so cost grows with the number of Services; IPVS and nftables use hash/map lookups and scale flat.
- IPVS needs the VIPs on `kube-ipvs0`, ipsets for masquerade/NodePort matching, and `strictARP` so nodes don't answer ARP for ClusterIPs; it brings real schedulers (rr, lc, sh).
- nftables mode keeps everything in `table ip kube-proxy` with a verdict map; iptables-based tooling sees nothing, so you debug with `nft`.
