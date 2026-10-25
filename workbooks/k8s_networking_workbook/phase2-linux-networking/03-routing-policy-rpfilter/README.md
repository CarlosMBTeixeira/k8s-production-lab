# Lab 2.03 — Routing, policy routing and rp_filter

| | |
|---|---|
| **Objective** | Turn a namespace into a router, then break and fix an asymmetric path with `rp_filter` and source-based policy routing. |
| **Time** | 4 h (week 2) |
| **Where** | netlab-a, root |
| **Risk** | Safe — namespaces only |

## 1. Prerequisites

- Labs 2.01, 2.02. Phase 1 drill 05 (static routing).

## 2. Hands-on

### 2.1 Build client / router / server by hand

This is the topology [`../lib/topo-crs.sh`](../lib/topo-crs.sh) builds for later labs. Build it yourself once.

```
client                 router                       server
c-eth0 10.1.1.2/24 ── r-c   10.1.1.1/24
                       r-s1 10.2.2.1/24 ────────── s1 10.2.2.2/24
                       r-s2 10.3.3.1/24 ────────── s2 10.3.3.2/24
```

```bash
for n in client router server; do ip netns add $n; ip -n $n link set lo up; done
ip link add c-eth0 netns client type veth peer name r-c  netns router
ip link add r-s1   netns router type veth peer name s1   netns server
ip link add r-s2   netns router type veth peer name s2   netns server
ip -n client addr add 10.1.1.2/24 dev c-eth0
ip -n router addr add 10.1.1.1/24 dev r-c
ip -n router addr add 10.2.2.1/24 dev r-s1
ip -n router addr add 10.3.3.1/24 dev r-s2
ip -n server addr add 10.2.2.2/24 dev s1
ip -n server addr add 10.3.3.2/24 dev s2
for l in "client c-eth0" "router r-c" "router r-s1" "router r-s2" "server s1" "server s2"; do
  set -- $l; ip -n $1 link set $2 up
done
```

### 2.2 Make it route — one missing piece at a time

Predict each failure before running it.

```bash
ip netns exec client ping -c1 -W1 10.2.2.2     # 1: "Network is unreachable" — no route in client
ip -n client route add default via 10.1.1.1
ip netns exec client ping -c1 -W1 10.2.2.2     # 2: silence
ip netns exec router sysctl net.ipv4.ip_forward   # 0: router drops forwarded packets
ip netns exec router sysctl -w net.ipv4.ip_forward=1
ip netns exec client ping -c1 -W1 10.2.2.2     # 3: still silence — capture on s1: requests arrive. Why no reply?
ip -n server route                             # only connected routes: no way back to 10.1.1.0/24
ip -n server route add default via 10.2.2.1
ip netns exec client ping -c1 10.2.2.2         # 4: works
```

`ip_forward` is per namespace. Each step is a real incident: missing default
route, forwarding disabled on a new node, no return route.

### 2.3 Ask the kernel instead of guessing

```bash
ip netns exec router ip route get 10.2.2.2
ip netns exec router ip route get 10.2.2.2 from 10.1.1.2 iif r-c   # the forwarding decision, exactly
ip netns exec server ip route get 10.1.1.2 from 10.3.3.2           # which way would a reply from s2 go?
ip -n router route show table all | head -20                       # local, main, default tables
ip -n router rule                                                  # 0 local · 32766 main · 32767 default
```

`ip route get … from … iif …` simulates a forwarded packet. Use it before
touching a routing table.

### 2.4 Asymmetric path and rp_filter

```bash
ip netns exec router sysctl net.ipv4.conf.all.rp_filter net.ipv4.conf.r-s1.rp_filter
# effective value = max(conf.all, conf.<iface>): with r-s1 at 2, all=1 alone stays loose
ip netns exec router sysctl -w net.ipv4.conf.all.rp_filter=1 net.ipv4.conf.r-s1.rp_filter=1   # strict
ip netns exec router sysctl -w net.ipv4.conf.all.log_martians=1
ip netns exec server sysctl -w net.ipv4.conf.all.rp_filter=2    # loose, so the server accepts on s2

ip netns exec client ping -c3 -W1 10.3.3.2                      # write your prediction first
```

Follow it with three captures: `s2` (request arrives), `s1` (reply leaves —
by the **default route**, sourced 10.3.3.2), router `r-s1` (reply arrives).
Then:

```bash
ip netns exec router nstat -az TcpExtIPReversePathFilter       # rising
dmesg | grep -i martian | tail -3                              # "martian source 10.1.1.2 from 10.3.3.2, on dev r-s1"
```

Strict rp_filter drops a packet if the route **back** to its source doesn't
use the interface it came in on. Loose (`2`) only requires that some route
exists. The effective value is `max(conf.all, conf.<iface>)`.

### 2.5 Fix it properly: source-based policy routing

Don't loosen the router. Make the server reply out of the interface that
owns the source address:

```bash
ip -n server rule add from 10.3.3.2 lookup 100
ip -n server route add default via 10.3.3.1 dev s2 table 100
ip -n server rule
ip netns exec server ip route get 10.1.1.2 from 10.3.3.2        # now via s2
ip netns exec client ping -c3 10.3.3.2                           # works, rp_filter still strict
```

This is how multi-NIC nodes, Multus secondary networks and some cloud
setups (AWS VPC CNI secondary ENIs) keep replies symmetric.

## 3. Verification

| Check | Expected |
|---|---|
| §2.2 step 4 | `0% packet loss` |
| `ip netns exec router ip route get 10.2.2.2 from 10.1.1.2 iif r-c` | `10.2.2.2 from 10.1.1.2 dev r-s1 … iif r-c` |
| §2.4 before the fix | 100 % loss to 10.3.3.2; martian log line; `IPReversePathFilter` counter > 0 |
| §2.5 after the fix | `ip rule` shows `from 10.3.3.2 lookup 100`; ping 10.3.3.2 works |

## 4. Break/fix

```bash
bash break.sh          # rebuilds the topology with lib/topo-crs.sh, starts HTTP on the server, injects a fault
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

**Done when** `ip netns exec client curl -s 10.2.2.2:8080` returns
`hello from server`, and `ip route` on the router was never the problem.

<details><summary>Hint (only after 20 minutes)</summary>

The main table is not the only table. One command shows which table a
given packet is looked up in.
</details>

Solution: [`solution.md`](solution.md).

## 5. Cleanup

```bash
bash ../lib/topo-crs.sh down
```

## 6. What I should be able to explain after this

- A router is a stack with `ip_forward=1` and routes both ways; most "can't reach" incidents are a missing return route, not a missing forward route.
- Policy routing: `ip rule` picks a table by source, mark, interface or more, *before* any route lookup; `ip route get … from … iif …` is the only way to see the real decision.
- Strict `rp_filter` drops asymmetric returns silently (counter `IPReversePathFilter`, martian logs); multi-homed hosts need source-based rules, not a looser filter.
