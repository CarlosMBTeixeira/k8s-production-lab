# Lab 2.02 — Bridges, ARP and VLAN filtering

| | |
|---|---|
| **Objective** | Build a software switch, watch it learn MACs and flood, segment it with VLANs, and see how `br_netfilter` makes bridged frames hit iptables. |
| **Time** | 4 h (week 1) |
| **Where** | netlab-a, root. §2.4 on netlab-c (the Docker VM). |
| **Risk** | Safe on netlab-a. §2.4 flips a bridge sysctl on netlab-c and puts it back. |

## 1. Prerequisites

- Lab 2.01. Phase 1 drill 02 (Ethernet, ARP) helps but isn't required.

## 2. Hands-on

### 2.1 Three hosts on one switch

```bash
ip link add br0 type bridge
ip link set br0 up
for i in 1 2 3; do
  ip netns add ns$i
  ip link add v$i type veth peer name eth0 netns ns$i
  ip link set v$i master br0 up
  ip -n ns$i addr add 10.0.10.$i/24 dev eth0
  ip -n ns$i link set eth0 up
  ip -n ns$i link set lo up
done
bridge link                            # v1..v3, state forwarding
ip netns exec ns1 ping -c2 10.0.10.3
```

The bridge has no IP. It does not need one to switch: it is L2 only. (A
host IP on `br0` would make the root namespace a fourth host on the switch
— that is what `cni0` and `docker0` are.)

### 2.2 Learning and flooding

```bash
bridge fdb show br br0 | grep -v permanent   # learned MACs, one per port, "master br0"
ip -d link show br0 | grep -o 'ageing_time [0-9]*'   # centiseconds; 30000 = 300 s

# watch a flood: clear ns1's ARP cache and the bridge's FDB, then capture on the port to ns2
ip -n ns1 neigh flush all
bridge fdb flush dev br0 2>/dev/null || ip link set br0 type bridge fdb_flush
tcpdump -nnei v2 'arp or icmp' &      # in a second shell, or background it
ip netns exec ns1 ping -c2 10.0.10.3
kill %1
```

The filter matters: drop it once and you'll see IPv6 MLD reports and router
solicitations from every namespace (multicast, flooded like broadcast) bury
the ARP.

Write before running: which frames will `v2` (ns2's port) see? The ARP
**request** is a broadcast and floods to every port. The ARP reply and the
ICMP are unicast to a learned MAC and only go out the port that MAC lives on.

### 2.3 VLANs on the bridge

```bash
ip link set br0 type bridge vlan_filtering 1
bridge vlan show                       # every port: 1 PVID Egress Untagged
bridge vlan add dev v1 vid 10 pvid untagged
bridge vlan add dev v2 vid 10 pvid untagged
bridge vlan add dev v3 vid 20 pvid untagged
for p in v1 v2 v3; do bridge vlan del dev $p vid 1; done
bridge vlan show

ip netns exec ns1 ping -c2 -W1 10.0.10.2     # works — same VLAN
ip netns exec ns1 ping -c2 -W1 10.0.10.3     # fails — same subnet, different VLAN: ARP never arrives
```

Now make `v3` a **trunk** carrying VLAN 10 and 20 tagged, and give ns3 a VLAN
sub-interface (what a hypervisor or a Multus/macvlan-on-VLAN setup does):

```bash
bridge vlan del dev v3 vid 20
bridge vlan add dev v3 vid 10
bridge vlan add dev v3 vid 20
ip -n ns3 addr flush dev eth0
ip -n ns3 link add link eth0 name eth0.10 type vlan id 10
ip -n ns3 addr add 10.0.10.33/24 dev eth0.10
ip -n ns3 link set eth0.10 up
tcpdump -nnei v3 -c4 'vlan and (arp or icmp)' &
ip netns exec ns1 ping -c2 10.0.10.33
```

### 2.4 Bridged traffic meets iptables (netlab-c)

Do this on **netlab-c**, where Docker runs. `bash setup/netlab.sh up c` first.

```bash
ip netns add d1; ip netns add d2
ip link add brx type bridge; ip link set brx up
for i in 1 2; do
  ip link add dx$i type veth peer name eth0 netns d$i
  ip link set dx$i master brx up
  ip -n d$i addr add 10.9.9.$i/24 dev eth0; ip -n d$i link set eth0 up
done
ip netns exec d1 ping -c2 -W1 10.9.9.2        # write your prediction first
lsmod | grep br_netfilter
sysctl net.bridge.bridge-nf-call-iptables
iptables -S FORWARD | head -1
iptables -L FORWARD -v -n | head -3           # watch the policy counter while pinging
```

On a fresh netlab-c the first ping **works**: Docker (27.x, from the
Containerlab installer) sets FORWARD to DROP at start but loads
`br_netfilter` only on demand, so `lsmod` is empty and the sysctl doesn't
exist yet (a plain `docker run` doesn't load it either). Bridged frames
never reach iptables. Now load it, as every kubeadm node's prerequisites do,
and repeat the ping:

```bash
modprobe br_netfilter
ip netns exec d1 ping -c2 -W1 10.9.9.2        # now 100 % loss
iptables -L FORWARD -v -n | head -3           # policy DROP counter rising
```

With it loaded and `bridge-nf-call-iptables=1`, **frames switched
inside a bridge traverse the iptables FORWARD chain**, and Docker's FORWARD
policy is DROP. To prove it, briefly:

```bash
sysctl -w net.bridge.bridge-nf-call-iptables=0   # ping works
sysctl -w net.bridge.bridge-nf-call-iptables=1   # back — Docker relies on it
```

kubeadm's preflight insists on `br_netfilter` and `bridge-nf-call-iptables=1`
for the same reason in reverse: kube-proxy's DNAT must see pod-to-pod traffic
that a bridge-based CNI switches without routing. Lab 2.10 hits this.

## 3. Verification

| Check | Expected |
|---|---|
| §2.2 capture on `v2` | ARP `Request who-has 10.0.10.3` (dst `ff:ff:ff:ff:ff:ff`); no ICMP |
| `bridge fdb show br br0` | one learned MAC per port, matching `ip -n nsX link show eth0` |
| §2.3 ns1 → ns3 | 100 % loss before the trunk; `tcpdump -e` on `v3` shows `ethertype 802.1Q … vlan 10` after |
| `bridge vlan show` | v1, v2: `10 PVID Egress Untagged`; v3: `10` and `20`, tagged |
| §2.4 | ping works before `modprobe br_netfilter`; after it, fails with the sysctl at 1 and works at 0; FORWARD policy counter rises while it fails |

## 4. Break/fix

```bash
bash break.sh          # rebuilds a plain br0 with ns1..ns3 (no VLANs), injects a fault
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

**Done when** ns1 ↔ ns2 ping works, and you can say why the neighbour table
looked healthy while ping failed.

<details><summary>Hint (only after 20 minutes)</summary>

ARP succeeds. ICMP doesn't. What is different about how a bridge forwards
those two frames? Compare what the bridge knows about each port.
</details>

Solution: [`solution.md`](solution.md).

## 5. Cleanup

```bash
# netlab-a
for i in 1 2 3; do ip netns del ns$i; done; ip link del br0
# netlab-c
for i in 1 2; do ip netns del d$i; done; ip link del brx
modprobe -r br_netfilter      # §2.4 loaded it; it would outlive the lab (and break §2.4's first ping on a re-run)
lsmod | grep -c br_netfilter  # 0
```

## 6. What I should be able to explain after this

- A Linux bridge is a learning switch: it fills its FDB from source MACs, forwards known unicast out one port, and floods broadcast, multicast and unknown unicast to every other port (per-port `flood`/`learning` flags can change that).
- With `vlan_filtering`, each port has a PVID (untagged ingress goes there) and a set of member VLANs (tagged or untagged egress); a trunk is just a port with several tagged members.
- `br_netfilter` sends bridged frames through iptables; that is why Docker's FORWARD DROP breaks hand-built bridges, and why kubeadm requires it so DNAT applies to same-bridge pod traffic.
