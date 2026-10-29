# Lab 2.09 — solution

## What was injected

<!--FAULT-->
```bash
bash "$LAB_DIR/topo.sh" up
bash "$LAB_DIR/topo.sh" serve
# --- the fault ---
ip -n mr2 link set r2-w mtu 1500
ip netns exec ms ethtool -K eth0 tso off gso off >/dev/null 2>&1 || true
cat <<'T'

TICKET  Since the WAN maintenance last night, downloads of
        http://10.2.2.2:8080/big.bin from the client (10.1.1.2) hang after
        the response starts. Small pages work. There are no firewall rules
        on either router (check: nft list ruleset is empty). No ICMP errors
        anywhere.
T
```
<!--/FAULT-->

The WAN link's two ends disagree: r1-w says 1400, r2-w says 1500. r2
believes 1500-byte packets fit, so it never sends "frag needed"; r1's side
of the veth refuses frames larger than its MTU and drops them silently. The
offload change on the server makes it send real 1500-byte packets instead of
GSO super-segments (which a veth would wave through), so the lab behaves
like real NICs do.

## Diagnosis path

| Beat | Answer |
|---|---|
| Hypothesis | Connects-then-hangs on big responses = MTU. No ICMP and no filter rules = a router that doesn't know it should send one. |
| Tool | `ip netns exec ms ping -c2 -M do -s 1472 10.1.1.2` then `-s 1372` |
| Expected if right | 1472: silence (not "Frag needed"); 1372: works. Something between 1400 and 1500 dies without a word. |
| Tool 2 | captures on `r2-w` and `r1-w` during the 1472 ping |
| Expected if right | leaves r2-w (tcpdump prints `length 1480`, the ICMP payload of a 1500-byte packet), never appears on r1-w. |
| Tool 3 | `ip -n mr1 link show r1-w; ip -n mr2 link show r2-w` |
| Expected if right | `mtu 1400` vs `mtu 1500` on the two ends of one link. |
| What would have told me sooner | Compare MTU on **both ends** of every link in the path; any mismatch is a silent drop. In Kubernetes this is the pod MTU vs the tunnel MTU (lab 3.06), or a cloud VPC with jumbo frames peered to one without. |

## Fix

```bash
ip -n mr2 link set r2-w mtu 1400
ip -n ms route flush cache
ip netns exec mc curl -s -o /dev/null -w '%{http_code}\n' 10.2.2.2:8080/big.bin
```

Optional: put the server's offloads back (`ethtool -K eth0 tso on gso on` in ms).

## Why it matters later

Calico, Cilium and Flannel auto-detect MTU from the node's uplink. A node
pool with a different NIC MTU, or a manual override on one node, gives
exactly this: pods on some nodes talk fine, large responses across certain
node pairs hang.
