# Lab 2.09 — MTU and PMTUD

| | |
|---|---|
| **Objective** | Watch Path MTU Discovery work, break it into a blackhole by filtering ICMP, and fix it three ways (allow ICMP, MSS clamping, PLPMTUD). |
| **Time** | 3 h (week 6) |
| **Where** | netlab-a, root |
| **Risk** | Safe — namespaces only |

## 1. Prerequisites

- Labs 2.07, 2.08 (§2.2 there is the overlay version of this lab).

```bash
bash topo.sh up && bash topo.sh serve
```

```
mc ── r1 ══(MTU 1400)══ r2 ── ms
10.1.1.2            10.2.2.2 (HTTP :8080, big.bin)
```

The 1400 link stands for any tunnel, VPN or overlay in the path.

## 2. Hands-on

### 2.1 PMTUD working

```bash
ip netns exec ms ping -c2 -M do -s 1472 10.1.1.2    # 1472 + 8 ICMP + 20 IP = 1500
ip netns exec ms ip route get 10.1.1.2              # "cache expires … mtu 1400"
ip netns exec ms tracepath -n 10.1.1.2              # pmtu 1400 at hop 2
ip -n ms route flush cache
```

`-M do` sets DF. r2 can't forward 1500 bytes onto a 1400 link with DF, so it
drops the packet and sends **ICMP type 3 code 4 "fragmentation needed",
next-hop MTU 1400** to the sender. The sender caches the PMTU for that
destination (10 minutes) and sends smaller packets.

TCP relies on the same signal. Watch it:

```bash
ip netns exec mr2 tcpdump -nni r2-s 'icmp or (tcp and greater 1400)' -c 8 &
ip netns exec mc curl -s -o /dev/null -w '%{http_code} %{size_download}\n' 10.2.2.2:8080/big.bin
```

### 2.2 The blackhole

Someone "hardens" r2 by dropping ICMP it originates:

```bash
ip netns exec mr2 iptables -A OUTPUT -p icmp --icmp-type fragmentation-needed -j DROP
ip -n ms route flush cache
ip netns exec mc curl -s -m10 10.2.2.2:8080/              # small: works
ip netns exec mc curl -s -m10 -o /dev/null -w '%{http_code}\n' 10.2.2.2:8080/big.bin   # predict
```

Capture on `r2-s` while it hangs: the server retransmits full-size
segments forever; no ICMP comes back. The handshake, the request and the
response headers fit; the first full data segment doesn't. "Connects, then
hangs" is the PMTUD-blackhole signature.

### 2.3 Three fixes

Apply each, verify, then remove it before trying the next.

**(a) Let the ICMP through.** The right fix.
`ip netns exec mr2 iptables -D OUTPUT -p icmp --icmp-type fragmentation-needed -j DROP`

**(b) MSS clamping** where the SYN enters the small link (r1, client side):

```bash
ip netns exec mr1 iptables -t mangle -A FORWARD -o r1-w -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
ip netns exec mc tcpdump -nni eth0 -c1 -v 'tcp[tcpflags] == tcp-syn' &   # the SYN as sent
ip netns exec ms tcpdump -nni eth0 -c1 -v 'tcp[tcpflags] == tcp-syn' &   # the SYN as received
sleep 1
ip netns exec mc curl -s -o /dev/null -w '%{http_code}\n' 10.2.2.2:8080/big.bin
```

The client still says MSS 1460; the server receives 1360 (1400 − 40). The
server never sends a segment that needs PMTUD. This is what VPN gateways,
cloud NAT gateways and many CNIs do.

**(c) Let TCP find it without ICMP** (PLPMTUD, RFC 4821):

```bash
ip netns exec ms sysctl -w net.ipv4.tcp_mtu_probing=1
ip -n ms route flush cache
ip netns exec mc curl -s -o /dev/null -w '%{http_code} %{time_total}\n' 10.2.2.2:8080/big.bin
```

Slower to start (it waits for a timeout, then probes smaller), but it
survives a blackhole.

## 3. Verification

| Check | Expected |
|---|---|
| §2.1 | `Frag needed and DF set (mtu = 1400)` from 10.2.2.1; `ip route get` shows `mtu 1400` |
| §2.2 | small request 200; big.bin hangs until `-m10` (exit code 28) |
| §2.3 a, b, c | big.bin `200 20971520` each time |
| §2.3 b capture on ms | `mss 1360` in the SYN |

## 4. Break/fix

```bash
bash break.sh      # rebuilds this topology, injects a fault (no iptables involved this time)
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

**Done when** big.bin downloads and `ip netns exec ms ping -c2 -M do -s 1472
10.1.1.2` either succeeds or returns "Frag needed".

<details><summary>Hint (only after 20 minutes)</summary>

No ICMP anywhere, and nothing is filtering. Who decides an ICMP frag-needed
should be sent — and what does that router believe the next link's MTU is?
</details>

Solution: [`solution.md`](solution.md).

## 5. Cleanup

```bash
bash topo.sh down
```

## 6. What I should be able to explain after this

- PMTUD: DF set, router drops and sends ICMP 3/4 with the next-hop MTU, sender caches it per destination; filtering that ICMP creates a blackhole where connections establish and then hang on the first full-size segment.
- MSS clamping rewrites the MSS option in SYNs crossing the small link so endpoints never send oversized segments; PLPMTUD (`tcp_mtu_probing`) recovers without ICMP at the cost of a slow start.
- A link whose two ends disagree on MTU is a silent blackhole with no ICMP at all — the router that should send it thinks the packet fits.
