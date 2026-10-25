# Lab 2.07 — solution

## What was injected

<!--FAULT-->
```bash
bash "$PHASE_DIR/lib/topo-crs.sh" up
bash "$PHASE_DIR/lib/topo-crs.sh" serve
modprobe sch_netem 2>/dev/null || true
R='ip netns exec router'
# --- the fault ---
$R tc qdisc add dev r-c root handle 1: prio
$R tc qdisc add dev r-c parent 1:3 handle 30: netem delay 20ms loss 3%
$R tc filter add dev r-c parent 1:0 protocol ip prio 1 u32 \
    match ip protocol 6 0xff match ip sport 8080 0xffff flowid 1:3
cat <<'T'

TICKET  Downloading http://10.2.2.2:8080/big.bin (20 MB) from the client takes
        ages — a few hundred KB/s. index.html loads instantly. Ping is clean
        (sub-millisecond, 0% loss). The router has no iptables or nft rules.
        Measure:  ip netns exec client curl -s -o /dev/null -w '%{speed_download}\n' 10.2.2.2:8080/big.bin
T
```
<!--/FAULT-->

A `prio` qdisc on the router's client-facing interface sends TCP traffic
**from port 8080** into a netem band with 20 ms delay and 3 % loss. Ping,
small requests and anything not sourced from :8080 are untouched.

Throughput with loss is roughly `MSS / RTT × 1.22 / √p` (Mathis):
1448 B / 0.02 s × 1.22 / 0.17 ≈ 0.5 MB/s. That's the number you measured.

## Diagnosis path

| Beat | Answer |
|---|---|
| Hypothesis | Throughput collapse with clean ping = loss and/or latency on the data path only, somewhere between server and client. |
| Tool | a client capture of the download, then `tshark -r client.pcap -Y tcp.analysis.retransmission \| wc -l` and `tshark -r client.pcap -Y tcp.analysis.ack_rtt -T fields -e tcp.analysis.ack_rtt \| sort -n \| tail -3` |
| Expected if right | dozens of retransmissions within a few seconds; `tcp.analysis.ack_rtt` in the tens of ms (20 ms netem delay plus queueing in netem's backlog; 40–60 ms measured) instead of µs. Capture with `-s 128` so tcpdump itself doesn't drop. |
| Tool 2 | count server data segments on `r-s1` (router in) and `r-c` (router out) over the same 5 s |
| Expected if right | fewer on `r-c` (~3 %), and `r-c` timestamps ~20 ms later than `r-s1` for the same `tcp.seq`. The router loses and delays them **on egress**, after routing and netfilter. |
| Tool 3 | `ip netns exec router tc -s qdisc show dev r-c` and `tc filter show dev r-c` |
| Expected if right | `qdisc netem 30: … delay 20ms loss 3%` with a `dropped` counter rising; a u32 filter matching sport 8080. |
| What would have told me sooner | `tc -s qdisc` on every hop is a 2-second check that people skip because they think of tc as "QoS stuff". A RTT that differs between ping and TCP is the tell that something classifies traffic. |

Note the capture on `r-c` can't show the dropped packets at all: tcpdump's
egress tap runs **after** the qdisc. Missing-on-egress is the evidence.

## Fix

```bash
ip netns exec router tc qdisc del dev r-c root
ip netns exec client curl -s -o /dev/null -w '%{speed_download}\n' 10.2.2.2:8080/big.bin
```

## Why it matters later

Bandwidth plugins (`kubernetes.io/egress-bandwidth` annotations via the CNI
bandwidth plugin), Cilium's bandwidth manager and cloud NIC shaping all sit
on egress qdiscs. "Slow but not broken" on one pod or node: check tc.
