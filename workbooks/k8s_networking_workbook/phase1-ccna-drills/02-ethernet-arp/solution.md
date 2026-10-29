# Drill 02 — solution

## What was injected

<!--FAULT-->
```bash
cd "$PHASE_DIR/topo"
containerlab deploy -t lan.clab.yml --reconfigure >/dev/null && bash lan-setup.sh >/dev/null
H1MAC=$(docker exec clab-p1l-h1 cat /sys/class/net/eth1/address)
# --- the fault ---
docker exec clab-p1l-h4 sh -c "ip link set eth1 address $H1MAC; (nohup ping -i 0.3 10.0.10.3 >/dev/null 2>&1 &)"
cat <<'T'

TICKET  On the lan topology, h2 → h1 loses lots of packets, on and off:
          docker exec clab-p1l-h2 ping -c20 -i0.2 10.0.10.1
        h2 → h3 is perfect. No interface errors anywhere. "Someone
        re-imaged h4 this morning."
T
```
<!--/FAULT-->

h4 now uses **h1's MAC address** and keeps sending traffic. Both switches
see that MAC arrive alternately from h1's port and from the h4 side, and
keep re-learning it ("MAC flapping"). Frames for h1 are delivered to
whichever port was learned last — half of h2's pings go to h4.

| Beat | Answer |
|---|---|
| Hypothesis | Intermittent loss to one host on a flat L2, no errors on links → the switches deliver some frames elsewhere: a MAC conflict or loop. |
| Tool | `x sw1 'bridge monitor fdb'` **while h2 pings h1** (or repeat `bridge fdb show br br0 \| grep <h1 MAC>`) |
| Expected if right | h1's MAC flipping between `eth1` and `eth3`. |
| Tool 2 | `for h in h1 h2 h3 h4; do echo "$h $(x $h 'cat /sys/class/net/eth1/address')"; done` |
| Expected if right | h1 and h4 have the same MAC. |
| What would have told me sooner | MAC-flap logs / FDB churn on switches (real switches log "MAC move"); in VMs, cloned images with fixed MACs are the usual cause. |

## Fix

```bash
x h4 'pkill ping; ip link set eth1 address 02:42:0a:00:0a:04'
x h1 'arping -c1 -U -I eth1 10.0.10.1'     # re-teach both switches where h1's MAC lives
x h2 'ping -c20 -i0.2 10.0.10.1' | tail -2
```

The GARP is part of the fix. Without it the switches can keep h1's MAC
pointed at the h4 side: h2's pings go there, h1 never receives them, so h1
never sends the reply that would correct the FDB, and the loss continues
until the entry ages out (300 s). Any frame from h1 corrects it; a GARP is
the deliberate one, and it is what a real failover or NIC swap relies on.
Removing a duplicate is not finished until the tables that learned it have
been corrected.
