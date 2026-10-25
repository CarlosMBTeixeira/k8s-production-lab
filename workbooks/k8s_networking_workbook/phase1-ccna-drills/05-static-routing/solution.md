# Drill 05 — solution

## What was injected

<!--FAULT-->
```bash
cd "$PHASE_DIR/topo"
containerlab deploy -t routed.clab.yml --reconfigure >/dev/null && bash routed-setup.sh >/dev/null
c() { docker exec clab-p1r-$1 vtysh -c 'conf t' -c "$2" >/dev/null; }
c r1 'ip route 172.16.2.0/24 10.0.12.2'
c r2 'ip route 172.16.1.0/24 10.0.12.1'
# --- the fault ---
c r1 'ip route 172.16.2.0/25 10.0.13.3'
cat <<'T'

TICKET  h1 can't reach h2 (172.16.2.10) since this morning. r1's
        "show ip route" clearly lists 172.16.2.0/24 via 10.0.12.2, and
        r2 has the route back. "We only added a route for the new
        servers coming next month."
T
```
<!--/FAULT-->

Someone added `172.16.2.0/25 via r3` on r1 "for the new servers" — and r3
has no route to 172.16.2.0/25. The /25 is more specific than the /24, so
it wins for 172.16.2.0–127, including h2 (.10). r3 drops them (or bounces
them, depending on what it has).

| Beat | Answer |
|---|---|
| Hypothesis | r1 "has the /24", but a more specific route might be stealing the destination. |
| Tool | `v r1 'show ip route 172.16.2.10'` (or `x r1 'ip route get 172.16.2.10'`) |
| Expected if right | `172.16.2.0/25 via 10.0.13.3`, not the /24. |
| Tool 2 | `v r3 'show ip route 172.16.2.10'` |
| Expected if right | no route (or only the connected links). |
| What would have told me sooner | Always look up the **address**, not the prefix you expect (`show ip route <ip>`): it shows the route actually chosen. |

## Fix

```bash
c r1 'no ip route 172.16.2.0/25 10.0.13.3'
x h1 'ping -c2 172.16.2.10'
```
