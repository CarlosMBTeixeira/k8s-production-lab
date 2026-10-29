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
syncs() { docker exec $1 curl -s localhost:10249/metrics | awk '/^kubeproxy_sync_proxy_rules_duration_seconds_(sum|count)\{ip_family="IPv4"/{printf "%s ", $2} END{print ""}'; }   # "<sum> <count>", IPv4 only
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
docker exec lab-plain-worker iptables-save -t nat | grep -c '^-A KUBE'      # rule count (~45)
syncs lab-plain-worker                                                       # sum count
```

Now 300 more Services and measure again:

```bash
bash many-services.sh 300; sleep 30
docker exec lab-plain-worker iptables-save -t nat | grep -c '^-A KUBE'      # ~11 more per Service
syncs lab-plain-worker
time kubectl -n lab-modes exec client -- curl -s -o /dev/null web-300
```

Record: rules before/after, and two sync times: the average before
(sum/count) and the average **during the scale-up** (Δsum/Δcount between the
two readings). The counters are cumulative, so sum/count after the
scale-up mixes old and new syncs and hides the change.

Expect the per-sync time to barely move (tens of ms on kind). Since
Kubernetes 1.28 the iptables proxier only rewrites the chains that changed
and does a full resync once per `syncPeriod`; the "iptables rewrites
everything on every change" cost is gone. What still grows with the
Service count is the rule list itself, and `KUBE-SERVICES` is matched
linearly on each new connection.
`kind delete cluster --name lab-plain`.

### 2.2 IPVS (`kube-proxy-ipvs.yaml` → `lab-ipvs`)

```bash
kubectl -n kube-system logs ds/kube-proxy | grep -m1 deprecated   # IPVS: off by default in 1.40, removed in 1.43
kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep -A6 '^ipvs:'
dbg lab-ipvs-worker ip -br addr show kube-ipvs0                # one line: state DOWN (a dummy), every ClusterIP as a /32
dbg lab-ipvs-worker ipvsadm -Ln -t $VIP:80                     # virtual server + 3 real servers, "Masq"
dbg lab-ipvs-worker ipset list -n                              # KUBE-CLUSTER-IP, KUBE-LOOP-BACK, …
docker exec lab-ipvs-worker iptables-save -t nat | grep -c '^-A KUBE'   # small and constant
kubectl -n lab-modes exec client -- sh -c 'for i in $(seq 9); do curl -s web | grep Hostname; done'   # strict rotation
```

Scale and measure exactly as in 2.1 (`syncs lab-ipvs-worker`), then count
where the Services went:

```bash
dbg lab-ipvs-worker ipvsadm -Ln | grep -c '^TCP'                          # ~304 virtual servers
dbg lab-ipvs-worker ipset list KUBE-CLUSTER-IP | grep 'Number of entries'  # ~305
dbg lab-ipvs-worker ip -o addr show kube-ipvs0 | wc -l                     # ~303 VIPs on the dummy
```

The iptables rule count doesn't move; ipsets and the virtual-server table
(a hash) grow instead. Per-packet lookup is flat, but the sync is not:
each new Service is a VIP on `kube-ipvs0`, an ipset entry and a virtual
server, programmed one netlink call at a time. On kind, per-sync time
during the scale-up was ~1.5× the baseline and higher than iptables mode's.
The IPVS kernel modules load on demand (`lsmod | grep ip_vs` on the WSL
host afterwards). Also check
strict ARP (lab 2.10 §2.5):
`kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep strictARP`.
MetalLB in L2 mode requires it to be `true` with IPVS.

`kind delete cluster --name lab-ipvs`.

### 2.3 nftables (`kube-proxy-nftables.yaml` → `lab-nft`)

GA since Kubernetes 1.33; the long-term replacement for both.

```bash
docker exec lab-nft-worker nft list tables                     # table ip kube-proxy (and ip6)
docker exec lab-nft-worker nft list map ip kube-proxy service-ips | head   # VIP . proto . port : goto service-…
docker exec lab-nft-worker nft list ruleset 2>/dev/null | grep -A3 'chain service-.*lab-modes/web/tcp/http'   # dnat … numgen random mod 3 map { 0 : <pod> . 80, … }
docker exec lab-nft-worker iptables-save -t nat | grep -c '^-A KUBE'      # ~0: nothing in iptables
```

One map lookup per packet regardless of the number of Services, and
incremental updates: adding a Service adds one map element and one chain.
Scale and measure again (`syncs lab-nft-worker`; count elements with
`nft list map ip kube-proxy service-ips | grep -c ' : goto'`, 5 → 305). Note where iptables-mode tooling now lies to you: `iptables-save` on
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
| §2.1 | KUBE rules ~45 → ~3345 (~11 per Service); per-sync time roughly flat (partial syncs) |
| §2.2 | `kube-ipvs0` holds the VIPs; `ipvsadm` shows `rr` and 3 `Masq` real servers; KUBE iptables rules constant (9); ~304 virtual servers after scaling; per-sync time grows |
| §2.3 | the `service-ips` map has an element for `$VIP . tcp . 80`; 0 KUBE rules in iptables; 305 map elements after scaling; per-sync time flat |

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

- iptables mode walks a rule list per new connection, so the datapath cost grows with the number of Services; since 1.28 its syncs are partial, so control-plane cost grows far less than folklore says. IPVS and nftables use hash/map lookups per packet; nftables also syncs incrementally, IPVS pays per Service in netlink calls and is deprecated (disabled by default in 1.40).
- IPVS needs the VIPs on `kube-ipvs0`, ipsets for masquerade/NodePort matching, and `strictARP` so nodes don't answer ARP for ClusterIPs; it brings real schedulers (rr, lc, sh).
- nftables mode keeps everything in `table ip kube-proxy` with a verdict map; iptables-based tooling sees nothing, so you debug with `nft`.
