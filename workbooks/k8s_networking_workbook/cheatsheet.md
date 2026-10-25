# Cheatsheet

Commands and debugging flows, added lab by lab. Each block names the lab it
came from. Add what *you* reached for during a break/fix, not only what the
lab listed. A command you had to look up twice belongs here.

Format: one line per command, a comment saying what question it answers.

---

## Capture and inspect
<!-- Phase 1 drills, 2.01, 2.07 -->
```bash
tcpdump -nni <if> -w f.pcap <filter>              # always -nn; -w keeps evidence; -s 128 for headers only
tcpdump -nnei any arp or icmp                     # L2 + reachability, interface name per packet
tcpdump -nni any 'tcp[tcpflags] & (tcp-syn|tcp-rst) != 0'   # handshakes and resets only
tcpdump -nni any 'icmp[icmptype] == icmp-unreach'           # every unreachable, incl. frag-needed
tcpdump -nni any 'ip[6:2] & 0x4000 != 0 and greater 1400'   # DF + big: MTU suspects
tcpdump -nni <if> -Q in|out                       # one direction
mergecap -w all.pcap a.pcap b.pcap                # merge per-hop captures, then read in time order
tshark -r f.pcap -q -z conv,tcp                   # per-conversation bytes/duration
tshark -r f.pcap -Y tcp.analysis.flags            # retransmits, dup ACKs, zero windows [2.07]
ethtool -k <if> | grep segmentation               # GSO/TSO on? captures show >MTU "packets" [2.07]
```
Dropped where tcpdump can't see: XDP, tc egress, qdisc, netfilter on egress [2.11].


## Namespaces, links, addresses, neighbours
<!-- 2.01, 2.02 -->
```bash
ip netns add X; ip -n X link set lo up            # new stack; lo starts DOWN
ip link add a type veth peer name b netns X       # wire straight into a namespace
ip -d link show <veth>                            # "@ifN" = peer ifindex, "link-netns"
nsenter -t <pid> -n ip -o link show eth0          # pod's eth0@ifN by PID (not /sys!) [2.01]
ip -o link | grep '^N:'                           # → the host-side veth
lsns -t net                                       # every netns, named or not
ip neigh show dev <if>                            # INCOMPLETE/FAILED = ARP failed
bridge link; bridge fdb show br <br>              # ports + learned MACs [2.02]
bridge -d link show dev <port>                    # learning / flood / hairpin flags
bridge vlan show                                  # PVID, tagged/untagged per port
sysctl net.bridge.bridge-nf-call-iptables         # 1 = bridged frames hit iptables [2.02, 2.10]
```


## Routing
<!-- 2.03 -->
```bash
ip route get <dst> from <src> iif <in-if>         # the kernel's forwarding decision, exactly
ip rule                                           # policy routing: which table, by source/mark/iif
ip route show table all | grep -v '^local'        # every table
sysctl net.ipv4.ip_forward                        # per netns
sysctl net.ipv4.conf.{all,<if>}.rp_filter         # effective = max(all, if); 1 strict, 2 loose
nstat -az TcpExtIPReversePathFilter               # rp_filter drops
sysctl -w net.ipv4.conf.all.log_martians=1        # dmesg: "martian source …"
```


## netfilter: iptables, nftables, tracing
<!-- 2.04, 2.05 -->
```bash
nft list ruleset                                  # ground truth; iptables -L hides other tables [2.04]
iptables -V                                       # "(nf_tables)" = iptables-nft
iptables -t nat -L <chain> -v -n --line-numbers   # counters per rule
nft -a list chain <family> <table> <chain>        # -a: handles, for "delete rule … handle N"
nft add chain inet t tr '{ type filter hook prerouting priority -350; }'
nft add rule inet t tr ip saddr X meta nftrace set 1; nft monitor trace   # every rule a packet hits
sysctl -w net.netfilter.nf_log_all_netns=1        # LOG/log from non-root netns
iptables -t nat -A POSTROUTING -s <cidr> ! -o <br> -j MASQUERADE   # docker0-style egress [2.05]
iptables -t nat -A PREROUTING -i <up> -p tcp --dport P -j DNAT --to-destination IP:port
# local clients need OUTPUT DNAT; localhost needs route_localnet + SNAT; hairpin needs SNAT
```


## conntrack
<!-- 2.06 -->
```bash
conntrack -L [-p udp] [--orig-dst X]              # orig + reply tuples; NAT lives in the reply tuple
conntrack -E                                      # live events: NEW / UPDATE / DESTROY
conntrack -S                                      # insert_failed, drop, early_drop per CPU
conntrack -C; cat /proc/sys/net/netfilter/nf_conntrack_max
conntrack -D -p udp --orig-dst <vip>              # kill stale UDP entries after an endpoint change
dmesg | grep 'table full'                         # exhaustion
sysctl net.netfilter.nf_conntrack_tcp_loose       # 1: mid-stream pickup (no NAT!); 0: INVALID
```


## Tunnels and MTU
<!-- 2.08, 2.09 -->
```bash
ip link add vx type vxlan id N dstport 4789 local <me> dev <up> nolearning   # no dstport → 8472!
bridge fdb append 00:00:00:00:00:00 dev vx dst <peer>     # BUM head-end replication
bridge fdb add <mac> dev vx dst <peer> self permanent    # MAC → VTEP, no learning
ip neigh replace <ip> lladdr <mac> dev vx nud permanent  # skip ARP across the tunnel
tcpdump -nni <up> udp port 4789 or udp port 8472 or udp port 6081 or ip proto 4   # any overlay
ping -M do -s <mtu-28> <dst>                      # largest unfragmented packet
tracepath -n <dst>                                # PMTU per hop
ip route get <dst>                                # "cache … mtu N" = learned PMTU
ip route flush cache
iptables -t mangle -A FORWARD -o <small-if> -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
sysctl -w net.ipv4.tcp_mtu_probing=1              # PLPMTUD: survives ICMP blackholes
```
Overhead: IPIP 20 · VXLAN 50 · Geneve 50+ · WireGuard 60 (v4) / 80 (v6).


## Load balancing: DNAT, IPVS
<!-- 2.10 -->
```bash
iptables-save -t nat | grep -E 'KUBE-(SVC|SEP)'   # ClusterIP chains: random-probability cascade → DNAT
iptables -t nat -L <SVC chain> -v -n              # which endpoint got how many
ipvsadm -Ln [--stats]                             # IPVS virtual + real servers
ipvsadm -Lnc                                      # IPVS connection table
ip addr show kube-ipvs0                           # IPVS needs VIPs on a local dummy
bridge link set dev <port> hairpin on             # pod → own Service on a bridge CNI
```


## eBPF
<!-- 2.11 -->
```bash
bpftool net show                                  # XDP/tc programs per interface (Cilium: cil_*)
bpftool prog show; bpftool map show
sysctl -w kernel.bpf_stats_enabled=1; bpftool prog show id N   # run_cnt / run_time_ns
pwru --output-tuple '<pcap filter>'               # every kernel function + drop reason for matching skbs
bpftrace -e 'tracepoint:skb:kfree_skb { @[args->reason] = count(); }'          # why the kernel drops
bpftrace -e 'tracepoint:tcp:tcp_retransmit_skb { @[ntop(args->daddr)] = count(); }'
bpftrace -e 'tracepoint:sock:inet_sock_set_state { … }'                         # every TCP state change
tc -s qdisc show dev <if>; tc filter show dev <if> ingress|egress            # tc drops [2.07, 2.11]
ip link set dev <if> xdpgeneric obj f.o sec xdp   # attach; "xdpgeneric off" to detach
```


## Kubernetes: pods, Services, kube-proxy
<!-- 3.01–3.03 -->

## DNS
<!-- 1-08, 3.04 -->

## Policy
<!-- 3.05, 3.08 -->

## Cilium and Hubble
<!-- 3.07, 3.08, 3.13 -->

## Gateway API
<!-- 3.09 -->

## OVN-Kubernetes and OpenShift
<!-- 3.10, 3.11 -->

## Mesh datapath
<!-- 3.12 -->

## BGP: FRR, MetalLB, Calico, Cilium
<!-- 4.01–4.04, 4.08 -->

## TLS, HTTP/2, QUIC
<!-- 4.06 -->

## Metrics and alerts
<!-- 4.07 -->

---

## Flows

Short decision paths. The full checklist is
[`troubleshooting-playbook.md`](troubleshooting-playbook.md).

**"It enters and never leaves" (one box)** [2.04, 2.07, 2.11]
captures both sides → `nft list ruleset` → `tc -s qdisc`/`tc filter show` both directions →
`pwru` → `ip route get … from … iif …` → `ip rule`.

**"Works from here, not from there"** [2.03, 2.05]
source-dependent → `ip rule`, NAT rules matching `-s`, rp_filter, allowlists. Check the source on the wire.

**"Connects, then hangs on big responses"** [2.09]
`ping -M do -s` sweep → MTU on both ends of every link → ICMP frag-needed filtered? → MSS on the SYN.

**"1 in N requests fail"** [2.10]
N backends → list endpoints in the datapath vs source of truth → `conntrack -L -d <vip>` UNREPLIED.
