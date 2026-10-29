# Drill 12 — IPv6 basics

| | |
|---|---|
| **Objective** | Run a dual-stack segment and route, and see what IPv6 does differently from IPv4: link-local addresses, Neighbor Discovery instead of ARP, multicast instead of broadcast, and no fragmentation by routers. |
| **Time** | 1.5 h (week 7) · course: IPv6 (the address types, NDP, SLAAC basics) |
| **Where** | netlab-a, root |
| **Risk** | Safe |

## 1. Prerequisites

```bash
cd /workbook/phase1-ccna-drills/12-ipv6 && bash topo.sh up
A='ip netns exec h6a'; B='ip netns exec h6b'; R='ip netns exec r6'
```

## 2. Hands-on

### 2.1 Addresses you didn't configure

```bash
ip -n h6a -6 addr show eth0          # fd00:1::10/64 (global-ish, ULA) AND fe80::…/64 scope link (automatic)
ip -n h6a -6 maddr show dev eth0     # multicast groups: ff02::1 (all nodes), ff02::1:ff00:10 (solicited-node)
ip -n h6a -6 route                   # fd00:1::/64 dev eth0, fe80::/64 dev eth0, default via fd00:1::1
```

Every IPv6 interface has a link-local address; routers and NDP use them.
ULA `fd00::/8` is IPv6's "private" range (like 10/8); global unicast is 2000::/3.

### 2.2 Neighbor Discovery, not ARP

```bash
$A tcpdump -nni eth0 -c4 icmp6 &
sleep 1; ip -n h6a -6 neigh flush all; $A ping -6 -c1 fd00:1::1 >/dev/null; wait
ip -n h6a -6 neigh
```

Neighbor Solicitation goes to the **solicited-node multicast** address
`ff02::1:ff00:1` (derived from the target's last 24 bits), not to a
broadcast; the target answers with a Neighbor Advertisement. It's ICMPv6
(type 135/136) — which is why "block ICMP" breaks IPv6 completely.
(Router Advertisements, type 134, are how SLAAC hands out prefixes and
default routers; this drill sets addresses statically.)

### 2.3 Routing and dual stack

```bash
$A ping -6 -c2 fd00:2::10; $A ping -c2 10.6.2.10
$A traceroute -6 -n fd00:2::10
$B python3 -m http.server 8080 --bind :: >/dev/null 2>&1 &
sleep 1; $B ss -ltn | grep 8080                # *:8080 — one socket, both families
$A curl -s -o /dev/null -w '%{http_code}\n' 'http://[fd00:2::10]:8080/'
$A curl -s -o /dev/null -w '%{http_code}\n' http://10.6.2.10:8080/
kill %1
```

Without `--bind ::` Python's server listens on `0.0.0.0:8080` only and the
IPv6 curl fails: a dual-stack socket is something the application asks for
(an `AF_INET6` socket on `::` with `IPV6_V6ONLY` off).

### 2.4 No fragmentation in the network

```bash
ip -n r6 link set r-b mtu 1400; ip -n h6b link set eth0 mtu 1400
$A ping -6 -c1 -s 1452 fd00:2::10         # "Packet too big: mtu=1400" from fd00:1::1
ip -n h6a -6 route get fd00:2::10         # … mtu 1400: PMTU learned
ip -n r6 link set r-b mtu 1500; ip -n h6b link set eth0 mtu 1500
```

IPv6 routers never fragment: oversized packets are dropped with ICMPv6
"Packet Too Big", and PMTUD is mandatory. Minimum MTU is 1280. Lab 2.09's
blackhole is worse in IPv6, because there's no "just fragment it" fallback.

## 3. Verification

| Check | Expected |
|---|---|
| §2.1 | an `fe80::` address and solicited-node multicast groups on every interface |
| §2.2 | NS to `ff02::1:ff00:1`, NA back; neighbour entry REACHABLE |
| §2.3 | both families reach h6b; one `*:8080` socket serves both |
| §2.4 | Packet too big, mtu 1400; PMTU cached in the route |

## 4. Break/fix

```bash
bash break.sh
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

**Done when** `$A curl -s -m3 'http://[fd00:2::10]:8080/'` works, `ip -n r6 -6 neigh show dev r-b`
shows h6b REACHABLE, and h6b is still "hardened" in a way that makes sense
(if that means "no ping", `ping -6` to it failing is correct).

Solution: [`solution.md`](solution.md).

## 5. Cleanup

```bash
bash topo.sh down
```

## 6. What I should be able to explain after this

- IPv6 address types (link-local `fe80::/10`, ULA `fd00::/8`, global `2000::/3`, multicast `ff00::/8`) and that every interface has a link-local address.
- NDP (NS/NA via solicited-node multicast, RS/RA for SLAAC) replaces ARP and DHCP's router option — all ICMPv6, so ICMPv6 must not be blocked wholesale.
- Routers don't fragment IPv6; Packet Too Big + PMTUD always; dual-stack sockets serve both families.
