# Drill 02 — Ethernet, ARP and MAC learning

| | |
|---|---|
| **Objective** | Watch two switches learn MAC addresses, flood what they don't know, and resolve IPs to MACs with ARP — and know what a link's speed/duplex/error counters tell you. |
| **Time** | 1.5 h (week 1) · course Days 2, 5, 6, 9 |
| **Where** | netlab-c, `topo/lan`, root |
| **Risk** | Safe — containers. eth4 stays out of the bridges (it would make a loop; drill 06). |

## 1. Prerequisites

```bash
sudo -i; cp -r /workbook ~/wb 2>/dev/null; cd ~/wb/phase1-ccna-drills/topo
containerlab deploy -t lan.clab.yml && bash lan-setup.sh
x() { docker exec clab-p1l-$1 sh -c "$2"; }
```

Hosts: h1 10.0.10.1, h2 .2 on sw1; h3 .3, h4 .4 on sw2; all one L2 segment.

## 2. Hands-on

### 2.1 Learning

```bash
for h in h1 h2 h3 h4; do echo "$h $(x $h 'cat /sys/class/net/eth1/address')"; done   # note the MACs
x sw1 'bridge fdb show br br0 | grep -v permanent'        # empty-ish: nothing learned yet
x h1 'ping -c1 10.0.10.3 >/dev/null'
x sw1 'bridge fdb show br br0 | grep -v permanent'        # h1's MAC on eth1, h3's MAC on eth3 (the inter-switch link)
x sw2 'bridge fdb show br br0 | grep -v permanent'        # h3 on eth1, h1 on eth3
```

A switch learns **source** MACs per port and forwards by **destination**
MAC. Behind sw1's eth3 sit all of sw2's hosts: one port, many MACs.

### 2.2 Flooding and ARP

```bash
x h1 'ip neigh flush all'; x sw1 'bridge fdb flush dev br0 2>/dev/null || true'
x h2 'tcpdump -nnei eth1 -c4 arp or icmp' &
x h4 'tcpdump -nnei eth1 -c4 arp or icmp' &
x h1 'ping -c2 10.0.10.3 >/dev/null'; wait
x h1 'ip neigh'                                            # 10.0.10.3 lladdr <h3 MAC> REACHABLE
```

Predict before running: h2 and h4 see the ARP **request** (broadcast,
`ff:ff:ff:ff:ff:ff`, flooded everywhere) but not the reply or the pings
(unicast, delivered only where the MAC lives). Then:

```bash
x h4 'arping -c2 -U -I eth1 10.0.10.4'                    # gratuitous ARP: "this IP is at my MAC", unsolicited
x h1 'ip neigh show 10.0.10.4'
```

GARP is what VRRP, MetalLB L2 and kube-vip send on failover (drill 11, lab 4.02).

### 2.3 The link layer's health counters

```bash
x h1 'ethtool eth1 | grep -E "Speed|Duplex|Link detected"'   # veth: 10000Mb/s, Full (virtual)
x h1 'ip -s link show eth1'                                   # RX/TX packets, errors, dropped
x h1 'ethtool -S eth1 | head'
```

On real NICs a **duplex mismatch** (one side forced full, the other
auto → half) shows as late collisions and CRC errors rising on one side,
and throughput collapsing under load while ping looks fine. `ip -s link`
and `ethtool -S` are where you see it. Node bonds (LACP, "EtherChannel")
are the Linux `bond` driver: `cat /proc/net/bonding/bond0`.

## 3. Verification

| Check | Expected |
|---|---|
| §2.1 | sw1 learned h1 on eth1, h3 on eth3; sw2 the mirror |
| §2.2 | h2/h4 see only the ARP request; h1's neighbour table has h3's MAC |
| §2.3 | link up, 10000Mb/s Full, zero errors |

## 4. Break/fix

```bash
cd ~/wb/phase1-ccna-drills/02-ethernet-arp && bash break.sh
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

**Done when** `x h2 'ping -c20 -i0.2 10.0.10.1'` shows 0 % loss.

Solution: [`solution.md`](solution.md).

## 5. Cleanup

```bash
containerlab destroy -t ~/wb/phase1-ccna-drills/topo/lan.clab.yml --cleanup   # or keep for drills 03, 06
```

## 6. What I should be able to explain after this

- A switch learns source MAC → port, forwards known unicast out one port, floods broadcast/unknown unicast; behind an inter-switch link sit many MACs.
- ARP maps an IP to a MAC with a broadcast request and a unicast reply; gratuitous ARP announces a mapping unasked (failover).
- Link-layer problems (duplex, CRC, drops) show in interface counters, not in ping.
