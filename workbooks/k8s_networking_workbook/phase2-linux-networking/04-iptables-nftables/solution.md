# Lab 2.04 — solution

## What was injected

<!--FAULT-->
```bash
bash "$PHASE_DIR/lib/topo-crs.sh" up
bash "$PHASE_DIR/lib/topo-crs.sh" serve
R='ip netns exec router'
$R iptables -A FORWARD -p tcp --dport 8080 -j ACCEPT
$R iptables -A FORWARD -p icmp -j ACCEPT
# --- the fault ---
$R nft add table inet edge
$R nft add chain inet edge pre '{ type filter hook prerouting priority -150; policy accept; }'
$R nft add rule inet edge pre 'tcp dport 8080 tcp flags & (syn|ack) == syn drop'
cat <<'T'

TICKET  client → http://10.2.2.2:8080 hangs. Ping 10.2.2.2 works.
        The network team checked the router:
          ip netns exec router iptables -L -v -n        → ACCEPT 8080, ACCEPT icmp
          ip netns exec router iptables -t mangle -L    → empty
        "The firewall is open. Must be the app."
T
```
<!--/FAULT-->

A native nftables table, `inet edge`, hooks prerouting at priority -150
(mangle's slot) and drops TCP SYNs to 8080. `iptables -L` (any table)
cannot show it: iptables-nft only displays the `ip filter`/`nat`/`mangle`/
`raw` tables it manages.

## Diagnosis path

| Beat | Answer |
|---|---|
| Hypothesis | ICMP passes and TCP/8080 doesn't, so it is a port-specific filter on the path, not routing. |
| Tool | Captures: `ip netns exec router tcpdump -nni r-c tcp port 8080` and on `r-s1` |
| Expected if right | SYNs arrive on `r-c`, never leave on `r-s1`, no RST back: dropped inside the router. |
| Tool 2 | `ip netns exec router nft list ruleset` |
| Expected if right | A table besides `ip filter` with a `drop` matching 8080. |
| Tool 3 (if the ruleset were huge) | trace chain at priority -350 + `nft monitor trace` |
| Expected if right | the last trace line: `inet edge pre rule … tcp dport 8080 … drop (verdict drop)` |
| What would have told me sooner | "iptables shows nothing" on a modern distro proves nothing. SYN in, nothing out, no RST = local netfilter drop: go straight to `nft list ruleset`. |

## Fix

```bash
ip netns exec router nft delete table inet edge
ip netns exec client curl -s 10.2.2.2:8080
```

## Why it matters later

kube-proxy's nftables mode (lab 3.03) lives in `table ip kube-proxy`, and
Calico/Cilium can install their own tables or bypass netfilter entirely
with eBPF. On a node, `iptables-save | wc -l` is a sanity check, never a
complete answer.
