# Lab 2.01 — solution

## What was injected

<!--FAULT-->
```bash
for n in red blue; do
    ip netns pids "$n" 2>/dev/null | xargs -r kill 2>/dev/null || true
    ip netns del "$n" 2>/dev/null || true
done
ip netns add red; ip netns add blue
ip link add veth-red netns red type veth peer name veth-blue netns blue
ip -n red  addr add 10.0.0.1/24 dev veth-red
ip -n blue addr add 10.0.0.2/24 dev veth-blue
for n in red blue; do ip -n "$n" link set lo up; done
ip -n red  link set veth-red up
ip -n blue link set veth-blue up
# --- the fault ---
ip -n blue link set veth-blue arp off
cat <<'T'

TICKET  From namespace red, `ping 10.0.0.2` fails:
        "From 10.0.0.1 icmp_seq=1 Destination Host Unreachable".
        Addresses are 10.0.0.1/24 (red) and 10.0.0.2/24 (blue), both links UP.
        The owner of blue says "I only ran a hardening script".
T
```
<!--/FAULT-->

`arp off` sets `NOARP` on blue's end. The kernel stops answering ARP
requests on that interface, and stops sending them too.

## Diagnosis path

| Beat | Answer |
|---|---|
| Hypothesis | L3 config is right (same /24 both sides); something below IP is failing. |
| Tool | `ip -n red neigh` |
| Expected if right | `10.0.0.2 … INCOMPLETE` or `FAILED` — red never got an ARP reply. |
| Tool 2 | `ip netns exec blue tcpdump -nnei veth-blue arp` while red pings |
| Expected if right | `Request who-has 10.0.0.2 tell 10.0.0.1` arriving, no `Reply`. So the wire works and blue is the one not answering. |
| Tool 3 | `ip -n blue -d link show veth-blue` |
| Expected if right | `<BROADCAST,MULTICAST,NOARP,UP,LOWER_UP>` |
| What would have told me sooner | `Destination Host Unreachable` from **your own** address (10.0.0.1), not from a router, means local ARP resolution failed. That message plus `ip neigh` showing `FAILED` is a two-second L2 diagnosis. |

## Fix

```bash
ip -n blue link set veth-blue arp on
ip -n red neigh flush dev veth-red
ip netns exec red ping -c3 10.0.0.2
```

## Why it matters later

Calico does the opposite on purpose: the host-side `cali*` veth answers
ARP for everything (`proxy_arp=1`) so the pod's gateway `169.254.1.1`
resolves to the host's MAC. Lab 3.01 shows it. A NOARP or proxy-ARP
surprise looks exactly like this ticket.
