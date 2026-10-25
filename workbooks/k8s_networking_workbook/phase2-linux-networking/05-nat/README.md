# Lab 2.05 — NAT: what Docker does

| | |
|---|---|
| **Objective** | Give namespaces internet access with masquerade, publish a port with DNAT, and fix the three DNAT cases that always bite: local clients, localhost and hairpin. |
| **Time** | 5 h (week 3) |
| **Where** | netlab-a, root namespace |
| **Risk** | Changes netlab-a's root namespace: `ip_forward`, `route_localnet`, NAT rules (all tagged `lab205`). Blast radius: this VM. Rollback: §5. |

## 1. Prerequisites

- Labs 2.01–2.04. Phase 1 drill 08 (DNS) helps for §2.2.

```bash
UP=$(ip -o route show default | awk '{print $5}')            # uplink, usually ens3
A_IP=$(ip -4 -o addr show dev $UP | awk '{print $4}' | cut -d/ -f1)
echo $UP $A_IP
```

## 2. Hands-on

### 2.1 A docker0 of your own

```bash
ip link add lab0 type bridge
ip addr add 172.30.0.1/24 dev lab0
ip link set lab0 up
for i in 2 3; do
  ip netns add c$i
  ip link add vc$i type veth peer name eth0 netns c$i
  ip link set vc$i master lab0 up
  ip -n c$i addr add 172.30.0.$i/24 dev eth0
  ip -n c$i link set eth0 up; ip -n c$i link set lo up
  ip -n c$i route add default via 172.30.0.1
done
ip netns exec c2 ping -c1 172.30.0.1      # the "host" — works
ip netns exec c2 ping -c1 -W2 1.1.1.1     # predict
```

Two things are missing. Find them with captures before reading on:
`tcpdump -nni lab0 icmp` (arrives?) and `tcpdump -nni $UP icmp` (leaves? with
which source?).

```bash
sysctl net.ipv4.ip_forward                     # 0 on a fresh Ubuntu
sysctl -w net.ipv4.ip_forward=1
ip netns exec c2 ping -c1 -W2 1.1.1.1          # leaves $UP with source 172.30.0.2 — nobody routes that back
iptables -t nat -A POSTROUTING -s 172.30.0.0/24 ! -o lab0 -j MASQUERADE -m comment --comment lab205
ip netns exec c2 ping -c2 1.1.1.1              # works
conntrack -L -s 172.30.0.2 2>/dev/null | head  # orig: src=172.30.0.2 … reply: dst=$A_IP — that is the NAT
```

### 2.2 DNS inside the namespace

```bash
ip netns exec c2 curl -sI -m5 http://example.com | head -1     # fails — why?
ip netns exec c2 cat /etc/resolv.conf                           # nameserver 127.0.0.53: c2's own loopback, nothing there
mkdir -p /etc/netns/c2 /etc/netns/c3
DNS=$(resolvectl dns $UP | awk '{print $NF}')
for i in 2 3; do echo "nameserver $DNS" > /etc/netns/c$i/resolv.conf; done
ip netns exec c2 curl -sI -m5 http://example.com | head -1     # HTTP/1.1 200 (or a redirect)
```

`ip netns exec` bind-mounts `/etc/netns/<name>/resolv.conf` over
`/etc/resolv.conf`. Docker solves the same problem by rewriting the file
when the host's points at a loopback resolver. Kubelet has the same issue
with systemd-resolved: it reads `/run/systemd/resolve/resolv.conf`, not
`/etc/resolv.conf`, for `dnsPolicy: Default` pods.

### 2.3 Publish a port (DNAT)

```bash
ip netns exec c2 bash -c 'echo "c2 says hi" > /tmp/index.html; cd /tmp && exec python3 -m http.server 80' >/dev/null 2>&1 &
iptables -t nat -A PREROUTING -i $UP -p tcp --dport 8080 -j DNAT --to-destination 172.30.0.2:80 -m comment --comment lab205
```

From the **WSL host** (a different machine): `curl http://<A_IP>:8080` → `c2 says hi`.

### 2.4 The three DNAT gotchas

Predict each one, then make it work.

**(a) From netlab-a itself.** `curl -m3 $A_IP:8080` → refused. Locally
generated packets never cross PREROUTING; they cross OUTPUT.

```bash
iptables -t nat -A OUTPUT -d $A_IP -p tcp --dport 8080 -j DNAT --to-destination 172.30.0.2:80 -m comment --comment lab205
curl -s $A_IP:8080
```

**(b) Via localhost.** `curl -m3 127.0.0.1:8080` → still refused. The kernel
won't route a 127/8 source off the box.

```bash
iptables -t nat -A OUTPUT -d 127.0.0.1 -p tcp --dport 8080 -j DNAT --to-destination 172.30.0.2:80 -m comment --comment lab205
sysctl -w net.ipv4.conf.all.route_localnet=1
iptables -t nat -A POSTROUTING -s 127.0.0.0/8 -o lab0 -j MASQUERADE -m comment --comment lab205
curl -s 127.0.0.1:8080
```

kube-proxy did exactly this for NodePorts on localhost, and
`route_localnet=1` was CVE-2020-8558 (other hosts on the L2 could reach
the node's 127.0.0.1 services). Know it when you see it.

**(c) Hairpin: c3 → A_IP:8080 → c2.**

```bash
ip netns exec c3 curl -m3 $A_IP:8080        # refused: the PREROUTING rule is pinned to -i $UP
iptables -t nat -A PREROUTING -i lab0 -d $A_IP -p tcp --dport 8080 -j DNAT --to-destination 172.30.0.2:80 -m comment --comment lab205
ip netns exec c3 curl -m3 $A_IP:8080        # now it hangs — capture on vc2 and vc3 and explain
```

c2 sees the source 172.30.0.3, which is on its own subnet, so it replies
**directly** over the bridge. c3 gets a SYN-ACK from 172.30.0.2, not from
A_IP, and resets it. The fix is to SNAT hairpinned traffic so the reply comes
back through the host:

```bash
iptables -t nat -A POSTROUTING -s 172.30.0.0/24 -d 172.30.0.2 -p tcp --dport 80 -j MASQUERADE -m comment --comment lab205
ip netns exec c3 curl -s $A_IP:8080
```

This is the same problem kube-proxy has when a pod hits its own Service and
lands on a pod behind the same bridge (lab 2.10, lab 3.02).

## 3. Verification

| Check | Expected |
|---|---|
| `conntrack -L -s 172.30.0.2` during a ping | `src=172.30.0.2 dst=1.1.1.1 … src=1.1.1.1 dst=<A_IP>` |
| `tcpdump -nni $UP icmp` | source is `A_IP`, never 172.30.0.x |
| §2.3 from the WSL host | `c2 says hi` |
| §2.4 a, b, c | all three curls succeed only after their fix |
| `iptables -t nat -S \| grep lab205 \| wc -l` | 7 |

## 4. Break/fix

```bash
bash break.sh      # rebuilds lab0, c2, c3 and masquerade, injects a fault
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

**Done when** both namespaces reach `1.1.1.1` and you changed one rule.

<details><summary>Hint (only after 20 minutes)</summary>

Compare the source address of the two namespaces' packets on the uplink.
</details>

Solution: [`solution.md`](solution.md).

## 5. Cleanup

```bash
pkill -f 'http.server 80' || true
for i in 2 3; do ip netns del c$i 2>/dev/null; rm -rf /etc/netns/c$i; done
ip link del lab0
iptables-save -t nat | grep -v lab205 | iptables-restore -T nat
sysctl -w net.ipv4.conf.all.route_localnet=0
sysctl -w net.ipv4.ip_forward=0          # labs 2.06+ set it again when they need it
```

## 6. What I should be able to explain after this

- MASQUERADE is SNAT to the outgoing interface's address, applied in POSTROUTING; conntrack remembers the translation so replies get un-NATed automatically.
- DNAT happens in PREROUTING for traffic arriving from outside and in OUTPUT for local traffic; localhost needs `route_localnet` plus SNAT, which is why kube-proxy stopped doing it by default.
- Hairpin NAT: when client and backend share an L2 segment, the backend replies directly unless you SNAT, and the client resets an answer from an address it never called.
