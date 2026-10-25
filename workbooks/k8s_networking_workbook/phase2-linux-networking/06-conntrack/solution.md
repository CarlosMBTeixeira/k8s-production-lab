# Lab 2.06 — solution

## What was injected

<!--FAULT-->
```bash
pkill -f conntrack-holder 2>/dev/null || true
pkill -f conntrack-sink 2>/dev/null || true
bash "$PHASE_DIR/lib/topo-crs.sh" up
bash "$PHASE_DIR/lib/topo-crs.sh" serve
R='ip netns exec router'
$R iptables -A FORWARD -m conntrack --ctstate INVALID -j DROP
[ -f /var/tmp/ct_max.orig ] || cat /proc/sys/net/netfilter/nf_conntrack_max > /var/tmp/ct_max.orig
# server: accept and hold sockets on :9000
setsid ip netns exec server python3 -c '
import socket, sys; sys.argv[0] = "conntrack-sink"
l = socket.socket(); l.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
l.bind(("0.0.0.0", 9000)); l.listen(1024); held = []
while True: held.append(l.accept()[0])
' conntrack-sink >/dev/null 2>&1 < /dev/null &
sleep 1
# --- the fault ---
# nf_conntrack_max is global on most kernels (read-only inside a netns);
# set it in both places so the fault works either way.
sysctl -qw net.netfilter.nf_conntrack_max=200
$R sysctl -qw net.netfilter.nf_conntrack_max=200 2>/dev/null || true
setsid ip netns exec client python3 -c '
import socket, time
held = []
for _ in range(260):
    try:
        s = socket.create_connection(("10.2.2.2", 9000), timeout=0.5); held.append(s)
    except OSError:
        pass
time.sleep(86400)
' conntrack-holder >/dev/null 2>&1 < /dev/null &
sleep 8
cat <<'T'

TICKET  New requests from client to http://10.2.2.2:8080 hang or time out,
        almost every time. An SSH-style session opened earlier is still fine.
        Ping 10.2.2.2 also fails now and then. Nothing was deployed today.
T
```
<!--/FAULT-->

The global `nf_conntrack_max` dropped to 200, and a client process holds
~260 idle TCP connections to the server's port 9000. Established entries are
`ASSURED`, so the kernel can't evict them early (`early_drop` only removes
non-assured entries). Once the router's table is full, every new flow's
first packet is dropped.

## Diagnosis path

| Beat | Answer |
|---|---|
| Hypothesis | New flows fail and old ones survive: something per-new-flow is exhausted in the router — conntrack. |
| Tool | `dmesg \| grep -i conntrack` |
| Expected if right | `nf_conntrack: nf_conntrack: table full, dropping packet` |
| Tool 2 | `ip netns exec router conntrack -C`; `cat /proc/sys/net/netfilter/nf_conntrack_max`; `ip netns exec router conntrack -S` |
| Expected if right | count ≈ max; `drop` (and `early_drop` attempts) rising. |
| Tool 3 | who owns the entries: `ip netns exec router conntrack -L -p tcp \| awk '{print $5,$6}' \| sort \| uniq -c \| sort -rn \| head` then `ip netns exec client ss -tnp state established` |
| Expected if right | ~260 entries `src=10.1.1.2 dst=10.2.2.2 … dport=9000`; a python3 process owning them. |
| What would have told me sooner | `nf_conntrack_count / nf_conntrack_max` as a metric (node_exporter exposes both: `node_nf_conntrack_entries` / `node_nf_conntrack_entries_limit`). An alert at 80 % fires long before the first drop. Lab 4.07 builds it. |

## Fix

```bash
sysctl -w net.netfilter.nf_conntrack_max=$(cat /var/tmp/ct_max.orig)   # restore capacity
ip netns exec router sysctl -w net.netfilter.nf_conntrack_max=$(cat /var/tmp/ct_max.orig) 2>/dev/null || true
#   ^ only matters on kernels where the limit is per-namespace; elsewhere it's read-only and this fails harmlessly
pkill -f 'conntrack-holder'                                               # stop the leak
ip netns exec client curl -s 10.2.2.2:8080
```

Raising the limit alone is half a fix: the holder is a connection leak. In
production the usual culprits are clients without keepalive reuse, a
connection-per-request library, a scanner, or a DDoS. Size `max` from
memory (~320 bytes per entry) and alert on the ratio.

## Why it matters later

Every Service connection on a node is a conntrack entry in the node's root
namespace. A busy node with the default limit, a UDP-heavy workload (DNS)
or a NodePort under a SYN flood hits this. Lab 3.06 does it on k8slab.
