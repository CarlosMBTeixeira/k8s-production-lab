# Lab 2.12 — solution

The reference plugin, `hostgw.sh` and `vxlan.sh` are in [`reference/`](reference/).
This file covers the break/fix.

## What was injected

<!--FAULT-->
```bash
SIDE="${1:?usage: break.sh a|b}"
case "$SIDE" in
b)
  ip netns list | grep -qw pod2 || { echo "pod2 missing: run 'bash verify.sh b' first"; exit 1; }
  ip netns pids pod2 | xargs -r kill 2>/dev/null || true
  setsid ip netns exec pod2 python3 "$LAB_DIR/echo-server.py" >/dev/null 2>&1 < /dev/null &
  iptables -D FORWARD -d 10.244.2.0/24 -p tcp --dport 8080 ! -s 10.244.0.0/16 -j REJECT -m comment --comment lab-cni-allowlist 2>/dev/null || true
  iptables -I FORWARD 1 -d 10.244.2.0/24 -p tcp --dport 8080 ! -s 10.244.0.0/16 -j REJECT -m comment --comment lab-cni-allowlist
  echo "side B ready. Now run 'bash break.sh a' on netlab-a."
  ;;
a)
  ip netns list | grep -qw pod1 || { echo "pod1 missing: finish the capstone first"; exit 1; }
  # --- the fault ---
  iptables -t nat -I POSTROUTING 1 -s 10.244.1.0/24 -j MASQUERADE -m comment --comment "egress-nat"
cat <<'T'

TICKET  pod1 (netlab-a) can't use the service in pod2 (10.244.2.2:8080) any
        more: "curl: (7) Failed to connect … Connection refused". Ping
        pod1 → pod2 works. pod2's node has had an allowlist for years
        ("only the pod network may reach :8080"). Someone on netlab-a
        "fixed egress for a new subnet" this morning.
T
  ;;
*) echo "usage: break.sh a|b"; exit 1 ;;
esac
```
<!--/FAULT-->

On B: an allowlist that only lets the pod network reach pod2's port 8080 —
reasonable, and it was "always there". On A: a new top-of-chain MASQUERADE
for the whole pod subnet with **no cluster-CIDR exclusion**, which wins over
your correct rule further down. Pod1's traffic to pod2 now arrives from
A_IP, so the allowlist rejects it.

## Diagnosis path

| Beat | Answer |
|---|---|
| Hypothesis | Connection refused (fast) = something answered with a reject; ping still works, so routing is fine. Something filters on source, and the source changed. |
| Tool | on B: `tcpdump -nni $UP 'port 8080 or udp port 8472'` (or on cni0) during the curl |
| Expected if right | the request arrives with a node address as source, not 10.244.1.2, and an ICMP port-unreachable goes back. In this lab it shows as **10.215.138.1**, not A_IP: the WSL host has br_netfilter on, and Multipass's own `-s <bridge subnet> ! -d <bridge subnet> -j MASQUERADE` NATs A_IP → 10.244.2.2 a second time. Two layers of SNAT, same lesson. |
| Tool 2 | on B: `iptables -L FORWARD -v -n --line-numbers` |
| Expected if right | a REJECT for `! 10.244.0.0/16 → 10.244.2.0/24:8080` with a rising counter. |
| Tool 3 | on A: `iptables -t nat -L POSTROUTING -v -n --line-numbers` |
| Expected if right | rule 1 `MASQUERADE … 10.244.1.0/24 → 0.0.0.0/0` counting the pod-to-pod packets; your `! -d 10.244.0.0/16` rule below it never matches. |
| What would have told me sooner | `verify.sh`'s "pod2 sees pod1's own IP" check — a source-IP assertion is the test that catches SNAT mistakes before a policy does. In a cluster: `kubectl logs` on the server showing node IPs instead of pod IPs. |

## Fix (on netlab-a)

```bash
iptables -t nat -D POSTROUTING -s 10.244.1.0/24 -j MASQUERADE -m comment --comment "egress-nat"
bash verify.sh a
```

The allowlist on B is legitimate; leave it, or remove it in cleanup.

## Why it matters later

Calico's `natOutgoing`, Cilium's `nonMasqueradeCIDRs` and `ip-masq-agent`
are this rule with a config file. A non-masquerade list that misses a range
(another cluster, an on-prem network reached over a VPN) gives this exact
ticket from the other side's firewall.
