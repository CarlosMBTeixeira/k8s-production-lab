# Drill 03 — IPv4 addressing and subnetting

| | |
|---|---|
| **Objective** | Subnet any prefix in your head in under 30 seconds, and see what a host does with its mask: what it delivers directly, what it hands to the gateway, and what it can't send at all. |
| **Time** | 1.5 h (week 2) · course Days 7, 8, 13 + the later subnetting/VLSM days |
| **Where** | netlab-c, `topo/lan`, root · the quiz runs anywhere with python3 |
| **Risk** | Safe |

## 1. Prerequisites

- Drill 02. `topo/lan` up (`containerlab deploy -t lan.clab.yml && bash lan-setup.sh`).

## 2. Hands-on

### 2.1 The method (no calculator)

For `a.b.c.d/p`: find the **interesting octet** (the one the prefix cuts),
the **block size** = 256 − mask value in that octet, and the network =
largest multiple of the block ≤ that octet. Broadcast = network + block − 1.
Hosts = 2^(32−p) − 2. Example: `172.16.37.140/27` → block 32 in the 4th
octet → network .128, broadcast .159, hosts .129–.158, mask 255.255.255.224, 30 hosts.

```bash
python3 subnet-quiz.py 5           # warm-up
python3 subnet-quiz.py 10          # the Phase 1 exit check: 10 correct in < 5 min — repeat weekly until met
```

Pod CIDR, Service CIDR, node subnets, cloud VPCs: you'll carve these
constantly. The k8slab ranges (pods 192.168.0.0/16 in /26 blocks,
Services 10.96.0.0/12) — subnet them now: how many /26 blocks, how many
Services?

### 2.2 Two subnets on one L2

Re-address the lan as two /25s with r1 as the router between them (same
wire, two IP networks — legal, and common by accident):

```bash
x() { docker exec clab-p1l-$1 sh -c "$2"; }
x r1 'sysctl -qw net.ipv4.ip_forward=1; ip addr add 10.0.10.126/25 dev eth1; ip addr add 10.0.10.254/25 dev eth1'
x h1 'ip addr flush dev eth1; ip addr add 10.0.10.1/25 dev eth1;   ip route add default via 10.0.10.126'
x h2 'ip addr flush dev eth1; ip addr add 10.0.10.2/25 dev eth1;   ip route add default via 10.0.10.126'
x h3 'ip addr flush dev eth1; ip addr add 10.0.10.130/25 dev eth1; ip route add default via 10.0.10.254'
x h4 'ip addr flush dev eth1; ip addr add 10.0.10.131/25 dev eth1; ip route add default via 10.0.10.254'
x h1 'ip route get 10.0.10.2; ip route get 10.0.10.130'      # direct vs via gateway — the mask decides
x h1 'ping -c2 10.0.10.130'
x h1 'tcpdump -nnei eth1 -c6 icmp' & sleep 1; x h1 'ping -c2 10.0.10.130 >/dev/null'; wait
```

Read the capture: the echo request goes to **r1's MAC** even though h3 is
on the same wire. You may also see an **ICMP redirect** from r1 ("next time,
send it straight to …") — routers send them when in and out interface are
the same. Most Linux hosts ignore them; note it anyway.

### 2.3 What a mask mistake looks like

```bash
x h2 'ip addr flush dev eth1; ip addr add 10.0.10.2/24 dev eth1; ip route add default via 10.0.10.126'
x h2 'ip route get 10.0.10.130'      # direct now: h2 thinks h3 is local
x h2 'ping -c2 10.0.10.130'          # works anyway — why? (h3's reply goes via r1: asymmetric, but delivered)
x h2 'ip addr flush dev eth1; ip addr add 10.0.10.2/25 dev eth1; ip route add default via 10.0.10.126'   # back
```

A wrong mask often "works" until it doesn't — the failure depends on which
side is wrong and what's in between. The break/fix is one that doesn't work.

## 3. Verification

| Check | Expected |
|---|---|
| quiz | your time and score recorded in the tracker |
| §2.2 | h1 → h2 direct, h1 → h3 via 10.0.10.126; ping works (ping may count r1's redirect as `+1 errors`) |
| §2.3 | with /24, `ip route get 10.0.10.130` shows `dev eth1` without `via` |

## 4. Break/fix

```bash
cd ~/wb/phase1-ccna-drills/03-ipv4-subnetting && bash break.sh     # rebuilds §2.2's addressing, then changes one host
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

**Done when** h2 reaches h1 and h3.

Solution: [`solution.md`](solution.md).

## 5. Cleanup

```bash
bash ~/wb/phase1-ccna-drills/topo/lan-setup.sh 2>/dev/null   # re-address (or destroy the lab)
```

## 6. What I should be able to explain after this

- Subnetting by block size: network, broadcast, host range, mask and host count from any prefix in seconds.
- A host's mask decides "deliver directly (ARP for the destination)" vs "send to the gateway (ARP for the gateway)"; the gateway must be inside the host's own subnet.
- Two IP subnets can share one L2; a router between them sees in = out and may send ICMP redirects.
