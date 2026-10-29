# Drill 01 — solution

## What was injected

<!--FAULT-->
```bash
cd "$PHASE_DIR/topo"
containerlab deploy -t routed.clab.yml --reconfigure >/dev/null && bash routed-setup.sh >/dev/null
docker exec clab-p1r-r1 vtysh -c 'conf t' -c 'ip route 172.16.2.0/24 10.0.12.2' >/dev/null
docker exec clab-p1r-r2 vtysh -c 'conf t' -c 'ip route 172.16.1.0/24 10.0.12.1' >/dev/null
# --- the fault ---
docker exec clab-p1r-h1 sh -c 'ip route replace 172.16.0.0/12 via 172.16.1.254; ip route replace 10.0.0.0/8 via 172.16.1.254'
cat <<'T'

TICKET  h1 can't reach h2 any more:
          docker exec clab-p1r-h1 ping -c2 172.16.2.10
          → "From 172.16.1.10 icmp_seq=1 Destination Host Unreachable"
        The routers' routes are unchanged.
T
```
<!--/FAULT-->

h1's route to everything beyond its subnet now points at `172.16.1.254`,
an address nobody has. h1 ARPs for it, gets no answer, and reports
`Destination Host Unreachable` **from its own address**.

| Beat | Answer |
|---|---|
| Hypothesis | Unreachable from my own IP = I couldn't resolve the next hop's MAC (L2), not a remote router's verdict. |
| Tool | `x h1 'ip route get 172.16.2.10; ip neigh'` |
| Expected if right | `via 172.16.1.254`; `172.16.1.254 … FAILED` |
| What would have told me sooner | The source of the ICMP error: yourself = local next hop; a router's IP = that router. |

## Fix

```bash
x h1 'ip route replace 172.16.0.0/12 via 172.16.1.1; ip route replace 10.0.0.0/8 via 172.16.1.1'
x h1 'curl -s -m3 172.16.2.10'
```
