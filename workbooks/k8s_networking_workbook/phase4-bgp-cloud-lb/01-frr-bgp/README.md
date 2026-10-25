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
docker exec clab-bgp-h1 traceroute -n 172.16.3.10
```

The state machine: **Idle → Connect** (TCP SYN to 179) **→ Active**
(TCP failed, retrying/listening) **→ OpenSent → OpenConfirm → Established**.
"Active" sounds healthy and means the opposite: no TCP session.

### 2.2 The messages on the wire

```bash
docker exec clab-bgp-r2 tcpdump -nni eth2 -w /tmp/bgp.pcap tcp port 179 &
v r2 'clear bgp 10.0.23.3'           # hard reset: new TCP session, new OPEN
sleep 12; kill %1
docker cp clab-bgp-r2:/tmp/bgp.pcap /tmp/bgp.pcap
tshark -r /tmp/bgp.pcap -Y bgp -T fields -e frame.time_relative -e ip.src -e bgp.type -e bgp.open.myas -e bgp.open.holdtime -e bgp.update.path_attribute.as_path -e bgp.nlri_prefix
```

Types: 1 OPEN (AS, hold time, router-id, capabilities), 2 UPDATE (path
attributes + NLRI or withdrawals), 3 NOTIFICATION (error → session reset),
4 KEEPALIVE every 3 s.

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
docker exec clab-bgp-h1 traceroute -n 172.16.3.10
```

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
v r1 'show bgp neighbors 10.0.12.2 received-routes'    # everything r2 sent (needs soft-reconfiguration inbound)
v r1 'show bgp neighbors 10.0.12.2 routes'             # what survived the filter: no 2.2.2.2/32, no 3.3.3.3/32
v r2 'show bgp neighbors 10.0.12.1 advertised-routes'  # r2's view of what it sent
```

`le 24` matters: without it the list matches exactly 172.16.0.0/16 and
nothing else. A filter that silently drops everything is the most common
BGP change incident.

### 2.6 Fast failure detection with BFD

```bash
docker exec clab-bgp-r1 vtysh -c 'conf t' -c 'router bgp 65001' -c 'neighbor 10.0.13.3 bfd'
docker exec clab-bgp-r3 vtysh -c 'conf t' -c 'router bgp 65003' -c 'neighbor 10.0.13.1 bfd'
v r1 'show bfd peers brief'
docker exec clab-bgp-r1 tc qdisc add dev eth2 root netem loss 100%     # the direct link "fails" silently
for i in $(seq 12); do date +%T.%N | cut -c1-12; v r1 'show bgp ipv4 unicast 172.16.3.0/24' | grep -A1 -m1 best; sleep 0.5; done
#   note when the best path flips from 10.0.13.3 to 10.0.12.2; then repeat without BFD (no neighbor … bfd) and compare
docker exec clab-bgp-r1 tc qdisc del dev eth2 root
```

Without BFD, BGP notices after the hold timer (9 s here, 90–180 s with
default timers). BFD notices in ~1 s (300 ms × 3). MetalLB, Calico and
Cilium all support BFD to the fabric for this reason.

## 3. Verification

| Check | Expected |
|---|---|
| §2.1 | all sessions Established; h1 → h2 via r2 (3 hops) |
| §2.2 | OPEN with `myas` 65002/65003, hold 9; UPDATEs with AS paths; KEEPALIVEs every ~3 s |
| §2.3 | best path direct (AS path `65003`) |
| §2.4 | prepend → via r2; local-pref 200 → direct again |
| §2.5 | `routes` shows only 172.16.x prefixes |
| §2.6 | BFD peer Up; failover in ~1 s instead of 9 s |

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

- The BGP FSM and what each stuck state means: Idle (not trying/administratively down or no route), Connect/Active (no TCP: reachability, port 179 filtered, wrong IP, MD5), OpenSent/OpenConfirm (TCP up, OPEN rejected: AS, router-id, capabilities).
- Best-path selection order and its two practical levers: local-pref (your egress choice) and AS-path prepend/MED (others' choice of how to reach you); prefix-lists with `ge`/`le` as the first line of defence.
- Why hold timers are too slow for failover and BFD exists.
