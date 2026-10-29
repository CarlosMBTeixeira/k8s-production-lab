# Lab 4.01 — solution

## What was injected

<!--FAULT-->
```bash
cd "$LAB_DIR"
containerlab destroy -t topo.clab.yml --cleanup >/dev/null 2>&1 || true
containerlab deploy -t topo.clab.yml >/dev/null
for i in $(seq 30); do
  docker exec clab-bgp-r2 vtysh -c 'show bgp summary' 2>/dev/null | grep -q '10.0.23.3.*[0-9]\+ *[0-9]\+ *N/A' && break
  docker exec clab-bgp-r2 vtysh -c 'show bgp neighbors 10.0.23.3' 2>/dev/null | grep -q 'BGP state = Established' && break
  sleep 2
done
# --- the fault ---
docker exec clab-bgp-r3 vtysh -c 'conf t' -c 'router bgp 65003' -c 'neighbor 10.0.23.2 password lab-secret' >/dev/null
docker exec clab-bgp-r3 vtysh -c 'clear bgp 10.0.23.2' >/dev/null
cat <<'T'

TICKET  h1 (172.16.1.10) lost h2 (172.16.3.10) right after "the security
        hardening of r3". On r2:
          docker exec clab-bgp-r2 vtysh -c 'show bgp summary'   → r3(10.0.23.3) stuck in state Connect
        r2 and r3 ping each other fine. r2's config wasn't touched.
T
```
<!--/FAULT-->

r3 now requires a TCP MD5 signature (RFC 2385) on its session with r2; r2
doesn't send one. The kernel drops r2's unsigned segments before BGP ever
sees them, and nobody sends a RST, so neither side gets past TCP: r2 and r3 both sit in
**Connect**. They never reach Active, because nothing refuses the connection.
The only NOTIFICATION is r3's `Cease/Other Configuration Change` from the
config change. After that, FRR on r2 only logs retries.

## Diagnosis path

| Beat | Answer |
|---|---|
| Hypothesis | Stuck in Connect = SYNs that get no answer at all. Reachability is fine (ping 10.0.23.3 from r2 works), so something drops the TCP itself. |
| Tool | `v r2 'show bgp neighbors 10.0.23.3' \| grep -E 'BGP state\|Last reset\|Connections'` |
| Expected if right | `BGP state = Connect`, `Connections established 1; dropped 1` not increasing, `Last reset … Notification received (Cease/Other Configuration Change)` — r3 changed something. |
| Tool 2 | `timeout 15 ip netns exec clab-bgp-r3 tcpdump -nni eth1 -c6 tcp port 179` |
| Expected if right | SYNs both ways, **no SYN-ACK** either way. r3's SYNs carry `md5 shared secret not supplied with -M` in their options, r2's don't. |
| Tool 3 | `dmesg \| grep -i md5 \| tail -3` on netlab-c (the containers share its kernel) |
| Expected if right | `TCP: MD5 Hash not found for 10.0.23.2.x->10.0.23.3.179 [S]` (r3 expects a signature, r2 sent none) and `TCP: Unexpected MD5 Hash found for 10.0.23.3.x->10.0.23.2.179 [S]` (r2 got a signature it doesn't expect). |
| What would have told me sooner | Session-state monitoring that alerts on "not Established for > N minutes" per neighbor (FRR exports this; so do MetalLB/Calico/Cilium BGP metrics). For the cause: MD5 problems only ever show in the **kernel** log, never in the BGP daemon on the side without the password. |

## Fix

Agree on the password on both ends (or remove it on r3):

```bash
docker exec clab-bgp-r2 vtysh -c 'conf t' -c 'router bgp 65002' -c 'neighbor 10.0.23.3 password lab-secret'
sleep 5; docker exec clab-bgp-r2 vtysh -c 'show bgp summary'
docker exec clab-bgp-h1 ping -c2 172.16.3.10
```

## Why it matters later

Calico `BGPPeer.password`, MetalLB `BGPPeer.password`/`passwordSecret` and
Cilium `CiliumBGPPeerConfig.authSecretRef` all map to this same kernel
option. Rotating the secret on one side only is how this incident happens
in production.
