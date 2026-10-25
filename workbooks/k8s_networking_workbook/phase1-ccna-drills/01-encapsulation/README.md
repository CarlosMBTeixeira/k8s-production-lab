# Drill 01 — Encapsulation, layer by layer

| | |
|---|---|
| **Objective** | Capture one HTTP request at three points of a routed path and say, for every header, which fields change at each hop and why. |
| **Time** | 1.5 h (week 1) · course Days 1, 3, 12 |
| **Where** | netlab-c, `topo/routed`, root |
| **Risk** | Safe — containers |

## 1. Prerequisites

```bash
sudo -i; cp -r /workbook ~/wb 2>/dev/null; cd ~/wb/phase1-ccna-drills/topo
containerlab deploy -t routed.clab.yml && bash routed-setup.sh
v() { docker exec clab-p1r-$1 vtysh -c "$2"; }
x() { docker exec clab-p1r-$1 sh -c "$2"; }
cap() { ip netns exec clab-p1r-$1 tcpdump "${@:2}"; }   # netlab-c's tcpdump inside a node's netns (the FRR image has none)
```

## 2. Hands-on

Give the path h1 → r1 → r2 → h2 routes (drill 05 explains them):

```bash
docker exec clab-p1r-r1 vtysh -c 'conf t' -c 'ip route 172.16.2.0/24 10.0.12.2'
docker exec clab-p1r-r2 vtysh -c 'conf t' -c 'ip route 172.16.1.0/24 10.0.12.1'
x h1 'curl -s 172.16.2.10'            # hello from h2
```

Capture the same request at three points, then compare:

```bash
cap h1 -nnei eth1 -c 6 -w /tmp/h1.pcap tcp port 80 &
cap r1 -nnei eth2 -c 6 -w /tmp/r1r2.pcap tcp port 80 &
cap h2 -nnei eth1 -c 6 -w /tmp/h2.pcap tcp port 80 &
sleep 1; x h1 'curl -s 172.16.2.10 >/dev/null'; wait   # pcaps land in netlab-c's /tmp
for f in h1 r1r2 h2; do echo "== $f"; tshark -r /tmp/$f.pcap -c1 -T fields -e eth.src -e eth.dst -e ip.src -e ip.dst -e ip.ttl -e ip.checksum -e tcp.srcport -e tcp.dstport; done
tshark -r /tmp/h1.pcap -c1 -V | less         # every field of one SYN, per layer
```

Fill this table from the output before reading the rest:

| Field | h1's link | r1–r2 link | h2's link | Why |
|---|---|---|---|---|
| Ethernet src/dst | | | | |
| IP src/dst | | | | |
| IP TTL | | | | |
| IP header checksum | | | | |
| TCP ports | | | | |
| HTTP payload | | | | |

Then answer: what does a **switch** change in a frame? (Nothing.) What
does a **router** change? (L2 header entirely, TTL, IP checksum — and
nothing above L3, unless it NATs.)

Map the stack you just saw to the two models once, in your own words:
OSI 7 layers vs TCP/IP 4 (link, internet, transport, application). In
Kubernetes you'll say "L4" (Services, kube-proxy) and "L7" (Gateway,
mesh) — that's the vocabulary this drill grounds.

## 3. Verification

| Check | Expected |
|---|---|
| curl from h1 | `hello from h2` |
| table | MACs differ per link; IPs and ports identical; TTL 64 → 63 → 62; checksum changes with TTL |

## 4. Break/fix

```bash
cd ~/wb/phase1-ccna-drills/01-encapsulation && bash break.sh
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

**Done when** `x h1 'curl -s -m3 172.16.2.10'` works again.

Solution: [`solution.md`](solution.md).

## 5. Cleanup

```bash
containerlab destroy -t ~/wb/phase1-ccna-drills/topo/routed.clab.yml --cleanup   # or keep it for drills 04, 05, 10
```

## 6. What I should be able to explain after this

- Encapsulation: application data inside TCP inside IP inside Ethernet; each layer has its own addressing (ports, IPs, MACs).
- Per hop, a router rewrites the L2 header and decrements TTL (recomputing the IP checksum); end-to-end, IP addresses and ports stay the same unless something NATs.
- A switch forwards frames without changing them; that's the difference between L2 and L3 forwarding you'll use in every capture.
