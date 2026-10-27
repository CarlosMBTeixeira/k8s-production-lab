# Lab 2.08 — VXLAN by hand

| | |
|---|---|
| **Objective** | Stretch one L2 segment across two hosts with VXLAN, fill the forwarding table by hand the way Flannel and Calico do, and read encapsulated packets on the underlay. |
| **Time** | 4 h (week 6) |
| **Where** | netlab-a **and** netlab-b, root |
| **Risk** | Safe — new devices only; the uplink is not reconfigured |

## 1. Prerequisites

- Labs 2.01, 2.02, 2.07. Both VMs up (`setup/netlab.sh up`), and
  `setup/netlab.sh env` run on the WSL host so `/workbook/setup/netlab.env` exists.

On **both** VMs:

```bash
source /workbook/setup/netlab.env           # A_IP, B_IP
UP=$(ip -o route show default | awk '{print $5}')
# netlab-a:
ME=$A_IP PEER=$B_IP N=1
# netlab-b:
ME=$B_IP PEER=$A_IP N=2
```

## 2. Hands-on

### 2.1 Point-to-point tunnel

On both:

```bash
ip link add vx100 type vxlan id 100 dstport 4789 local $ME remote $PEER dev $UP
ip link add br-vx type bridge
ip link set vx100 master br-vx
ip link set vx100 up; ip link set br-vx up
ip netns add pod
ip link add vpod type veth peer name eth0 netns pod
ip link set vpod master br-vx up
ip -n pod addr add 10.200.0.$N/24 dev eth0
ip -n pod link set eth0 up; ip -n pod link set lo up
```

On netlab-a:

```bash
timeout 5 tcpdump -nnei $UP udp port 4789 &
ip netns exec pod ping -c2 10.200.0.2; wait
```

The new links also send IPv6 DAD and MLD (`ff02::…`) and an IGMP report
through the tunnel in their first seconds; skip those and find the ARP and
ICMP.

Read one encapsulated packet aloud: outer Ethernet (VM MACs) → outer IP
(A_IP → B_IP) → UDP (random source port → 4789) → VXLAN header (VNI 100) →
inner Ethernet (pod MACs) → inner IP (10.200.0.1 → 10.200.0.2) → ICMP. The
source port is a hash of the inner flow so the underlay can ECMP-balance.

```bash
ip -d link show vx100                       # vxlan id 100 remote … dstport 4789 … mtu 1450
bridge fdb show dev vx100                   # 00:00:00:00:00:00 dst <PEER> — the "remote" default; learned MACs appear too
ss -lun | grep 4789                         # the kernel's VXLAN socket
```

### 2.2 MTU: the overlay's first bug

```bash
ip netns exec pod ping -c2 -M do -s 1472 10.200.0.2    # predict
ip -n pod link show eth0 | grep -o 'mtu [0-9]*'        # 1500
ip link show vx100 | grep -o 'mtu [0-9]*'              # 1450 = 1500 - 50
```

The 1500-byte frame reaches the bridge and is dropped silently because the
egress port (`vx100`) has MTU 1450. No ICMP, no counter you'd look at.
Fix it the way every CNI does — give the pod the overlay MTU:

```bash
ip -n pod link set eth0 mtu 1450
ip netns exec pod ping -c2 -M do -s 1422 10.200.0.2    # 1422 + 28 = 1450: works
```

Overhead: outer Ethernet 14 (not counted in MTU) + IP 20 + UDP 8 + VXLAN 8 +
inner Ethernet 14 = 50 bytes of MTU.

### 2.3 No flooding: program the FDB like a CNI

The `remote` form only knows one peer. Real overlays have N peers and
don't want to learn by flooding. Rebuild `vx100` on both hosts:

```bash
ip link del vx100
ip link add vx100 type vxlan id 100 dstport 4789 local $ME dev $UP nolearning
ip link set vx100 master br-vx mtu 1450 up
```

Ping fails now: no FDB entry, no learning. Give it what Flannel gives it.
Get each pod's MAC (`ip -n pod link show eth0`) and on each host add the
**other** pod:

```bash
PEER_POD_MAC=<the other host's pod eth0 MAC>
PEER_POD_IP=10.200.0.$((3-N))
bridge fdb add $PEER_POD_MAC dev vx100 dst $PEER self permanent   # MAC → which VTEP
ip -n pod neigh replace $PEER_POD_IP lladdr $PEER_POD_MAC dev eth0 nud permanent   # skip ARP entirely
ip -n pod neigh show                                              # PERMANENT, not STALE
timeout 15 tcpdump -nni $UP udp port 4789 > /tmp/vx.txt &
ip netns exec pod ping -c10 -q $PEER_POD_IP; wait
grep -c VXLAN /tmp/vx.txt; grep -c ARP /tmp/vx.txt                # 20 and 0: no ARP crosses the tunnel
```

`replace`, not `add`: §2.1's ARP left a STALE entry, `add` fails with
"File exists", and that dynamic entry keeps sending unicast ARP probes
through the tunnel.

For BUM traffic (if you didn't pin ARP), the head-end replication entry
is `bridge fdb append 00:00:00:00:00:00 dev vx100 dst <peer>` — one per peer.

## 3. Verification

| Check | Expected |
|---|---|
| §2.1 capture | `A_IP.<port> > B_IP.4789: VXLAN, flags [I] (0x08), vni 100` followed by the inner `10.200.0.1 > 10.200.0.2: ICMP echo request` |
| §2.2 | `-s 1472 -M do` fails silently before the pod MTU fix; `-s 1422` works after |
| §2.3 | `bridge fdb show dev vx100` shows your static entry with `dst <PEER>`; no ARP inside the tunnel |

## 4. Break/fix

```bash
# netlab-a
bash break.sh a     # builds a correct side A (tunnel + pod 10.200.0.1)
# netlab-b
bash break.sh b     # builds side B (pod 10.200.0.2) — and prints the ticket
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

**Done when** `ip netns exec pod ping -c3 10.200.0.2` works from netlab-a.

<details><summary>Hint (only after 20 minutes)</summary>

Capture the underlay on both hosts, without a port filter: `udp or icmp`.
</details>

Solution: [`solution.md`](solution.md).

## 5. Cleanup

On both:

```bash
ip netns del pod; ip link del vx100; ip link del br-vx
```

## 6. What I should be able to explain after this

- VXLAN is L2 over UDP: a VTEP wraps the inner frame in IP/UDP/VXLAN (VNI) and sends it to the VTEP that owns the destination MAC; the UDP source port carries flow entropy for ECMP.
- An overlay costs 50 bytes of MTU (VXLAN; Geneve ≥ 50, IPIP 20). Pods must use the overlay MTU or large frames die silently at the bridge or the tunnel.
- Production overlays don't flood-and-learn: the CNI programs FDB (MAC→VTEP) and neighbour entries from its control plane (Flannel from node annotations, Calico from its datastore, Cilium from its own maps). Port 4789 is IANA; Linux defaults to 8472, which Flannel and Cilium kept.
