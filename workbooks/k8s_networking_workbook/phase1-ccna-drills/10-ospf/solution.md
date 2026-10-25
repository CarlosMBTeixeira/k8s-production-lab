# Drill 10 — solution

## What was injected

<!--FAULT-->
```bash
cd "$PHASE_DIR/topo"
containerlab deploy -t routed.clab.yml --reconfigure >/dev/null && bash routed-setup.sh >/dev/null
ospf() { local r=$1 id=$2; shift 2; local a=(-c 'conf t' -c 'router ospf' -c "ospf router-id $id"); for n in "$@"; do a+=(-c "network $n area 0"); done; docker exec clab-p1r-$r vtysh "${a[@]}" >/dev/null; }
# --- the fault (before OSPF starts, as after a hardware swap) ---
docker exec clab-p1r-r2 ip link set eth1 mtu 1400
ospf r1 1.1.1.1 172.16.1.0/24 10.0.12.0/24 10.0.13.0/24 1.1.1.1/32
ospf r2 2.2.2.2 172.16.2.0/24 10.0.12.0/24 10.0.23.0/24 2.2.2.2/32
ospf r3 3.3.3.3 10.0.13.0/24 10.0.23.0/24 3.3.3.3/32
sleep 50
cat <<'T'

TICKET  After r2's NIC replacement, traffic from h1 to h2 takes the long way
        (via r3) and the r1–r2 link sits idle:
          docker exec clab-p1r-h1 traceroute -n 172.16.2.10
        OSPF is configured identically to before. r1 and r2 ping each other.
T
```
<!--/FAULT-->

r2's side of the r1–r2 link now has MTU 1400; r1's still 1500. OSPF puts
the interface MTU in its Database Description packets and refuses to
exchange databases with a neighbor whose MTU differs. The adjacency forms
hellos (2-Way) but sticks in **ExStart/Exchange** forever, so no routes are
learned over that link and traffic takes the r3 path.

| Beat | Answer |
|---|---|
| Hypothesis | Neighbors see each other but never reach Full → they disagree on something in the DBD exchange: MTU is the classic. |
| Tool | `v r1 'show ip ospf neighbor'` |
| Expected if right | r2 in `ExStart` or `Exchange`, never `Full`. |
| Tool 2 | `docker logs clab-p1r-r1 2>&1 \| grep -i mtu \| tail -2` and `x r1 'ip link show eth2'; x r2 'ip link show eth1'` |
| Expected if right | "MTU mismatch" / "MTU size is larger"; 1500 vs 1400. |
| What would have told me sooner | OSPF stuck in ExStart = MTU, every time. The real-world version: a jumbo-frame NIC on one side of a link. |

## Fix

Match the MTUs (the right fix), or tell OSPF to ignore it (`ip ospf mtu-ignore` — a workaround that hides a real data-plane mismatch):

```bash
x r2 'ip link set eth1 mtu 1500'
sleep 15; v r1 'show ip ospf neighbor'; x h1 'traceroute -n 172.16.2.10'
```
