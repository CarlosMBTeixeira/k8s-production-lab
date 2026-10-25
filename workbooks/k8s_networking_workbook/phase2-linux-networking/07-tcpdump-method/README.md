# Lab 2.07 — tcpdump methodology

| | |
|---|---|
| **Objective** | Capture on both sides of every boundary, filter precisely, and read a TCP conversation's health (retransmits, resets, windows) from a pcap with tshark. |
| **Time** | 3 h (week 5) |
| **Where** | netlab-a, root |
| **Risk** | Safe |

## 1. Prerequisites

- Labs 2.03–2.06. `bash ../lib/topo-crs.sh up && bash ../lib/topo-crs.sh serve`

## 2. Hands-on

### 2.1 The rule: both sides of every boundary

A packet path is a chain of boundaries (veth, bridge, router, NAT, tunnel).
Capture **before and after** each one. "Present here, absent there" names
the boundary that ate it. Four captures at once, written to files:

```bash
mkdir -p /var/tmp/pcap && cd /var/tmp/pcap
ip netns exec client tcpdump -nni c-eth0 -w 1-client.pcap  tcp port 8080 &
ip netns exec router tcpdump -nni r-c    -w 2-router-in.pcap  tcp port 8080 &
ip netns exec router tcpdump -nni r-s1   -w 3-router-out.pcap tcp port 8080 &
ip netns exec server tcpdump -nni s1     -w 4-server.pcap  tcp port 8080 &
sleep 1; ip netns exec client curl -s 10.2.2.2:8080 >/dev/null; sleep 1
kill %1 %2 %3 %4
mergecap -w all.pcap 1-client.pcap 2-router-in.pcap 3-router-out.pcap 4-server.pcap
tshark -r all.pcap -T fields -e frame.time_relative -e frame.interface_name -e ip.src -e ip.dst -e tcp.flags.str 2>/dev/null | head -20
```

`-nn` (no name or port resolution: resolution itself can hang on a broken
network), `-e` adds MACs, `-w` keeps everything for later, `-s 128` cuts
payload when only headers matter.

### 2.2 Filters you will actually use

```bash
tcpdump -nni any 'tcp[tcpflags] & (tcp-syn|tcp-rst) != 0'     # only handshakes and resets
tcpdump -nni any 'icmp[icmptype] == icmp-unreach'             # every "unreachable" (incl. frag-needed)
tcpdump -nni any 'ip[6:2] & 0x4000 != 0 and greater 1400'     # DF set, big — MTU suspects
tcpdump -nni any udp port 53                                  # DNS
tcpdump -nnei any arp or icmp                                 # L2 + reachability
tcpdump -nni any -Q in host 10.2.2.2                          # inbound only (-Q in|out|inout)
```

Try each against traffic you generate. On `-i any` tcpdump prints the
interface name per packet (LINUX_SLL2 link type), which is often enough to
see the path without four captures.

### 2.3 Offloads lie (a little)

```bash
ip netns exec client curl -s -o /dev/null 10.2.2.2:8080/big.bin &
ip netns exec server tcpdump -nni s1 -c 10 'tcp src port 8080 and greater 2000'
ip netns exec server ethtool -k s1 | grep -E 'tcp-segmentation-offload|generic-segmentation'
```

You see "packets" of 30–60 KB on a 1500-MTU link: GSO/TSO hands the stack
large segments and splits them later (in the NIC, or here in the veth
driver). The capture shows the stack's view, not the wire's. Remember this
in lab 2.09 when sizes don't match the MTU.

### 2.4 Read a conversation with tshark

```bash
ip netns exec client tcpdump -nni c-eth0 -w dl.pcap tcp port 8080 &
ip netns exec client curl -s -o /dev/null 10.2.2.2:8080/big.bin; kill %1
tshark -r dl.pcap -q -z conv,tcp                       # bytes per direction, duration
tshark -r dl.pcap -q -z io,stat,1                      # packets/bytes per second
tshark -r dl.pcap -Y 'tcp.analysis.flags' | head       # retransmissions, dup ACKs, zero windows — empty here
tshark -r dl.pcap -Y 'tcp.flags.syn==1' -T fields -e tcp.options.mss_val -e tcp.window_size_value
```

### 2.5 The patterns to recognise on sight

| On the client capture | Means | Next capture |
|---|---|---|
| SYN, SYN, SYN (1 s, 2 s, 4 s …), nothing back | dropped on the way there, or the reply is lost | next hop toward the server |
| SYN → RST,ACK | reached a host with no listener (or a REJECT rule) | `ss -ltn` on the server |
| SYN → ICMP unreachable | a router or firewall refused it; the ICMP's source says which | that hop |
| SYN-ACK arrives, client sends RST | reply came from an address the client didn't call (NAT asymmetry, lab 2.05 §2.4c) | NAT hop |
| server retransmits SYN-ACK | client's ACK never reaches the server: return path | reverse direction |
| dup ACKs + retransmissions | loss in the data path | both sides of each hop, count segments |
| `[TCP ZeroWindow]` | receiver not reading: the app, not the network | `ss -tnmi` on the receiver |

## 3. Verification

| Check | Expected |
|---|---|
| §2.1 merged trace | each SYN appears 4 times (client, router in, router out, server) in time order, microseconds apart |
| §2.3 | segments larger than 1500 bytes while TSO/GSO is on |
| §2.4 `tcp.analysis.flags` | no output on a clean link |

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

**Done when** `big.bin` downloads at full speed again, and you can name the
exact interface and mechanism that caused it — with the capture that proves it.

<details><summary>Hint (only after 20 minutes)</summary>

Retransmissions mean loss. Count the server's data segments on each side
of the router. Netfilter is clean; there are other things on an interface's
egress path.
</details>

Solution: [`solution.md`](solution.md).

## 5. Cleanup

```bash
bash ../lib/topo-crs.sh down; rm -rf /var/tmp/pcap
```

## 6. What I should be able to explain after this

- Where to capture: both sides of each boundary; "seen before, not after" localises a drop to one hop in minutes.
- How to read TCP health from a capture: handshake outcome, who retransmits what, dup ACKs, RST source, zero window — and which of those are network vs application.
- What a capture does not show: GSO-sized segments instead of wire packets, nothing dropped before the capture point (XDP, tc egress before the tap, qdisc drops).
