# Drill 04 — The IPv4 header: TTL, DF, fragmentation

| | |
|---|---|
| **Objective** | Make every interesting IPv4 header field do its job on the wire: TTL (and how traceroute uses it), DF and fragmentation, the ID field, protocol numbers and DSCP. |
| **Time** | 1.5 h (week 2) · course Day 10 |
| **Where** | netlab-c, `topo/routed`, root |
| **Risk** | Safe |

## 1. Prerequisites

- Drill 01. `topo/routed` up with drill 01's two static routes:

```bash
cd ~/wb/phase1-ccna-drills/topo; containerlab deploy -t routed.clab.yml --reconfigure && bash routed-setup.sh
docker exec clab-p1r-r1 vtysh -c 'conf t' -c 'ip route 172.16.2.0/24 10.0.12.2'
docker exec clab-p1r-r2 vtysh -c 'conf t' -c 'ip route 172.16.1.0/24 10.0.12.1'
x() { docker exec clab-p1r-$1 sh -c "$2"; }
```

## 2. Hands-on

### 2.1 TTL and traceroute

```bash
x h1 'ping -c1 -t 1 172.16.2.10'          # "Time to live exceeded" from 172.16.1.1 (r1)
x h1 'ping -c1 -t 2 172.16.2.10'          # from r2
x r1 'tcpdump -nni eth1 -c2 -v icmp' & sleep 1; x h1 'ping -c1 -t1 172.16.2.10 >/dev/null'; wait
x h1 'traceroute -n 172.16.2.10'          # UDP probes with TTL 1, 2, 3…
x h1 'traceroute -n -I 172.16.2.10'       # ICMP probes; -T for TCP (what firewalls usually allow)
```

The ICMP "time exceeded" carries the **original IP header + 8 bytes** of
the dropped packet — that's how traceroute knows which probe it answers.

### 2.2 DF and fragmentation

Shrink the r1–r2 link to 1400:

```bash
x r1 'ip link set eth2 mtu 1400'; x r2 'ip link set eth1 mtu 1400'
x r1 'tcpdump -nni eth2 -c4 -v icmp' &
sleep 1; x h1 'ping -c1 -s 1472 -M dont 172.16.2.10 >/dev/null'; wait
```

Two fragments on r1–r2: same **ID**, first with **MF** (more fragments)
and offset 0, second with offset 1376 (=172×8: offsets count 8-byte units).
h2 reassembles. Now with DF:

```bash
x h1 'ping -c1 -s 1472 -M do 172.16.2.10'   # "Frag needed and DF set (mtu = 1400)" from r1
x r1 'ip link set eth2 mtu 1500'; x r2 'ip link set eth1 mtu 1500'
```

Lab 2.09 builds on this for TCP (PMTUD, MSS clamping, blackholes).

### 2.3 Protocol number and DSCP

```bash
x r1 'tcpdump -nni eth2 -c3 -v "icmp or tcp port 80"' &
sleep 1; x h1 'ping -c1 -Q 0xb8 172.16.2.10 >/dev/null; curl -s 172.16.2.10 >/dev/null'; wait
```

`proto ICMP (1)` vs `proto TCP (6)` (UDP is 17, IP-in-IP 4, GRE 47, ESP 50);
`tos 0xb8` = DSCP 46 (EF, voice) in the top 6 bits. Kubernetes doesn't set
DSCP for you; some CNIs can, and fabrics may honour or rewrite it.

## 3. Verification

| Check | Expected |
|---|---|
| §2.1 | TTL 1 → r1, TTL 2 → r2; traceroute lists 172.16.1.1, 10.0.12.2, 172.16.2.10 |
| §2.2 | two fragments with the same id, `flags [+]` on the first, `offset 1376` on the second; DF → frag needed, mtu 1400 |
| §2.3 | `tos 0xb8`; proto 1 and 6 |

## 4. Break/fix

```bash
cd ~/wb/phase1-ccna-drills/04-ipv4-header && bash break.sh
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

**Done when** `x h1 'ping -c1 172.16.99.10'` returns "Destination Net
Unreachable" from r1 (the honest answer for a network that doesn't exist)
instead of the current error, and h1 → h2 still works.

Solution: [`solution.md`](solution.md).

## 5. Cleanup

Keep `routed` for drill 05.

## 6. What I should be able to explain after this

- TTL stops loops and powers traceroute (each hop that decrements to 0 returns ICMP time exceeded quoting the original header).
- DF + a smaller next-hop MTU → drop + ICMP "frag needed"; without DF the router fragments (same ID, MF flag, 8-byte offsets) and only the destination reassembles.
- The protocol field says what's inside (1, 6, 17, 4, 47, 50); DSCP lives in the old TOS byte.
