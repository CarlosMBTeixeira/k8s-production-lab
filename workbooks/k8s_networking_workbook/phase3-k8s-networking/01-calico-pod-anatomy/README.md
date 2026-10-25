# Lab 3.01 — Calico pod networking anatomy

| | |
|---|---|
| **Objective** | Map every hop of a pod-to-pod packet on k8slab's Calico — pod eth0, `cali*` veth with proxy-ARP, per-pod /32 routes, BIRD-learned block routes, `tunl0` IP-in-IP — and find a real addressing bug in this lab. |
| **Time** | 5 h (week 10) |
| **Where** | k8slab, 2 workers, option 0 · WSL host + `ssh w-1` / `ssh w-2` |
| **Risk** | Hands-on is read-only. The break/fix adds an nftables table on **worker-2** (RISKY, see §4). |

## 1. Prerequisites

- Phase 2, especially 2.01 (veth by PID), 2.03 (routing), 2.08 (overlays).
- `export KUBECONFIG=~/k8slab/kubernetes/admin.conf`; `calicoctl version` works from the WSL host
  (`export DATASTORE_TYPE=kubernetes` once per shell).

```bash
kubectl apply -f pods.yaml
kubectl -n lab-anatomy get pods -o wide        # note each pod's IP and node
C='kubectl -n lab-anatomy exec client --'
REMOTE=$(kubectl -n lab-anatomy get pod server-remote -o jsonpath='{.status.podIP}')
LOCAL=$(kubectl -n lab-anatomy get pod server-local  -o jsonpath='{.status.podIP}')
```

## 2. Hands-on

### 2.1 The pod's view

```bash
$C ip -br addr           # eth0@ifN, a 192.168.x.y/32 — a /32, not a subnet
$C ip route              # default via 169.254.1.1 dev eth0 ; 169.254.1.1 dev eth0 scope link
$C ping -c1 $REMOTE >/dev/null; $C ip neigh   # 169.254.1.1 lladdr ee:ee:ee:ee:ee:ee
$C ip link show eth0 | grep -o 'mtu [0-9]*'   # 1480 — why not 1500?
```

Write down before reading on: who owns 169.254.1.1? (Nobody. No interface
anywhere has that address.)

### 2.2 The node's view (worker-1)

```bash
IDX=$($C cat /sys/class/net/eth0/iflink)       # works here: the container mounted its own /sys
ssh w-1 "ip -o link | grep \"^$IDX:\""         # caliXXXXXXXXXXX@ifN — the host side
CALI=<that name>
ssh w-1 "ip -d link show $CALI; cat /proc/sys/net/ipv4/conf/$CALI/proxy_arp"   # ee:ee:ee:ee:ee:ee, proxy_arp=1
ssh w-1 "ip route | grep -E 'cali|tunl0|blackhole'"
```

Read the routes:

| Route | Means |
|---|---|
| `192.168.a.b dev caliX scope link` | one /32 per local pod: the node routes to pods, it doesn't bridge them |
| `blackhole 192.168.a.0/26 proto 80` | this node's IPAM block; anything in it that isn't a live pod is dropped here |
| `192.168.c.0/26 via <w-2 IP> dev tunl0 proto bird onlink` | worker-2's block, learned over BGP, sent IP-in-IP |

The pod ARPs for 169.254.1.1; the `cali` veth answers with its own MAC
because `proxy_arp=1` answers for any address the node has a route to. The
node then **routes**. No bridge, no `cni0`.

### 2.3 IPAM: blocks and pools

```bash
calicoctl get ippool -o wide           # 192.168.0.0/16, IPIP Always, natOutgoing true, blockSize 26
calicoctl ipam show --show-blocks      # which /26 belongs to which node, how full
kubectl get blockaffinities.crd.projectcalico.org
```

A /26 per node holds 64 pod IPs; a node that runs out borrows a block from
the pool. That's why one node can have routes for several blocks.

### 2.4 Who told worker-1 about worker-2's block

```bash
kubectl -n kube-system get pods -l k8s-app=calico-node -o wide
P=<calico-node pod on worker-1>
kubectl -n kube-system exec $P -c calico-node -- birdcl -s /var/run/calico/bird.ctl show protocols
kubectl -n kube-system exec $P -c calico-node -- birdcl -s /var/run/calico/bird.ctl show route
```

Every node runs BIRD in a full mesh (`Mesh_<ip>`, state `Established`) and
announces its blocks. Calico in IPIP mode is **BGP for routes plus IP-in-IP
for the data**. Phase 4 replaces the mesh with route reflectors and peers it
with an external router.

### 2.5 The packet on the wire

```bash
UP=$(ssh w-1 "ip -o route show default | awk '{print \$5}'")
ssh w-1 "sudo timeout 10 tcpdump -nni $UP -c4 ip proto 4" &
$C ping -c2 $REMOTE
wait
```

Expected: `<w-1 IP> > <w-2 IP>: <pod IP> > <remote pod IP>: ICMP echo request … (ipip-proto-4)`.
Outer header node→node, inner header pod→pod: 20 bytes of overhead, hence
the 1480 MTU. Now ping `$LOCAL` (same node) with a capture on `$UP`: nothing,
because same-node traffic goes `cali → node → cali` and never touches the NIC.

### 2.6 Egress

```bash
ssh w-1 "sudo timeout 8 tcpdump -nni $UP -c2 'tcp port 80 and host 1.1.1.1'" &
$C curl -s -o /dev/null -m5 http://1.1.1.1
wait
ssh w-1 "sudo iptables -t nat -S | grep -A3 cali-nat-outgoing"
```

Source on the wire is worker-1's IP: `natOutgoing: true` masquerades pod
traffic whose destination is **outside every IPPool**.

### 2.7 A real bug in this lab

The pod CIDR is `192.168.0.0/16` (ADR-016). Find every 192.168.x.x network
your pods might need to reach:

```bash
ip -4 -br addr | grep 192.168          # on the WSL host: virbr0 192.168.122.1/24
```

```bash
$C ping -c2 -W2 10.215.138.1           # the WSL host's address on the VM bridge: works
$C ping -c2 -W2 192.168.122.1          # the same host, another address: predict
```

Explain it with §2.3 and §2.6 before reading on. 192.168.122.1 is inside
the IPPool, so Calico treats it as a pod address: **no masquerade**. The
host receives a packet from a pod IP it has no route back to and replies
out its default route. (If some node happens to own the 192.168.122.0/26
block, it's worse: the packet goes into that node's blackhole route.) Every 192.168.x.x destination outside the cluster —
a home LAN, a VPN range, a partner network — is unreachable from pods in
this lab for the same reason. Write it as a runbook row and a reference-track
item. The fix is choosing a non-overlapping pod CIDR at install time
(migrating an IPPool live is a documented Calico procedure, not in scope).

## 3. Verification

| Check | Expected |
|---|---|
| §2.1 | pod `/32`, default via 169.254.1.1, neighbour `ee:ee:ee:ee:ee:ee`, MTU 1480 |
| §2.2 | the `iflink` index maps to a `cali*` on worker-1 with `proxy_arp=1` |
| §2.4 | one `Mesh_*` protocol per other node, all `Established` |
| §2.5 | IPIP packets node→node for cross-node only |
| §2.7 | 10.215.138.1 answers, 192.168.122.1 doesn't |

## 4. Break/fix

> **RISKY.** `break.sh` adds an nftables table `inet lab-fw` on worker-2
> that filters IP-in-IP. **Blast radius:** pod traffic into worker-2 from
> other nodes (cluster DNS replicas there, the Gateway's backends there).
> Control-plane and node-to-node traffic are unaffected.
> **Rollback:** `ssh w-2 sudo nft delete table inet lab-fw`.

```bash
bash break.sh
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

**Done when** `kubectl -n lab-anatomy exec client -- curl -s -m3 $REMOTE`
answers and you can name the boundary that dropped it.

<details><summary>Hint (only after 20 minutes)</summary>

Cross-node only. Capture the underlay on both nodes and compare.
</details>

Solution: [`solution.md`](solution.md).

## 5. Cleanup

```bash
kubectl delete -f pods.yaml
ssh w-2 sudo nft delete table inet lab-fw 2>/dev/null || true
```

## 6. What I should be able to explain after this

- Calico doesn't bridge: each pod is a /32 behind a `cali` veth, the pod's gateway 169.254.1.1 exists only as a proxy-ARP answer, and the node routes everything.
- Calico IPIP = BIRD full-mesh BGP distributing per-node /26 blocks + IP-in-IP (protocol 4, 20 bytes) between nodes; same-node traffic never touches the NIC.
- natOutgoing masquerades only destinations outside every IPPool, so a pod CIDR that overlaps a real network makes that network unreachable from pods.
