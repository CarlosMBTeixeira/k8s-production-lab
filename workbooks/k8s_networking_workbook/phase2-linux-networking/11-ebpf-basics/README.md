# Lab 2.11 — eBPF basics

| | |
|---|---|
| **Objective** | Inventory the eBPF programs on a host, answer network questions with bpftrace and pwru, and drop packets with an XDP program that tcpdump can't see. |
| **Time** | 4 h (week 7) |
| **Where** | netlab-a, root |
| **Risk** | Safe — programs attach to lab veths only; `bpftrace`/`pwru` are read-only probes |

## 1. Prerequisites

- Labs 2.04, 2.07.
- Compiler for §2.4 (once): `apt-get install -y clang llvm libbpf-dev`
- `bash ../lib/topo-crs.sh up && bash ../lib/topo-crs.sh serve`
- `bpftool version` and `pwru --version` work (installed by the netlab cloud-init).

This is what Cilium is made of. You won't write Cilium; you need to read
what it loaded and know where its drops happen.

## 2. Hands-on

### 2.1 What's loaded

```bash
bpftool prog show            # id, type (cgroup_skb, xdp, sched_cls, kprobe…), name, loaded_at
bpftool map show
bpftool net show             # XDP and tc attachments per interface — the one to remember
bpftool cgroup tree | head   # systemd attaches programs to cgroups
ls /sys/fs/bpf               # pinned objects (Cilium pins maps here)
```

On a Cilium node, `bpftool net show` lists `cil_from_container` /
`cil_to_container` on every `lxc*` veth. Same command, same reading.

### 2.2 bpftrace: one-liners as questions

Run each, generate traffic in a second shell, Ctrl-C to print.

```bash
# Who changes TCP state, with which addresses? (connect, accept, close — every socket on the box)
bpftrace -e 'tracepoint:sock:inet_sock_set_state /args->protocol == 6/ {
  printf("%-15s:%-5d -> %-15s:%-5d %d -> %d\n", ntop(args->saddr), args->sport,
         ntop(args->daddr), args->dport, args->oldstate, args->newstate); }'
#   in another shell: ip netns exec client curl -s 10.2.2.2:8080

# Where are retransmits going? (add loss first: ip netns exec router tc qdisc add dev r-c root netem loss 5%)
bpftrace -e 'tracepoint:tcp:tcp_retransmit_skb { @[ntop(args->daddr), args->dport] = count(); }'
#   in another shell: ip netns exec client curl -s -o /dev/null 10.2.2.2:8080/big.bin
#   afterwards: ip netns exec router tc qdisc del dev r-c root

# Why does the kernel drop packets? (drop reasons, kernel ≥ 5.17)
ip netns exec router iptables -A FORWARD -p tcp --dport 8080 -j DROP
bpftrace -e 'tracepoint:skb:kfree_skb { @[args->reason] = count(); }'
#   ip netns exec client curl -s -m2 10.2.2.2:8080
grep -A80 'reason' /sys/kernel/tracing/events/skb/kfree_skb/format | grep -o '{ [0-9]*, "[A-Z_]*" }' | head -20   # number → name
ip netns exec router iptables -F FORWARD
```

`tracepoints` are stable kernel ABI; `kprobe:` on any function works too but
can change between kernels. That's the whole trade-off.

### 2.3 pwru: where did my packet die

```bash
ip netns exec router iptables -A FORWARD -p tcp --dport 8080 -j DROP
pwru --output-tuple 'host 10.2.2.2 and tcp dst port 8080' &
ip netns exec client curl -s -m2 10.2.2.2:8080
kill %1
ip netns exec router iptables -F FORWARD
```

The output lists every kernel function the skb went through, in order,
ending at `kfree_skb_reason(SKB_DROP_REASON_NETFILTER_DROP)` right after
`nf_hook_slow`. It works across namespaces because kprobes are global.
This is the fastest answer to "it enters and never leaves" on a node.

### 2.4 XDP: a drop before everything

```bash
cd /workbook/phase2-linux-networking/11-ebpf-basics
clang -O2 -g -target bpf -I/usr/include/$(uname -m)-linux-gnu -c xdp_drop_icmp.c -o /var/tmp/xdp_drop_icmp.o
ip -n server link set dev s1 xdpgeneric obj /var/tmp/xdp_drop_icmp.o sec xdp
ip -n server -d link show s1 | grep -i xdp          # prog/xdp id N
ip netns exec client ping -c3 -W1 10.2.2.2          # fails
ip netns exec server tcpdump -nni s1 -c3 icmp &     # predict: what does tcpdump show?
ip netns exec client ping -c3 -W1 10.2.2.2; sleep 1; kill %1
ip netns exec client curl -s 10.2.2.2:8080          # TCP still passes
sysctl -w kernel.bpf_stats_enabled=1
bpftool prog show name xdp_drop_icmp                # run_cnt rises with each packet
ip -n server link set dev s1 xdpgeneric off
```

tcpdump on `s1` shows **nothing**: XDP runs before the capture tap. A
Cilium/XDP drop is invisible to tcpdump on that interface. You need
`hubble`, `cilium monitor`, `pwru` or the program's own counters.

What tcpdump sees, by drop location:

| Dropped at | Visible to tcpdump on that interface? |
|---|---|
| XDP (ingress) | no |
| tc ingress (clsact) | yes — the tap runs before tc ingress |
| netfilter (any hook) | ingress yes / egress no |
| tc egress, qdisc | no — the egress tap runs after the qdisc |

## 3. Verification

| Check | Expected |
|---|---|
| §2.1 `bpftool net show` | empty for lab veths at first; after §2.4 `s1(…) generic id N` under xdp |
| §2.2 state tracer | `10.1.1.2:<port> -> 10.2.2.2:8080 2 -> 1` (SYN_SENT → ESTABLISHED) etc. |
| §2.2 drop reasons | the NETFILTER_DROP number dominates while the DROP rule is in place |
| §2.3 pwru | last line `kfree_skb_reason … NETFILTER_DROP` |
| §2.4 | ping fails, tcpdump shows nothing, curl works, `run_cnt` > 0 |

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

**Done when** `ip netns exec client curl -s 10.2.2.2:8080` works and you
can say at which hook, on which interface, the packet was dropped.

<details><summary>Hint (only after 20 minutes)</summary>

The packet enters the router and never leaves it, and netfilter is empty.
Use the tool from §2.3.
</details>

Solution: [`solution.md`](solution.md).

## 5. Cleanup

```bash
bash ../lib/topo-crs.sh down
sysctl -w kernel.bpf_stats_enabled=0
rm -f /var/tmp/xdp_drop_icmp.o
```

## 6. What I should be able to explain after this

- eBPF programs attach to hooks (XDP, tc ingress/egress, cgroup, socket, kprobe/tracepoint); `bpftool prog|map|net show` inventories them, and that's how you read what a CNI like Cilium has loaded.
- bpftrace answers ad-hoc questions with tracepoints (stable) and kprobes (any function); `pwru` follows one packet's skb through kernel functions to the exact drop reason.
- XDP and tc egress drop packets where tcpdump can't see them; "absent in tcpdump" is not "never arrived".
