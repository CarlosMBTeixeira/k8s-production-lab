# Lab 2.02 — solution

## What was injected

<!--FAULT-->
```bash
for i in 1 2 3; do ip netns del ns$i 2>/dev/null || true; done
ip link del br0 2>/dev/null || true
ip link add br0 type bridge
ip link set br0 up
for i in 1 2 3; do
  ip netns add ns$i
  ip link add v$i type veth peer name eth0 netns ns$i
  ip link set v$i master br0 up
  ip -n ns$i addr add 10.0.10.$i/24 dev eth0
  ip -n ns$i link set eth0 up
  ip -n ns$i link set lo up
done
# --- the fault ---
bridge link set dev v2 learning off flood off
cat <<'T'

TICKET  ns1 and ns3 talk fine. Nobody can reach ns2 (10.0.10.2).
        "It's not ARP — `ip neigh` on ns1 shows ns2's MAC as REACHABLE."
        ns2's interface is UP with the right address.
T
```
<!--/FAULT-->

Port `v2` has `learning off` and `flood off`. The bridge never learns ns2's
MAC, so frames **to** ns2 are unknown unicast, and unknown unicast is not
flooded to a port with `flood off`. Broadcasts still are (that's
`bcast_flood`, a separate flag), so ARP works in both directions.

## Diagnosis path

| Beat | Answer |
|---|---|
| Hypothesis | ns1 resolves ns2's MAC (`ip -n ns1 neigh` → REACHABLE), so ARP works; unicast toward ns2 is lost inside the bridge. |
| Tool | `tcpdump -nnei v2` while ns1 pings |
| Expected if right | ARP request and ARP reply present, **no ICMP echo request** on v2. Same capture on v1 shows the requests leaving ns1. |
| Tool 2 | `bridge fdb show br br0 \| grep -v permanent` |
| Expected if right | MACs learned for v1 and v3, **none for v2**. |
| Tool 3 | `bridge -d link show dev v2` |
| Expected if right | `learning off … flood off` |
| What would have told me sooner | A healthy neighbour entry plus a failed ping means the problem is below IP but above "the wire exists": the switch. `bridge fdb show` is the switch's MAC table — a port that never appears there is a port the bridge can't deliver unicast to. |

## Fix

```bash
bridge link set dev v2 learning on flood on
ip netns exec ns1 ping -c3 10.0.10.2
```

## Why it matters later

Calico's and Cilium's veths aren't bridged at all (routed instead), but
`cni0` (bridge plugin, Flannel, kindnet) is a bridge exactly like this one.
VXLAN devices with `nolearning` (lab 2.08) depend on static FDB entries —
the same table, filled by the CNI instead of by learning.
