# Drill 05 — Static routing and the life of a packet

| | |
|---|---|
| **Objective** | Route a three-router network by hand: routes both ways, longest-prefix match, a floating static backup, and the per-hop decision every packet goes through. |
| **Time** | 1.5 h (week 3) · course Days 11, 12 |
| **Where** | netlab-c, `topo/routed`, root |
| **Risk** | Safe |

## 1. Prerequisites

```bash
cd ~/wb/phase1-ccna-drills/topo; containerlab deploy -t routed.clab.yml --reconfigure && bash routed-setup.sh
v() { docker exec clab-p1r-$1 vtysh -c "$2"; }
c() { docker exec clab-p1r-$1 vtysh -c 'conf t' -c "$2"; }
x() { docker exec clab-p1r-$1 sh -c "$2"; }
```

## 2. Hands-on

### 2.1 Both directions, one hop at a time

```bash
x h1 'ping -c1 -W1 172.16.2.10'             # fails — predict where it dies
c r1 'ip route 172.16.2.0/24 10.0.12.2'
x h1 'ping -c1 -W1 172.16.2.10'             # still fails — capture on r2 eth2: requests reach h2. The reply?
c r2 'ip route 172.16.1.0/24 10.0.12.1'
x h1 'ping -c2 172.16.2.10'
v r1 'show ip route'                        # C = connected, S = static; [1/0] = [admin distance/metric]
```

The life of a packet, at r1, for h1 → h2: frame arrives for r1's MAC →
strip L2 → look up 172.16.2.10 → best match `172.16.2.0/24 via 10.0.12.2`
→ ARP for 10.0.12.2 on eth2 → new L2 header → TTL−1 → out. Say it aloud
once while watching `x r1 'tcpdump -nnei any -c4 icmp'`.

### 2.2 Longest-prefix match

```bash
c r1 'ip route 172.16.0.0/16 10.0.13.3'     # a broad route via r3
v r1 'show ip route 172.16.2.10'            # still the /24 via r2: more specific wins, regardless of order or distance
x r1 'ip route get 172.16.2.10'             # the kernel agrees (FRR installs into it)
c r1 'no ip route 172.16.0.0/16 10.0.13.3'
```

### 2.3 A floating static backup

Make r3 a backup path that only takes over when r1–r2 dies:

```bash
c r3 'ip route 172.16.2.0/24 10.0.23.2'; c r3 'ip route 172.16.1.0/24 10.0.13.1'
c r1 'ip route 172.16.2.0/24 10.0.13.3 10'  # distance 10: worse than the primary's 1, so not used
c r2 'ip route 172.16.1.0/24 10.0.23.3 10'
v r1 'show ip route 172.16.2.0/24'          # both listed, only the distance-1 route selected (>*)
x h1 'ping -i0.5 -c20 172.16.2.10' &
sleep 3; x r1 'ip link set eth2 down'; x r2 'ip link set eth1 down'; wait
x h1 'traceroute -n 172.16.2.10'            # via 10.0.13.3 now
x r1 'ip link set eth2 up'; x r2 'ip link set eth1 up'
```

A static route only "fails over" when its next hop becomes unreachable
(here, the link going down). If the link stayed up but r2 died, the static
route would stay and blackhole traffic — that's why drill 10 (OSPF) and
lab 4.01 (BGP + BFD) exist.

## 3. Verification

| Check | Expected |
|---|---|
| §2.1 | ping only works once **both** routes exist |
| §2.2 | /24 via r2 chosen over /16 via r3 |
| §2.3 | a few lost pings at the link-down, then replies via r3; traceroute shows 10.0.13.3 |

## 4. Break/fix

```bash
cd ~/wb/phase1-ccna-drills/05-static-routing && bash break.sh
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

**Done when** h1 reaches h2 (172.16.2.10) and every route you leave on r1 has a reason.

Solution: [`solution.md`](solution.md).

## 5. Cleanup

Keep `routed` for drill 10, or `containerlab destroy -t routed.clab.yml --cleanup`.

## 6. What I should be able to explain after this

- Every hop makes an independent decision from its own table; reachability needs a route **there and back**.
- Longest-prefix match first; administrative distance only decides between routes for the **same** prefix; metric within one source.
- A floating static (higher distance) backs up a primary only when the primary's next hop disappears; it can't detect a dead router behind a live link.
