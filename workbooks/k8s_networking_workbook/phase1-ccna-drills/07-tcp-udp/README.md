# Drill 07 — TCP and UDP on the wire

| | |
|---|---|
| **Objective** | Read a TCP connection's life from a capture (handshake, data, close), tell refused from filtered from timed out at a glance, and see how little UDP gives you. |
| **Time** | 1.5 h (week 5) · course: TCP & UDP |
| **Where** | netlab-a, root, Phase 2's client/router/server namespaces |
| **Risk** | Safe |

## 1. Prerequisites

```bash
cd /workbook/phase2-linux-networking && bash lib/topo-crs.sh up && bash lib/topo-crs.sh serve
C='ip netns exec client'; S='ip netns exec server'
```

## 2. Hands-on

### 2.1 One connection, start to finish

```bash
$C tcpdump -nni c-eth0 -S -c 12 tcp port 8080 &
sleep 1; $C curl -s 10.2.2.2:8080 >/dev/null; wait
```

Label each line: `[S]` SYN (client ISN, options: mss, sackOK, TS, wscale),
`[S.]` SYN-ACK (server ISN, ack = client ISN+1), `[.]` ACK, `[P.]` data
(seq advances by `length`), `[F.]` FIN from whoever closes first, final ACKs.
`-S` shows absolute sequence numbers; without it tcpdump shows relative ones.

```bash
$C ss -tan state time-wait | head      # the side that closed first holds TIME_WAIT (2×MSL)
$C sysctl net.ipv4.ip_local_port_range # the client's ephemeral ports
```

### 2.2 Refused vs filtered vs timed out

```bash
$C curl -s -m3 10.2.2.2:9999; echo "exit=$?"        # nothing listens → RST → exit 7, instant
$S iptables -A INPUT -p tcp --dport 9998 -j DROP
$C curl -s -m3 10.2.2.2:9998; echo "exit=$?"        # silently dropped → exit 28 after 3 s
$S iptables -A INPUT -p tcp --dport 9997 -j REJECT --reject-with icmp-port-unreachable
$C curl -s -m3 10.2.2.2:9997; echo "exit=$?"        # ICMP unreachable → exit 7, instant
$S iptables -F INPUT
```

Capture each once (`$C tcpdump -nni c-eth0 -c4 'tcp or icmp'`). The client
tells you which by **how fast** it fails and **what came back**: RST,
ICMP, or nothing.

```bash
$C sysctl net.ipv4.tcp_syn_retries net.ipv4.tcp_syn_linear_timeouts   # 6 and 4 (kernel ≥ 6.5)
$S iptables -A INPUT -p tcp --dport 9998 -j DROP
$C tcpdump -nni c-eth0 -ttt -c5 'tcp[tcpflags] == tcp-syn' & $C curl -s -m20 10.2.2.2:9998; wait   # predict the gaps
$C sysctl -w net.ipv4.tcp_syn_linear_timeouts=0
$C tcpdump -nni c-eth0 -ttt -c5 'tcp[tcpflags] == tcp-syn' & $C curl -s -m20 10.2.2.2:9998; wait   # again
$S iptables -F INPUT
```

The first capture shows retries **1 s apart**. Since kernel 6.5, the first
`tcp_syn_linear_timeouts` (4) SYN retransmits are linear, and only then
does backoff double. With it at 0 you get the textbook exponential gaps:
1, 1, 2, 4 s, i.e. retries at about 1, 3, 7, 15 s. A filtered port on an
older kernel (or a non-Linux client) takes noticeably longer to give up
than one on Ubuntu 24.04.

### 2.3 UDP

```bash
$S socat -u UDP-RECV:5000 STDOUT &
echo hello | $C socat -u - UDP:10.2.2.2:5000        # arrives; no handshake, no ack
echo hello | $C nc -u -w1 10.2.2.2 5001             # closed port: ICMP port unreachable (capture it)
kill %1
```

No connection, no ordering, no retransmission: the application does all of
it (DNS retries, QUIC rebuilds it all on top of UDP).

### 2.4 Inside the kernel's view

```bash
$C curl -s -o /dev/null 10.2.2.2:8080/big.bin &
$C ss -tni dst 10.2.2.2                             # cwnd, rtt, retrans, send/recv windows, while it runs
wait
```

## 3. Verification

| Check | Expected |
|---|---|
| §2.1 | SYN, SYN-ACK, ACK with ack = ISN+1; FIN exchange; a TIME_WAIT socket on the closer |
| §2.2 | exit 7 instantly for RST and REJECT, exit 28 for DROP; SYN retries 1 s apart with linear timeouts at 4, doubling with them at 0 |
| §2.3 | data arrives with no reply; closed port → ICMP port unreachable |

## 4. Break/fix

```bash
cd /workbook/phase1-ccna-drills/07-tcp-udp && bash break.sh
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

**Done when** `$C curl -s -m3 10.2.2.2:8080` returns `hello from server`.

Solution: [`solution.md`](solution.md).

## 5. Cleanup

```bash
bash /workbook/phase2-linux-networking/lib/topo-crs.sh down
```

## 6. What I should be able to explain after this

- The handshake (SYN / SYN-ACK / ACK with ISN+1), data with sequence/ack numbers, FIN close and TIME_WAIT on the side that closed first.
- Refused (RST or ICMP: something answered, fast) vs filtered (silence, SYN retransmits with exponential backoff, slow) — the first thing to read from any failed connection.
- UDP is datagrams with ports and nothing else; reliability is the application's job.
