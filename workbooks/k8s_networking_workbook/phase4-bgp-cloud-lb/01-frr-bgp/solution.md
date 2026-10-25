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
          docker exec clab-bgp-r2 vtysh -c 'show bgp summary'   → 10.0.23.3 in state Active
        r2 and r3 ping each other fine. r2's config wasn't touched.
T
```
<!--/FAULT-->

r3 now requires a TCP MD5 signature (RFC 2385) on its session with r2; r2
doesn't send one. The kernel drops r2's unsigned segments before BGP ever
sees them, so neither side gets past TCP: r2 sits in **Connect/Active**, r3
too. No NOTIFICATION, nothing in FRR's log on r2 except retries.

## Diagnosis path

| Beat | Answer |
|---|---|
| Hypothesis | Stuck in Active = no TCP session. Reachability is fine (ping 10.0.23.3 from r2 works), so something rejects the TCP itself. |
| Tool | `v r2 'show bgp neighbors 10.0.23.3' \| grep -E 'BGP state\|Last reset\|Connections'` |
| Expected if right | `BGP state = Active`, connection attempts rising, no "established" count increase. |
| Tool 2 | `docker exec clab-bgp-r3 tcpdump -nni eth1 -c6 tcp port 179` |
| Expected if right | SYNs from 10.0.23.2 and **no SYN-ACK** (r3's kernel ignores them); r3's own SYNs carry `md5` in the options. |
| Tool 3 | `dmesg \| grep -i md5 \| tail -3` on netlab-c (the containers share its kernel) |
| Expected if right | `MD5 Hash NOT expected …` / `MD5 Hash mismatch …` naming 10.0.23.2 ↔ 10.0.23.3. |
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
