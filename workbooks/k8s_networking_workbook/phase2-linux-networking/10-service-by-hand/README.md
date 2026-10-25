# Lab 2.10 — A Service by hand: DNAT, then IPVS

| | |
|---|---|
| **Objective** | Build a ClusterIP, a NodePort and hairpin handling with iptables exactly as kube-proxy lays them out, then rebuild the same Service with IPVS. |
| **Time** | 4 h (week 7) |
| **Where** | netlab-a, root namespace (the "node") |
| **Risk** | Changes netlab-a's root ns: nat chains `LAB-*`, `br_netfilter`, an IPVS service. Blast radius: this VM. Rollback: `bash topo.sh down` + §5. |

## 1. Prerequisites

- Labs 2.02 (br_netfilter), 2.05 (NAT), 2.06 (conntrack).

```bash
bash topo.sh up
A_IP=$(ip -4 -o addr show dev $(ip -o route show default | awk '{print $5}') | awk '{print $4}' | cut -d/ -f1)
```

The VIP `10.96.100.10` exists on no interface. It's a rule, not an address
— which is exactly what a ClusterIP is in iptables mode.

## 2. Hands-on

### 2.1 ClusterIP, kube-proxy style

```bash
iptables -t nat -N LAB-SERVICES
iptables -t nat -A PREROUTING -j LAB-SERVICES       # traffic from pods (forwarded)
iptables -t nat -A OUTPUT     -j LAB-SERVICES       # traffic from the node itself
iptables -t nat -N LAB-SVC-WEB
iptables -t nat -A LAB-SERVICES -d 10.96.100.10/32 -p tcp --dport 80 -j LAB-SVC-WEB
for i in 1 2 3; do
  iptables -t nat -N LAB-SEP-$i
  iptables -t nat -A LAB-SEP-$i -p tcp -j DNAT --to-destination 10.50.0.1$i:8080
done
iptables -t nat -A LAB-SVC-WEB -m statistic --mode random --probability 0.33333 -j LAB-SEP-1
iptables -t nat -A LAB-SVC-WEB -m statistic --mode random --probability 0.50000 -j LAB-SEP-2
iptables -t nat -A LAB-SVC-WEB -j LAB-SEP-3

for i in $(seq 30); do curl -s 10.96.100.10; done | sort | uniq -c   # ~10 each
iptables -t nat -L LAB-SVC-WEB -v -n
```

Why 1/3, then 1/2, then everything? Each rule only sees what the previous
ones didn't take. Compare with a real node later: `iptables-save -t nat |
grep -A4 'KUBE-SVC-'` (lab 3.02) has the same shape.

### 2.2 From a pod on the same bridge

```bash
lsmod | grep -q br_netfilter && echo "br_netfilter already loaded: modprobe -r br_netfilter first"
ip netns exec cl curl -s -m3 10.96.100.10 ; echo "exit=$?"     # predict
```

Capture on `vcl` and on the backend's port (`vb1`..`vb3`). The request is
routed through the node (DNAT happens), but the backend's reply goes
**straight over the bridge** to 10.50.0.20 without touching the node's IP
stack, so it is never un-DNATed. `cl` gets a SYN-ACK from 10.50.0.1x, which
it never called, and resets it. Fix it the way kubeadm requires:

```bash
modprobe br_netfilter
sysctl -w net.bridge.bridge-nf-call-iptables=1
ip netns exec cl bash -c 'for i in $(seq 9); do curl -s 10.96.100.10; done' | sort | uniq -c
```

Now bridged frames go through netfilter, conntrack sees the reply and
reverses the DNAT.

### 2.3 Hairpin: a backend calling its own Service

```bash
ip netns exec b1 bash -c 'for i in $(seq 9); do curl -s -m2 10.96.100.10 || echo FAIL; done' | sort | uniq -c
```

About a third fail: when DNAT picks b1 itself, the packet has to go back out
the port it came in on, and a bridge never does that. kube-proxy's answer:
SNAT hairpinned traffic (mark in the SEP chain, masquerade on the way
out), and the CNI sets the port to hairpin mode.

```bash
iptables -t nat -N LAB-MARK-MASQ
iptables -t nat -A LAB-MARK-MASQ -j MARK --or-mark 0x4000
for i in 1 2 3; do iptables -t nat -I LAB-SEP-$i 1 -s 10.50.0.1$i/32 -j LAB-MARK-MASQ; done
iptables -t nat -N LAB-POSTROUTING
iptables -t nat -A POSTROUTING -j LAB-POSTROUTING
iptables -t nat -A LAB-POSTROUTING -m mark --mark 0x4000/0x4000 -j MASQUERADE
for i in 1 2 3; do bridge link set dev vb$i hairpin on; done
ip netns exec b1 bash -c 'for i in $(seq 9); do curl -s -m2 10.96.100.10 || echo FAIL; done' | sort | uniq -c
```

### 2.4 NodePort

```bash
iptables -t nat -N LAB-NODEPORTS
iptables -t nat -A LAB-SERVICES -m addrtype --dst-type LOCAL -j LAB-NODEPORTS
iptables -t nat -N LAB-EXT-WEB
iptables -t nat -A LAB-EXT-WEB -j LAB-MARK-MASQ        # externalTrafficPolicy: Cluster → SNAT
iptables -t nat -A LAB-EXT-WEB -j LAB-SVC-WEB
iptables -t nat -A LAB-NODEPORTS -p tcp --dport 30080 -j LAB-EXT-WEB
```

From the **WSL host**: `for i in $(seq 6); do curl -s http://<A_IP>:30080; done`.
Then on netlab-a: `tail -3 /var/tmp/svc/b*.log` — the client address the
backends logged is `10.50.0.1`, the node, not the WSL host. That's the
source-IP loss of `externalTrafficPolicy: Cluster`. On one node the SNAT
isn't even needed for the reply to come back; with backends on other nodes
it is, and `Local` avoids it by only using local endpoints.

### 2.5 The same Service with IPVS

```bash
bash topo.sh clean-rules                                     # iptables Service gone
modprobe ip_vs
ip link add kube-ipvs0 type dummy; ip link set kube-ipvs0 up
ip addr add 10.96.100.10/32 dev kube-ipvs0                    # IPVS needs the VIP to be local
ipvsadm -A -t 10.96.100.10:80 -s rr
for i in 1 2 3; do ipvsadm -a -t 10.96.100.10:80 -r 10.50.0.1$i:8080 -m; done   # -m = masquerade (NAT) mode
ipvsadm -Ln
for i in $(seq 9); do curl -s 10.96.100.10; done             # strict rotation, not random
ipvsadm -Ln --stats; ipvsadm -Lnc | head                     # per-backend counters, IPVS's own connection table
ipvsadm -E -t 10.96.100.10:80 -s lc                          # switch scheduler live
```

One hash-table lookup instead of a rule walk, and real schedulers. kube-proxy
in IPVS mode still uses iptables (with ipsets) for masquerade and NodePorts.
The VIP being a local address has a side effect: by default Linux answers
ARP for **any** local address on **any** interface, which is why IPVS mode
(and MetalLB) want `arp_ignore=1`/`arp_announce=2` ("strictARP").

## 3. Verification

| Check | Expected |
|---|---|
| §2.1 | ~10/10/10 split; `LAB-SVC-WEB` counters ≈ 30, 20, 10 down the chain |
| §2.2 | hangs before br_netfilter, works after |
| §2.3 | ~3 FAIL out of 9 before, 0 after |
| §2.4 | from the WSL host, b1/b2/b3 answer; backend logs show `10.50.0.1` as client |
| §2.5 | `ipvsadm -Ln` lists 3 real servers `Masq`; curls rotate b1 b2 b3 b1 … |

## 4. Break/fix

```bash
bash break.sh      # rebuilds the topology and the iptables Service, injects a fault
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

**Done when** 30 requests to `10.96.100.10` from the node all succeed.

<details><summary>Hint (only after 20 minutes)</summary>

"One in three" with three backends. Follow the chains to their targets.
</details>

Solution: [`solution.md`](solution.md).

## 5. Cleanup

```bash
bash topo.sh down
sysctl -w net.bridge.bridge-nf-call-iptables=0; modprobe -r br_netfilter 2>/dev/null || true
modprobe -r ip_vs_lc ip_vs_rr ip_vs 2>/dev/null || true
```

## 6. What I should be able to explain after this

- An iptables-mode ClusterIP is a chain: match VIP:port → pick an endpoint chain by cascading probabilities → DNAT; conntrack does the reverse, which is why the reply must pass back through the same netfilter (br_netfilter on bridged CNIs).
- Hairpin and NodePort both need SNAT (`KUBE-MARK-MASQ` → `MASQUERADE` in POSTROUTING), and SNAT is what loses the client IP under `externalTrafficPolicy: Cluster`.
- IPVS is a kernel L4 load balancer with a hash lookup and real schedulers; it needs the VIP on a local dummy interface (`kube-ipvs0`), which in turn needs strict ARP settings.
