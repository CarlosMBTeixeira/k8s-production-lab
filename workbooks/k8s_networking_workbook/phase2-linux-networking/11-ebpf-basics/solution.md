# Lab 2.11 — solution

## What was injected

<!--FAULT-->
```bash
bash "$PHASE_DIR/lib/topo-crs.sh" up
bash "$PHASE_DIR/lib/topo-crs.sh" serve
modprobe cls_flower 2>/dev/null || true
# --- the fault ---
ip netns exec router tc qdisc add dev r-s1 clsact
ip netns exec router tc filter add dev r-s1 egress protocol ip flower ip_proto tcp dst_port 8080 action drop
cat <<'T'

TICKET  client → http://10.2.2.2:8080 hangs; ping 10.2.2.2 works.
        On the router: `nft list ruleset` is empty, iptables is empty.
        tcpdump on r-c shows the client's SYNs arriving.
        tcpdump on r-s1 shows nothing leaving toward the server.
        "The router is eating packets and there's no rule for it."
T
```
<!--/FAULT-->

A tc **egress** filter on the router's server-facing interface drops TCP to
port 8080. It runs before the qdisc and before tcpdump's egress tap, so
captures on `r-s1` show nothing leaving, and there is no netfilter rule to find.

## Diagnosis path

| Beat | Answer |
|---|---|
| Hypothesis | SYNs enter the router (`r-c`), don't leave (`r-s1`), netfilter is empty → dropped by something else in the router's datapath: tc or BPF. |
| Tool | `pwru --output-tuple 'host 10.2.2.2 and tcp dst port 8080'` during a curl (as in §2.3: to a file, wait ~10 s for it to attach, then `grep -B3 kfree_skb_reason`) |
| Expected if right | the trace passes `ip_forward` and `ip_finish_output2`, reaches `__dev_queue_xmit` → `tc_run` → `tcf_classify` → `tcf_action_exec`, then `kfree_skb_reason(SKB_DROP_REASON_TC_EGRESS)` (kernel 6.8). |
| Tool 2 | `ip netns exec router tc filter show dev r-s1 egress` (and `bpftool net show` inside the netns for BPF ones) |
| Expected if right | `flower … ip_proto tcp dst_port 8080 … action order 1: gact action drop` |
| What would have told me sooner | `tc -s filter show` / `tc qdisc show` on both interfaces of the hop where the packet vanishes, right after `nft list ruleset`. And the table from §2.4: "not on the egress capture" includes "dropped by tc egress". |

## Fix

```bash
ip netns exec router tc filter del dev r-s1 egress
ip netns exec router tc qdisc del dev r-s1 clsact
ip netns exec client curl -s 10.2.2.2:8080
```

## Why it matters later

Cilium's datapath is tc (and optionally XDP) programs on every pod veth and
on the node's NICs. When Cilium drops, `iptables` is empty and tcpdump on
the veth is incomplete — `hubble observe --verdict DROPPED` and
`cilium-dbg monitor --type drop` are the equivalent of this pwru trace (lab 3.08).
