# Lab 4.01 — BGP with FRR

| | |
|---|---|
| **Objective** | Bring up eBGP between three FRR routers, read every session state and message, steer traffic with AS-path prepending and local-pref, filter with prefix-lists, and detect failure fast with BFD. |
| **Time** | 5 h (week 19) |
| **Where** | netlab-c (Docker + Containerlab), root |
| **Risk** | Safe — containers on netlab-c |

## 1. Prerequisites

- Phase 1 drill 10 (OSPF) or any routing basics; lab 2.03.
- `bash setup/netlab.sh up c` (from the WSL host), then on netlab-c:

```bash
sudo -i
cp -r /workbook/phase4-bgp-cloud-lb ~/p4 && cd ~/p4/01-frr-bgp    # local copy: Docker can't bind-mount from the sshfs share reliably
containerlab deploy -t topo.clab.yml
v() { docker exec clab-bgp-$1 vtysh -c "$2"; }                    # v r1 'show bgp summary'
```

## 2. Hands-on

### 2.1 Sessions

```bash
v r2 'show bgp summary'              # two neighbors, State/PfxRcd = number → Established
v r2 'show bgp neighbors 10.0.23.3' | sed -n '1,25p'   # state, timers (datacenter profile: keepalive 3 s, hold 9 s), capabilities
v r1 'show bgp ipv4 unicast'         # 172.16.3.0/24 via 10.0.12.2, path 65002 65003
docker exec clab-bgp-h1 ping -c2 172.16.3.10
docker exec clab-bgp-h1 traceroute -n 172.16.3.10   # 172.16.1.1, 10.0.12.2, 10.0.23.3, 172.16.3.10
```

Neighbors print as `r3(10.0.23.3)`: FRR learns the peer's hostname from the
Hostname capability. Each router's `eth0` is Containerlab's management
network, and its `default via 172.20.20.1` route is not part of the lab.

The state machine: **Idle → Connect** (SYN sent to 179, waiting) **→ Active**
(the connect failed, e.g. RST; retrying and listening) **→ OpenSent →
OpenConfirm → Established**. Neither "Connect" nor "Active" means a TCP
session exists. Stuck in **Connect** means the SYNs get no answer at all
(dropped silently: firewall DROP, MD5 mismatch). Flapping into **Active**
means they are refused.

### 2.2 The messages on the wire

```bash
rm -f /tmp/bgp.pcap                  # tcpdump writes it as user tcpdump; fs.protected_regular=2 then denies root a re-run ("Permission denied")
ip netns exec clab-bgp-r2 tcpdump -nni eth2 -w /tmp/bgp.pcap tcp port 179 &   # host tcpdump, r2's netns (no tcpdump in the FRR image)
v r2 'clear bgp 10.0.23.3'           # hard reset: new TCP session, new OPEN
sleep 12; kill %1
tshark -r /tmp/bgp.pcap -Y bgp -T fields -e frame.time_relative -e ip.src -e bgp.type -e bgp.open.myas \
  -e bgp.open.holdtime -e bgp.update.path_attribute.as_path_segment.as4 -e bgp.nlri_prefix
tshark -r /tmp/bgp.pcap -Y 'bgp.type == 3' -T fields -e ip.src -e tcp.srcport -e tcp.dstport \
  -e bgp.notify.major_error -e bgp.notify.minor_error_cease
```

Types: 1 OPEN (AS, hold time, router-id, capabilities), 2 UPDATE (path
attributes + NLRI or withdrawals), 3 NOTIFICATION (error → session reset),
4 KEEPALIVE every 3 s. Both sessions negotiate 4-byte AS numbers, so the
path is in `…as_path_segment.as4`. Several messages can share one frame, so
fields come out comma-joined.

What you should see:
- **NOTIFICATION Cease (6) / 9, Hard Reset** from r2: that's the `clear`.
- **Two OPENs from each side**, then a **Cease / 7, Connection Collision
  Resolution**. Both routers reconnected at the same moment, so there were
  two TCP sessions, and BGP closes one of them (RFC 4271 §6.8).
- **UPDATEs** in both directions. r2 even sends r3's own prefixes back with
  path `65002,65003`. eBGP doesn't filter on the sending side; r3 drops them
  because it finds its own AS in the path.

### 2.3 A second path and best-path selection

Add the r1–r3 session on the direct link:

```bash
docker exec clab-bgp-r1 vtysh -c 'conf t' -c 'router bgp 65001' -c 'neighbor 10.0.13.3 remote-as 65003'
docker exec clab-bgp-r3 vtysh -c 'conf t' -c 'router bgp 65003' -c 'neighbor 10.0.13.1 remote-as 65001'
sleep 5; v r1 'show bgp ipv4 unicast 172.16.3.0/24'
```

Two paths; `>` best = AS path `65003` (length 1) over `65002 65003`. The
order FRR applies (subset you'll actually use): weight → **local-pref** →
locally originated → **AS-path length** → origin → **MED** → eBGP over iBGP
→ IGP metric → router-id.

### 2.4 Steering

Make the direct path less attractive from r3's side (outbound prepend):

```bash
docker exec clab-bgp-r3 vtysh -c 'conf t' \
  -c 'route-map PREPEND permit 10' -c 'set as-path prepend 65003 65003' -c 'exit' \
  -c 'router bgp 65003' -c 'address-family ipv4 unicast' -c 'neighbor 10.0.13.1 route-map PREPEND out'
v r3 'clear bgp 10.0.13.1 soft out'; sleep 3
v r1 'show bgp ipv4 unicast 172.16.3.0/24'                       # best via r2 now
docker exec clab-bgp-h1 traceroute -n 172.16.3.10                # hop 3 is 10.0.13.3, not 10.0.23.3
```

Hop 3 answering from `10.0.13.3` isn't a mistake. The prepend only changed
r1's choice towards r3. r3 still reaches h1 over the direct link, and it
sources its ICMP Time Exceeded from that egress interface. The forward and
return paths are now different.

Now override it on r1 (inbound local-pref beats any AS-path length):

```bash
docker exec clab-bgp-r1 vtysh -c 'conf t' \
  -c 'route-map PREFER-DIRECT permit 10' -c 'set local-preference 200' -c 'exit' \
  -c 'router bgp 65001' -c 'address-family ipv4 unicast' -c 'neighbor 10.0.13.3 route-map PREFER-DIRECT in'
v r1 'clear bgp 10.0.13.3 soft in'; sleep 3
v r1 'show bgp ipv4 unicast 172.16.3.0/24'                       # direct again, LocPrf 200
```

Prepend influences **others'** inbound traffic to you; local-pref controls
**your** outbound choice. That's the whole of BGP traffic engineering in
two lines.

### 2.5 Filtering

```bash
docker exec clab-bgp-r1 vtysh -c 'conf t' \
  -c 'ip prefix-list FROM-R2 seq 10 permit 172.16.0.0/16 le 24' \
  -c 'router bgp 65001' -c 'address-family ipv4 unicast' \
  -c 'neighbor 10.0.12.2 soft-reconfiguration inbound' -c 'neighbor 10.0.12.2 prefix-list FROM-R2 in'
v r1 'clear bgp 10.0.12.2 soft in'; sleep 2
v r1 'show bgp ipv4 unicast neighbors 10.0.12.2 received-routes'    # everything r2 sent (needs soft-reconfiguration inbound)
v r1 'show bgp ipv4 unicast neighbors 10.0.12.2 filtered-routes'    # what the prefix-list dropped: 1.1.1.1, 2.2.2.2, 3.3.3.3 /32s
v r1 'show bgp ipv4 unicast neighbors 10.0.12.2 routes'             # what was accepted: only 172.16.3.0/24
v r2 'show bgp ipv4 unicast neighbors 10.0.12.1 advertised-routes'  # r2's view of what it sent
```

The address family is required here: plain `show bgp neighbors X
received-routes` answers "% No such neighbor or address family".

`received-routes` lists 5 prefixes, including r1's own `1.1.1.1/32` and
`172.16.1.0/24` with path `65002 65001`. `172.16.1.0/24` passes the
prefix-list, but it isn't in `routes`: r1 rejects it because its own AS is
in the path. Prefix filtering and loop detection are separate steps.

`le 24` matters: without it the list matches exactly 172.16.0.0/16 and
nothing else. A filter that silently drops everything is the most common
BGP change incident.

### 2.6 Fast failure detection with BFD

```bash
docker exec clab-bgp-r1 vtysh -c 'conf t' -c 'router bgp 65001' -c 'neighbor 10.0.13.3 bfd'
docker exec clab-bgp-r3 vtysh -c 'conf t' -c 'router bgp 65003' -c 'neighbor 10.0.13.1 bfd'
v r1 'show bfd peers brief'                                            # 10.0.13.1 → 10.0.13.3 up
nh() { for i in $(seq 30); do echo "$(date +%T.%N | cut -c1-12) $(v r1 'show ip route 172.16.3.0/24' | grep -m1 -o '[0-9.]*, via eth[0-9]')"; sleep 0.5; done | uniq -f1 -c; }
date +%T.%N | cut -c1-12; docker exec clab-bgp-r1 tc qdisc add dev eth2 root netem loss 100%   # the direct link "fails" silently
nh                                                                     # ~15 s of samples; note when 10.0.13.3 → 10.0.12.2
docker exec clab-bgp-r1 tc qdisc del dev eth2 root
```

Now without BFD:

```bash
docker exec clab-bgp-r1 vtysh -c 'conf t' -c 'router bgp 65001' -c 'no neighbor 10.0.13.3 bfd'
docker exec clab-bgp-r3 vtysh -c 'conf t' -c 'router bgp 65003' -c 'no neighbor 10.0.13.1 bfd'
v r1 'clear bgp 10.0.13.3'
until v r1 'show ip route 172.16.3.0/24' | grep -q '10.0.13.3, via'; do sleep 1; done; echo "direct again"
date +%T.%N | cut -c1-12; docker exec clab-bgp-r1 tc qdisc add dev eth2 root netem loss 100%
nh
docker exec clab-bgp-r1 tc qdisc del dev eth2 root
```

The `clear` is required. After a BFD-triggered failure, FRR 10.2 parks the
session in **Idle** (`Last reset … BFD down received`). If you remove the BFD
config before BFD comes back Up, nothing restarts the session, even though
the link is healthy. Wait for the direct route before failing the link,
otherwise you measure the reset, not the failure. Measured on netlab-c: about 1.1 s with BFD and about 8.3 s
without it.

Without BFD, BGP notices after the hold timer (9 s here, 90–180 s with
default timers). BFD notices in ~1 s (300 ms × 3). MetalLB, Calico and
Cilium all support BFD to the fabric for this reason.

## 3. Verification

| Check | Expected |
|---|---|
| §2.1 | all sessions Established; h1 → h2 via r2 (3 hops) |
| §2.2 | Cease/9 Hard Reset; OPENs with `myas` 65002/65003, hold 9 (twice each, then Cease/7 collision); UPDATEs with AS paths; KEEPALIVEs every ~3 s |
| §2.3 | best path direct (AS path `65003`) |
| §2.4 | prepend → via r2; local-pref 200 → direct again |
| §2.5 | `received-routes` 5 prefixes (3 filtered); `filtered-routes` the three /32s; `routes` only 172.16.3.0/24 |
| §2.6 | BFD peer up; next hop flips to 10.0.12.2 in ~1 s with BFD, ~8–9 s (hold timer) without |

## 4. Break/fix

```bash
bash break.sh          # redeploys the base topology, then changes one router
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

**Done when** `v r2 'show bgp summary'` shows both sessions Established and
h1 reaches h2, with r3's change understood (keep it or remove it, but
both ends must agree).

<details><summary>Hint (only after 20 minutes)</summary>

Is there a TCP session at all? Capture port 179, and remember the routers
share netlab-c's kernel — its log sees what they don't.
</details>

Solution: [`solution.md`](solution.md).

## 5. Cleanup

```bash
containerlab destroy -t topo.clab.yml --cleanup
```

## 6. What I should be able to explain after this

- The BGP FSM and what each stuck state means: Idle (not trying/administratively down or no route), Connect (SYNs unanswered — silently dropped: firewall DROP, MD5) vs Active (connect failed — refused, wrong IP), OpenSent/OpenConfirm (TCP up, OPEN rejected: AS, router-id, capabilities).
- Best-path selection order and its two practical levers: local-pref (your egress choice) and AS-path prepend/MED (others' choice of how to reach you); prefix-lists with `ge`/`le` as the first line of defence.
- Why hold timers are too slow for failover and BFD exists.
