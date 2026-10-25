# Lab 2.06 — conntrack

| | |
|---|---|
| **Objective** | Read the connection-tracking table like a log, reproduce the stale-UDP-entry bug behind kube-proxy's DNS incidents, and break a DNAT'd TCP flow by flushing conntrack mid-stream. |
| **Time** | 4 h (week 5) |
| **Where** | netlab-a, root; traffic in the `router` namespace |
| **Risk** | Safe for the hands-on. The break/fix lowers the **global** `nf_conntrack_max` on netlab-a; the solution restores it. |

## 1. Prerequisites

- Labs 2.04, 2.05.

```bash
bash ../lib/topo-crs.sh up && bash ../lib/topo-crs.sh serve
R='ip netns exec router'
$R iptables -A FORWARD -m conntrack --ctstate INVALID -j DROP   # a stateful rule switches tracking on in this netns
```

conntrack is **per network namespace**: the router's table is not the root
namespace's. A Kubernetes node's table holds every pod's forwarded flows
because they are forwarded in the node's root namespace.

## 2. Hands-on

### 2.1 The table as a log

```bash
$R conntrack -E &                                   # events; a second shell is nicer
ip netns exec client curl -s 10.2.2.2:8080 >/dev/null
kill %1
$R conntrack -L                                     # TIME_WAIT entry left behind
$R conntrack -L -p tcp --dport 8080 -o extended
```

Write the event sequence before running it: `[NEW] SYN_SENT` → `[UPDATE]
SYN_RECV` → `ESTABLISHED` → `FIN_WAIT`/`CLOSE_WAIT`/`LAST_ACK` → `TIME_WAIT`
→ `[DESTROY]` after the timeout. Each entry has two tuples: **orig** (as the
initiator sent it) and **reply** (what the reply must look like). NAT is just
a reply tuple that differs from the inverted orig tuple.

```bash
$R sysctl -a 2>/dev/null | grep -E 'nf_conntrack_(tcp_timeout_established|tcp_timeout_time_wait|udp_timeout|udp_timeout_stream|tcp_loose|count)'
cat /proc/sys/net/netfilter/nf_conntrack_max       # global limit (root ns)
$R conntrack -S                                     # per-CPU: found, invalid, insert_failed, drop, early_drop …
$R conntrack -C                                     # count in this netns
```

### 2.2 UDP has no connection, conntrack invents one

```bash
ip netns exec server socat -T5 UDP-LISTEN:5353,bind=10.2.2.2,fork,reuseaddr SYSTEM:'echo backend-A' &
ip netns exec server socat -T5 UDP-LISTEN:5353,bind=10.3.3.2,fork,reuseaddr SYSTEM:'echo backend-B' &
echo q | ip netns exec client socat -t1 - UDP:10.2.2.2:5353
$R conntrack -L -p udp                              # [ASSURED]? UNREPLIED? note the timeout column
```

### 2.3 The stale UDP entry (kube-proxy's classic)

A "Service VIP" 10.9.9.9:5353, DNAT'd to backend A:

```bash
$R iptables -t nat -A PREROUTING -d 10.9.9.9 -p udp --dport 5353 -j DNAT --to-destination 10.2.2.2
q() { echo q | ip netns exec client socat -t1 - UDP:10.9.9.9:5353,sourceport=40000; }
q                                                   # backend-A
# "backend A is replaced": move the endpoint to B
$R iptables -t nat -R PREROUTING 1 -d 10.9.9.9 -p udp --dport 5353 -j DNAT --to-destination 10.3.3.2
q; q; q                                             # predict before running
$R conntrack -L -p udp --orig-dst 10.9.9.9          # the old translation is still there, refreshed by every query
$R conntrack -D -p udp --orig-dst 10.9.9.9
q                                                   # backend-B
```

NAT rules are only consulted for the **first** packet of a flow. A client
that reuses its source port (DNS resolvers, StatsD, syslog, anything that
keeps a UDP socket open) keeps hitting the dead backend for as long as it
keeps talking. kube-proxy deletes conntrack entries for removed UDP
endpoints for exactly this reason; when that cleanup fails, CoreDNS
restarts turn into minutes of DNS timeouts. Lab 3.06 reproduces it in a cluster.

### 2.4 Flushing conntrack under a DNAT'd TCP flow

```bash
$R iptables -t nat -A PREROUTING -d 10.9.9.9 -p tcp --dport 7000 -j DNAT --to-destination 10.2.2.2
ip netns exec server socat TCP-LISTEN:7000,reuseaddr SYSTEM:'while sleep 2; do date; done' &
ip netns exec client socat - TCP:10.9.9.9:7000 &    # prints a date every 2 s
sleep 5
ip netns exec client tcpdump -nni c-eth0 -c6 tcp port 7000 &
$R conntrack -F                                     # predict: what happens on the next server push?
sleep 5
```

The next segment from the server creates a **new** entry in the reply
direction with no NAT (`tcp_loose=1` lets conntrack pick up mid-stream
flows). It reaches the client with source 10.2.2.2, which matches no socket,
so the client answers with RST and the stream dies. Try `$R sysctl -w
net.netfilter.nf_conntrack_tcp_loose=0` and repeat: now the mid-stream
packet is INVALID and the rule in §1 drops it — the stream hangs instead.

## 3. Verification

| Check | Expected |
|---|---|
| §2.1 events | the TCP state sequence above, ending in `[DESTROY]` |
| §2.3 after moving the rule | `backend-A` until `conntrack -D`, then `backend-B` |
| §2.3 `conntrack -L` | `src=10.1.1.2 dst=10.9.9.9 sport=40000 dport=5353 … src=10.2.2.2 dst=10.1.1.2` |
| §2.4 capture | `10.2.2.2.7000 > 10.1.1.2.x` then `10.1.1.2.x > 10.2.2.2.7000: Flags [R]` |

## 4. Break/fix

```bash
bash break.sh      # rebuilds the topology, starts some background traffic, injects a fault
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

**Done when** new connections from client to `10.2.2.2:8080` succeed every
time, you found the process responsible, and the global limit is back at
its original value (the payload saved it to `/var/tmp/ct_max.orig`).

<details><summary>Hint (only after 20 minutes)</summary>

Existing connections are fine; only new ones fail. What does the kernel
need to create for every new connection, and is there room?
</details>

Solution: [`solution.md`](solution.md).

## 5. Cleanup

```bash
pkill -f 'socat' || true
bash ../lib/topo-crs.sh down
[ -f /var/tmp/ct_max.orig ] && sysctl -w net.netfilter.nf_conntrack_max=$(cat /var/tmp/ct_max.orig)
```

## 6. What I should be able to explain after this

- Every tracked flow has an orig and a reply tuple; NAT is recorded in the reply tuple, and only the first packet of a flow sees the nat table.
- UDP "connections" live as long as packets keep refreshing them, so a DNAT change doesn't reach a client that reuses its source port until the entry is deleted.
- Flushing conntrack under NAT breaks established flows (RST with `tcp_loose=1`, silent drop with `tcp_loose=0` plus an INVALID rule); the table is full when `nf_conntrack_count` reaches `nf_conntrack_max`, and then new flows drop.
