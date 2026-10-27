# Drill 10 — OSPF basics with FRR

| | |
|---|---|
| **Objective** | Replace drill 05's static routes with OSPF: form adjacencies, read the link-state database, steer with cost, and watch it reconverge — the dynamic routing every fabric under Kubernetes runs. |
| **Time** | 2 h (week 6) · course: dynamic routing, OSPF (RIP/EIGRP skipped) |
| **Where** | netlab-c, `topo/routed`, root |
| **Risk** | Safe |

## 1. Prerequisites

- Drill 05.

```bash
cd ~/wb/phase1-ccna-drills/topo; containerlab deploy -t routed.clab.yml --reconfigure && bash routed-setup.sh
v() { docker exec clab-p1r-$1 vtysh -c "$2"; }
x() { docker exec clab-p1r-$1 sh -c "$2"; }
cap() { ip netns exec clab-p1r-$1 tcpdump "${@:2}"; }   # netlab-c's tcpdump inside a node's netns (the FRR image has none)
ospf() { # router router-id networks...
  local r=$1 id=$2; shift 2; local args=(-c 'conf t' -c 'router ospf' -c "ospf router-id $id")
  for n in "$@"; do args+=(-c "network $n area 0"); done
  docker exec clab-p1r-$r vtysh "${args[@]}"
}
```

## 2. Hands-on

### 2.1 Bring up area 0

```bash
ospf r1 1.1.1.1 172.16.1.0/24 10.0.12.0/24 10.0.13.0/24 1.1.1.1/32
ospf r2 2.2.2.2 172.16.2.0/24 10.0.12.0/24 10.0.23.0/24 2.2.2.2/32
ospf r3 3.3.3.3 10.0.13.0/24 10.0.23.0/24 3.3.3.3/32
sleep 45                                     # default timers: hello 10 s, dead 40 s; DR election waits
v r1 'show ip ospf neighbor'                 # Full/DR, Full/Backup …
v r1 'show ip route ospf'                    # O routes to h2's subnet, r3's loopback, …
x h1 'traceroute -n 172.16.2.10'             # via r2 (cost 10+10 beats 10+10+10)
```

Neighbor states: Down → Init (I heard you) → 2-Way (you heard me) →
ExStart/Exchange (agree who leads, swap database summaries) → Loading →
**Full**. On a broadcast segment one router is DR, one BDR; others stay 2-Way
with each other.

### 2.2 The database every router shares

```bash
v r1 'show ip ospf database'                 # Router LSAs (one per router), Network LSAs (one per DR segment)
v r1 'show ip ospf database router 3.3.3.3'  # r3's links and costs, exactly as r1 knows them
cap r1 -nni eth2 -c3 ip proto 89     # hellos to 224.0.0.5 (AllSPFRouters)
```

Every router holds the same map and runs Dijkstra on it independently —
link state, versus BGP's path vector (lab 4.01).

### 2.3 Cost and failover

```bash
docker exec clab-p1r-r1 vtysh -c 'conf t' -c 'interface eth2' -c 'ip ospf cost 100'
sleep 5; x h1 'traceroute -n 172.16.2.10'    # now via r3: 172.16.1.1, 10.0.13.3, 10.0.12.2, h2
docker exec clab-p1r-r1 vtysh -c 'conf t' -c 'interface eth2' -c 'no ip ospf cost'
for r in r1:eth2 r2:eth1; do docker exec clab-p1r-${r%%:*} vtysh -c 'conf t' -c "interface ${r#*:}" -c 'ip ospf hello-interval 1' -c 'ip ospf dead-interval 3'; done
x h1 'ping -i0.2 -c50 172.16.2.10' | tail -2 &
sleep 2; x r2 'ip link set eth1 down'; wait   # loss ≈ dead interval… or instant, if the link-down is detected locally
x r2 'ip link set eth1 up'
```

In the cost-100 traceroute, r2 shows up as **10.0.12.2**, not 10.0.23.2: a
router answers traceroute from the interface it uses to reach the sender,
and r2's own best path back to h1 is still the direct r1–r2 link. The
return path is not the forward path.

A link that goes **down** is noticed at once; a neighbor that silently
stops talking is noticed after the dead interval — the same lesson as BFD
in lab 4.01.

## 3. Verification

| Check | Expected |
|---|---|
| §2.1 | three Full adjacencies; `O` routes for every remote subnet; h1 → h2 via r2 |
| §2.2 | 3 router LSAs in the database; hellos every 10 s on 224.0.0.5 |
| §2.3 | cost 100 moves the path to r3; failover loses 0 to a few pings (both veth ends see the link go down at once) |

## 4. Break/fix

```bash
cd ~/wb/phase1-ccna-drills/10-ospf && bash break.sh
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

**Done when** r1 and r2 are Full with each other and h1 → h2 goes via r2 again.

Solution: [`solution.md`](solution.md).

## 5. Cleanup

```bash
containerlab destroy -t ~/wb/phase1-ccna-drills/topo/routed.clab.yml --cleanup
```

## 6. What I should be able to explain after this

- OSPF neighbor states through Full, DR/BDR on broadcast segments, hellos and the dead interval.
- Link-state: every router floods LSAs, holds the same database and runs SPF; cost (default from bandwidth, settable per interface) picks the path.
- Adjacency failure modes: mismatched area, hello/dead timers, subnet/mask, **MTU** (stuck in ExStart/Exchange), authentication.
