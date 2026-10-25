# Drill 04 — solution

## What was injected

<!--FAULT-->
```bash
cd "$PHASE_DIR/topo"
containerlab deploy -t routed.clab.yml --reconfigure >/dev/null && bash routed-setup.sh >/dev/null
docker exec clab-p1r-r1 vtysh -c 'conf t' -c 'ip route 172.16.2.0/24 10.0.12.2' >/dev/null
docker exec clab-p1r-r2 vtysh -c 'conf t' -c 'ip route 172.16.1.0/24 10.0.12.1' >/dev/null
# --- the fault ---
docker exec clab-p1r-r1 vtysh -c 'conf t' -c 'ip route 0.0.0.0/0 10.0.12.2' >/dev/null
docker exec clab-p1r-r2 vtysh -c 'conf t' -c 'ip route 0.0.0.0/0 10.0.12.1' >/dev/null
cat <<'T'

TICKET  "We added default routes on both routers so 'everything is reachable'."
        Now h1 → 172.16.99.10 (a network that doesn't exist yet) gives:
          docker exec clab-p1r-h1 ping -c1 172.16.99.10
          → "Time to live exceeded"
        and the routers' CPU graphs spike whenever someone typos an address.
T
```
<!--/FAULT-->

Both routers got a **default route pointing at each other**. For any
destination neither knows (172.16.99.10), r1 sends to r2, r2 sends back to
r1, … until TTL hits 0. The client sees "Time to live exceeded" and a
traceroute alternating between the two routers.

| Beat | Answer |
|---|---|
| Hypothesis | TTL exceeded for an unknown destination = a routing loop, not a missing route (which gives "net unreachable" or silence). |
| Tool | `x h1 'traceroute -n -m 8 172.16.99.10'` |
| Expected if right | hops alternate `172.16.1.1`, `10.0.12.2`, `10.0.12.1`, `10.0.12.2`, … |
| Tool 2 | `docker exec clab-p1r-r1 vtysh -c 'show ip route 172.16.99.10'` and the same on r2 |
| Expected if right | r1: default via 10.0.12.2; r2: default via 10.0.12.1. |
| What would have told me sooner | Two defaults that point at each other is the classic static-routing loop: a default route belongs toward the exit, never back the way you came. |

## Fix

Remove the default from the router that isn't the exit (here: both — there is no exit):

```bash
docker exec clab-p1r-r1 vtysh -c 'conf t' -c 'no ip route 0.0.0.0/0 10.0.12.2'
docker exec clab-p1r-r2 vtysh -c 'conf t' -c 'no ip route 0.0.0.0/0 10.0.12.1'
docker exec clab-p1r-r1 vtysh -c 'conf t' -c 'ip route 0.0.0.0/0 reject'   # optional: answer "unreachable" explicitly
x h1 'ping -c1 172.16.99.10'; x h1 'curl -s 172.16.2.10'
```
