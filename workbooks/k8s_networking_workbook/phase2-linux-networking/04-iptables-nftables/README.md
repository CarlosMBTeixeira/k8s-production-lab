# Lab 2.04 — iptables, nftables and packet tracing

| | |
|---|---|
| **Objective** | Filter forwarded traffic with iptables and with native nftables, prove which rule saw a packet, and learn why `iptables -L` is not the whole truth. |
| **Time** | 4 h (week 2) |
| **Where** | netlab-a, root, inside the `router` namespace |
| **Risk** | Safe — all rules live in the router namespace |

## 1. Prerequisites

- Lab 2.03.
- `bash ../lib/topo-crs.sh up && bash ../lib/topo-crs.sh serve`

Shorthand for this lab: `R='ip netns exec router'`.

## 2. Hands-on

### 2.1 Which iptables is this?

```bash
R='ip netns exec router'
iptables -V                         # "(nf_tables)": iptables-nft, a front end that writes nftables rules
update-alternatives --display iptables
$R iptables -S                      # empty, policies ACCEPT
$R nft list ruleset                 # empty too — nothing created yet
```

### 2.2 Hooks, by counting

```bash
$R iptables -A FORWARD -p tcp --dport 8080 -j ACCEPT
$R iptables -A FORWARD -p icmp -j ACCEPT
ip netns exec client curl -s 10.2.2.2:8080 >/dev/null
ip netns exec client ping -c2 10.2.2.2 >/dev/null
$R iptables -L FORWARD -v -n --line-numbers   # pkts/bytes per rule
$R nft list ruleset                           # the same rules, as nft wrote them: table ip filter, chain FORWARD
```

Now watch which hooks a forwarded packet crosses vs a packet **to** the router.
Netfilter logging from a non-root namespace is muted by default, so unmute it
first (root-ns sysctl on this throwaway VM):

```bash
sysctl -w net.netfilter.nf_log_all_netns=1
for c in PREROUTING INPUT FORWARD OUTPUT POSTROUTING; do
  $R iptables -t mangle -A $c -j LOG --log-prefix "lab-$c " 2>/dev/null || true
done
ip netns exec client ping -c1 10.2.2.2         # forwarded
ip netns exec client ping -c1 10.1.1.1         # local to the router
dmesg | grep lab- | tail -12
$R iptables -t mangle -F
```

Expected: forwarded = PREROUTING → FORWARD → POSTROUTING; local = PREROUTING
→ INPUT, and the reply OUTPUT → POSTROUTING. Draw it. Every Kubernetes
datapath question is "which of these five hooks, in which table".

### 2.3 The same policy in native nftables

```bash
$R iptables -F
$R nft add table inet lab
$R nft add chain inet lab forward '{ type filter hook forward priority 0; policy drop; }'
$R nft add rule inet lab forward ct state established,related accept
$R nft add rule inet lab forward iifname r-c tcp dport 8080 ct state new counter accept
$R nft add rule inet lab forward iifname r-c icmp type echo-request counter accept
$R nft add rule inet lab forward counter log prefix '"lab-drop "'
$R nft -a list table inet lab                  # -a shows rule handles
ip netns exec client curl -s 10.2.2.2:8080     # works
ip netns exec server curl -s -m2 10.1.1.2:22   # server → client: new, not from r-c → dropped and logged
```

### 2.4 Two tables on one hook

```bash
$R iptables -A FORWARD -p tcp --dport 8080 -j ACCEPT
$R nft add rule inet lab forward tcp dport 8080 drop   # appended — after the accept, so no effect yet
$R nft -a list chain inet lab forward
```

Insert a drop **before** the accept in `inet lab`, keep the iptables ACCEPT,
and predict: does the iptables ACCEPT win? (No. An `accept` ends evaluation
in *that* chain only; every other base chain on the hook still runs. A
`drop` anywhere is final.) Prove it, then delete the rule by handle:
`$R nft delete rule inet lab forward handle <n>`.

### 2.5 Tracing — the tool for "which rule ate my packet"

```bash
$R nft add chain inet lab trace '{ type filter hook prerouting priority -350; }'
$R nft add rule inet lab trace ip saddr 10.1.1.2 tcp dport 8080 meta nftrace set 1
$R nft monitor trace &               # in a second shell is nicer
ip netns exec client curl -s 10.2.2.2:8080 >/dev/null
kill %1
```

Each line names table, chain, rule handle and verdict, in order, across every
table — including tables iptables created. With iptables-legacy you'd use
`-t raw -j TRACE`; with nft you never need to.

## 3. Verification

| Check | Expected |
|---|---|
| §2.2 counters | the ACCEPT rules' `pkts` increase by the packets you sent |
| §2.2 LOG | forwarded ping logs PREROUTING, FORWARD, POSTROUTING only |
| §2.3 | curl works; server→client SYN shows `lab-drop` in `dmesg`; the final rule's counter > 0 |
| §2.4 | a drop in `inet lab` before the accept blocks 8080 despite iptables' ACCEPT |
| §2.5 | `nft monitor trace` prints `rule … verdict accept` lines for both `ip filter FORWARD` and `inet lab forward` |

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

**Done when** `ip netns exec client curl -s 10.2.2.2:8080` works and ping
still works, and you removed only the offending rule.

<details><summary>Hint (only after 20 minutes)</summary>

`iptables` only shows the tables iptables owns.
</details>

Solution: [`solution.md`](solution.md).

## 5. Cleanup

```bash
bash ../lib/topo-crs.sh down     # rules live in the router netns and die with it
```

## 6. What I should be able to explain after this

- The five netfilter hooks and the path a forwarded vs a local packet takes; tables (filter, nat, mangle, raw) are just chains attached to hooks at different priorities.
- iptables-nft writes nftables rules into tables named `ip filter`, `ip nat`… Other software (Docker, firewalld, Cilium, kube-proxy nftables mode) creates its own tables that `iptables -L` never shows. `nft list ruleset` is the ground truth.
- Verdicts: `accept` ends one base chain; every base chain on the hook still runs; `drop` anywhere is final. `nft monitor trace` shows the full path with handles.
