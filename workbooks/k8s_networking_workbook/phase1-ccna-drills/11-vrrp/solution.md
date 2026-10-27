# Drill 11 — solution

## What was injected

<!--FAULT-->
```bash
# --- the fault: vB joined with a different VRRP group id, and was never finished ---
bash "$LAB_DIR/topo.sh" up 52 >/dev/null
ip -n vB route del 10.91.0.10/32 2>/dev/null || true
cat <<'T'

TICKET  Since a second router (vB) was added for redundancy last week,
        hosts on 10.90.0.0/24 can't reach the server (10.91.0.10):
          ip netns exec vh ping -c20 -i0.25 10.91.0.10
        vA, the original gateway, is unchanged and still routes to it.
T
```
<!--/FAULT-->

vB was configured with `virtual_router_id 52` while vA uses 51. Each
router ignores the other's adverts (different group), sees no master for
its own group, and becomes master: **both** hold 10.90.0.1 and both refresh
gratuitous ARP every 5 s. Here they started together, so their refreshes
run in step and vB's always lands last: the host's gateway MAC stays on vB.
(On a real segment the timers drift and the gateway flaps instead.) And vB
was never finished: it has **no route to the server**, hence the
`Destination Net Unreachable` from 10.90.0.3.

Two problems, one symptom: the split brain makes the untested backup
visible. Fixing only the VRID hides vB's missing route until the day vA
fails.

| Beat | Answer |
|---|---|
| Hypothesis | The new router is answering for the gateway (`Unreachable` comes from 10.90.0.3), yet vA is still healthy → both routers think they're master (split brain): they don't see each other's adverts. |
| Tool | `ip -n vA -br addr show eth0; ip -n vB -br addr show eth0` |
| Expected if right | the VIP on **both**. |
| Tool 2 | `ip netns exec vsw tcpdump -nni br0 -c4 vrrp` |
| Expected if right | adverts from both, `vrid 51 prio 150` and `vrid 52 prio 100`. |
| What would have told me sooner | Alert on "VIP present on more than one node" (or on two VRRP masters); in clouds, VRRP often fails the same way because multicast is filtered, which is why kube-vip/MetalLB use leader election instead. |

## Fix

```bash
sed -i 's/virtual_router_id 52/virtual_router_id 51/' /var/tmp/kB.conf
kill "$(cat /var/tmp/kB.pid)"; sleep 1
ip netns exec vB keepalived -P -f /var/tmp/kB.conf -p /var/tmp/kB.pid -r /var/tmp/kB-vrrp.pid
ip -n vB route add 10.91.0.10/32 via 10.91.2.2          # finish the backup
sleep 4; ip -n vB -br addr show eth0                     # VIP gone from vB: backup now
ip netns exec vh ping -c30 -i0.2 10.91.0.10 | tail -2
kill "$(cat /var/tmp/kA.pid)"; sleep 5; ip netns exec vh ping -c10 -i0.2 10.91.0.10 | tail -2   # failover really works
```
