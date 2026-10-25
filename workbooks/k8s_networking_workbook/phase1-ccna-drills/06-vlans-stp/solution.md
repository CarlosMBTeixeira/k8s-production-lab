# Drill 06 — solution

## What was injected

<!--FAULT-->
```bash
cd "$PHASE_DIR/topo"
containerlab deploy -t lan.clab.yml --reconfigure >/dev/null && bash lan-setup.sh >/dev/null
bash "$LAB_DIR/vlans.sh" >/dev/null
# --- the fault ---
docker exec clab-p1l-sw2 bridge vlan del dev eth3 vid 20
cat <<'T'

TICKET  After maintenance on sw2, h2 (10.0.20.2) can't reach h4 (10.0.20.4).
        Both are in VLAN 20. VLAN 10 (h1 ↔ h3) works across the same
        switches. h2 can ping its gateway 10.0.20.254.
T
```
<!--/FAULT-->

VLAN 20 was removed from sw2's side of the trunk. VLAN 10 still crosses;
VLAN 20 frames from sw1 arrive tagged 20 at a port that no longer accepts
VLAN 20, and are dropped. h2 → h4 dies; h2 → its gateway (on sw1) works.

| Beat | Answer |
|---|---|
| Hypothesis | One VLAN broken across the switches, the other fine → the trunk carries one but not the other. |
| Tool | `x sw2 'bridge vlan show dev eth3'` vs `x sw1 'bridge vlan show dev eth3'` |
| Expected if right | sw1 eth3: 10, 20 · sw2 eth3: 10 only. |
| Tool 2 | `x sw2 'tcpdump -nnei eth3 vlan 20'` while h2 pings h4 |
| Expected if right | tagged frames arrive; nothing is forwarded to eth2. |
| What would have told me sooner | Compare the allowed-VLAN list on **both ends** of every trunk (on real switches: `show interfaces trunk`). |

## Fix

```bash
x sw2 'bridge vlan add dev eth3 vid 20'
x h2 'ping -c2 10.0.20.4'; x h1 'ping -c2 10.0.10.3'
```
