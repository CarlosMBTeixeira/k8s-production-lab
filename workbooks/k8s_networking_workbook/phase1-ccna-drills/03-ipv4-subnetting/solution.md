# Drill 03 — solution

## What was injected

<!--FAULT-->
```bash
cd "$PHASE_DIR/topo"
containerlab deploy -t lan.clab.yml --reconfigure >/dev/null && bash lan-setup.sh >/dev/null
x() { docker exec clab-p1l-$1 sh -c "$2"; }
x r1 'sysctl -qw net.ipv4.ip_forward=1; ip addr add 10.0.10.126/25 dev eth1; ip addr add 10.0.10.254/25 dev eth1'
x h1 'ip addr flush dev eth1; ip addr add 10.0.10.1/25 dev eth1;   ip route add default via 10.0.10.126'
x h2 'ip addr flush dev eth1; ip addr add 10.0.10.2/25 dev eth1;   ip route add default via 10.0.10.126'
x h3 'ip addr flush dev eth1; ip addr add 10.0.10.130/25 dev eth1; ip route add default via 10.0.10.254'
x h4 'ip addr flush dev eth1; ip addr add 10.0.10.131/25 dev eth1; ip route add default via 10.0.10.254'
# --- the fault ---
x h2 'ip addr add 10.0.10.2/26 dev eth1; ip addr del 10.0.10.2/25 dev eth1'
cat <<'T'

TICKET  After "standardising addressing" on h2, it can still ping h1
        (10.0.10.1) but not h3 (10.0.10.130), the router, or anything else:
          docker exec clab-p1l-h2 ping -c2 10.0.10.130   → "Network is unreachable"
T
```
<!--/FAULT-->

h2 got `10.0.10.2/26` (network 10.0.10.0, hosts .1–.62). Its gateway
10.0.10.126 is **outside** that /26, so the kernel deleted the default
route when the address changed (a gateway must be on-link). h2 still
reaches h1 (.1 is inside the /26) and nothing else.

| Beat | Answer |
|---|---|
| Hypothesis | Reaches its neighbour, nothing beyond → no usable route off the subnet: missing default route or a gateway outside the subnet. |
| Tool | `x h2 'ip -br addr show eth1; ip route'` |
| Expected if right | `10.0.10.2/26`, no `default` line. Re-adding fails: `ip route add default via 10.0.10.126` → "Nexthop has invalid gateway". |
| What would have told me sooner | Subnet the host's own address first: does the gateway fall inside it? |

## Fix

```bash
x h2 'ip addr flush dev eth1; ip addr add 10.0.10.2/25 dev eth1; ip route add default via 10.0.10.126'
x h2 'ping -c1 10.0.10.1; ping -c1 10.0.10.130'
```
