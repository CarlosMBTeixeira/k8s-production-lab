# Lab 2.03 — solution

## What was injected

<!--FAULT-->
```bash
bash "$PHASE_DIR/lib/topo-crs.sh" up
bash "$PHASE_DIR/lib/topo-crs.sh" serve
# --- the fault ---
ip -n router rule add from 10.1.1.0/24 lookup 200 priority 1000
ip -n router route add blackhole 10.2.2.0/24 table 200
cat <<'T'

TICKET  The client (10.1.1.2) can't reach the web service on 10.2.2.2:8080 —
        curl hangs. From the router itself, `curl 10.2.2.2:8080` works.
        `ip route` on the router shows 10.2.2.0/24 dev r-s1, as always.
        10.3.3.2 is reachable from the client.
T
```
<!--/FAULT-->

A policy rule sends everything **from** the client subnet to table 200,
where 10.2.2.0/24 is a blackhole. Traffic to 10.3.3.0/24 isn't in table 200,
so the lookup falls through to `main` and works. Traffic generated **on**
the router has a router source address, doesn't match the rule, and works too.

## Diagnosis path

| Beat | Answer |
|---|---|
| Hypothesis | The router drops client→10.2.2.2 before forwarding; the main table is right, so another table or a filter is involved. |
| Tool | `ip netns exec router ip route get 10.2.2.2 from 10.1.1.2 iif r-c` |
| Expected if right | Not `dev r-s1`: either a `blackhole … table 200` line or an `RTNETLINK answers` error (iproute2 versions differ). Anything but the main-table answer says another table won. |
| Tool 2 | `ip -n router rule` and `ip -n router route show table 200` |
| Expected if right | `1000: from 10.1.1.0/24 lookup 200` and `blackhole 10.2.2.0/24`. |
| What would have told me sooner | "Works from the router, fails from the client" means the decision depends on the packet's **source**. Source-dependent behaviour is policy routing or a filter, never the main table. `ip route get` with `from` and `iif` answers it in one command. |

Captures confirm it: requests on `r-c`, nothing on `r-s1`, no ICMP back
(blackhole is silent; `unreachable` or `prohibit` would have sent ICMP).

## Fix

```bash
ip -n router rule del priority 1000
ip -n router route flush table 200
ip netns exec client curl -s 10.2.2.2:8080
```

## Why it matters later

Cilium, Calico (eBPF and egress gateway), AWS VPC CNI and OVN-K EgressIP all
install policy rules and extra tables. On a node, `ip rule` is the second
command after `ip route`, every time.
