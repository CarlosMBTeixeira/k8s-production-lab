# Lab 2.05 — solution

## What was injected

<!--FAULT-->
```bash
UP=$(ip -o route show default | awk '{print $5}')
pkill -f 'http.server 80' 2>/dev/null || true
for i in 2 3; do ip netns del c$i 2>/dev/null || true; done
ip link del lab0 2>/dev/null || true
iptables-save -t nat | grep -v -e lab205 -e 'no NAT to VPN' | iptables-restore -T nat
ip link add lab0 type bridge
ip addr add 172.30.0.1/24 dev lab0
ip link set lab0 up
DNS=$(resolvectl dns "$UP" | awk '{print $NF}')
for i in 2 3; do
  ip netns add c$i
  ip link add vc$i type veth peer name eth0 netns c$i
  ip link set vc$i master lab0 up
  ip -n c$i addr add 172.30.0.$i/24 dev eth0
  ip -n c$i link set eth0 up; ip -n c$i link set lo up
  ip -n c$i route add default via 172.30.0.1
  mkdir -p /etc/netns/c$i; echo "nameserver $DNS" > /etc/netns/c$i/resolv.conf
done
sysctl -qw net.ipv4.ip_forward=1
iptables -t nat -A POSTROUTING -s 172.30.0.0/24 ! -o lab0 -j MASQUERADE -m comment --comment lab205
# --- the fault ---
iptables -t nat -I POSTROUTING 1 -s 172.30.0.2/32 -m comment --comment "no NAT to VPN 10.8.0.0/16" -j RETURN
cat <<'T'

TICKET  Container c2 (172.30.0.2) lost internet access this morning:
        `ip netns exec c2 ping 1.1.1.1` → 100% loss. c3 (172.30.0.3) is fine.
        Same bridge, same gateway, same resolv.conf. The VPN team says they
        "only added an exclusion for their range".
T
```
<!--/FAULT-->

An "exclusion" rule meant to stop NAT toward a VPN range, written without
`-d`, so it exempts **all** of c2's traffic from masquerade. Packets leave
the VM with source 172.30.0.2, and no router upstream knows where that lives.

## Diagnosis path

| Beat | Answer |
|---|---|
| Hypothesis | c2's packets leave without SNAT (c3's are fine, so forwarding and routing work). |
| Tool | `tcpdump -nni $UP icmp` while both ping 1.1.1.1 |
| Expected if right | c3's requests with `src $A_IP`; c2's with `src 172.30.0.2`; replies only for c3. |
| Tool 2 | `iptables -t nat -L POSTROUTING -v -n --line-numbers` |
| Expected if right | rule 1: `RETURN … 172.30.0.2 … /* no NAT to VPN 10.8.0.0/16 */` with a counter that rises; MASQUERADE below it. |
| Tool 3 | `conntrack -L -s 172.30.0.2` |
| Expected if right | reply tuple `dst=172.30.0.2` — no translation recorded. |
| What would have told me sooner | The uplink capture's **source address**. "One host works, its twin doesn't" through NAT is almost always a per-source rule, and the source on the wire says so instantly. The comment promised a `-d` that the rule doesn't have — read rules, not comments. |

## Fix

```bash
iptables -t nat -D POSTROUTING -s 172.30.0.2/32 -m comment --comment "no NAT to VPN 10.8.0.0/16" -j RETURN
# or, if the exclusion was really wanted:
iptables -t nat -I POSTROUTING 1 -s 172.30.0.2/32 -d 10.8.0.0/16 -j RETURN -m comment --comment lab205
ip netns exec c2 ping -c2 1.1.1.1
```

## Why it matters later

Calico's `natOutgoing`, Cilium's `ipMasqAgent`/`nonMasqueradeCIDRs` and the
`ip-masq-agent` add exactly these exclusions. A wrong non-masquerade CIDR
gives "pods on this node can't reach the internet" or "can't reach the
on-prem range" depending on which way it's wrong. Same capture, same answer.
