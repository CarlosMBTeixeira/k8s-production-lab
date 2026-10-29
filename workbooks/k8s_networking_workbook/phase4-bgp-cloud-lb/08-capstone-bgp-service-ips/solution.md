# Lab 4.08 — solution

## Reference build

```bash
bash ../03-calico-bgp/install-calico.sh
bash ../lib/frr-kind.sh up lab-calico reference/frr.conf.tpl
export FRR_IP=$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' lab-frr)
# route reflector FIRST, mesh off LAST (bgp.yaml.tpl turns it off, so apply the RR pieces before it)
calicoctl patch node lab-calico-worker -p '{"spec":{"bgp":{"routeReflectorClusterID":"244.0.0.1"}}}'
kubectl label node lab-calico-worker route-reflector=true
envsubst < reference/bgp.yaml.tpl | calicoctl apply -f -
kubectl apply -f reference/app.yaml && kubectl -n lab-cap4 rollout status deploy/web
bash verify.sh
```

### Why the BGPFilter (row 8)

Measured on kind v0.33 / Calico 3.33.0, 2 workers with endpoints:

| `lab-frr` peer | FRR next hops for the VIP | `docker pause` a worker |
|---|---|---|
| default (next hop self) | both workers **and the control plane** — every node re-exports what the RR reflected to it | CP's share times out (Local, no endpoint): 4/30 failed |
| `keepOriginalNextHop: true` | the two workers, but each learned 3× (direct + via the other two nodes) | FRR drops its own session at ~9 s, but the reflected copies stay until the RR's iBGP hold timer expires: **~217 s** of ~half the flows blackholed |
| `filters: [own-routes-only]` | the two workers, one path each | next hop gone at **~7 s**; 7/211 requests failed, all inside that window |

BIRD's hold time is 240 s and Calico OSS can't change it (`keepaliveTime`
only sets the keepalive; no BFD). The fix is not faster iBGP timers but
not exporting what you didn't originate. Withdrawal (all replicas moved to
one node) took ~3 s including the rollout.

## What was injected

<!--FAULT-->
```bash
export KUBECONFIG="$HOME/.kube/config" DATASTORE_TYPE=kubernetes
[ "$(kubectl config current-context)" = kind-lab-calico ] || { echo "run: kubectl config use-context kind-lab-calico"; exit 1; }
calicoctl get bgppeer lab-frr >/dev/null 2>&1 || { echo "Calico BGPPeer 'lab-frr' not found — build the capstone first"; exit 1; }
# grep without -q: under pipefail, -q exits on the first match and the SIGPIPE'd docker exec fails the test
docker exec lab-frr vtysh -c 'show ip prefix-list CLUSTER-IN' 2>/dev/null | grep CLUSTER-IN >/dev/null || { echo "FRR prefix-list CLUSTER-IN not found — build the capstone first"; exit 1; }
# --- fault 1: cluster side renumbers the fabric's AS early ---
calicoctl patch bgppeer lab-frr -p '{"spec":{"asNumber":65001}}' >/dev/null
# --- fault 2: fabric filter "simplified" ---
docker exec lab-frr vtysh -c 'conf t' -c 'no ip prefix-list CLUSTER-IN' -c 'ip prefix-list CLUSTER-IN seq 10 permit 10.202.0.0/24' >/dev/null
docker exec lab-frr vtysh -c 'clear bgp * soft in' >/dev/null 2>&1 || true
sleep 10
cat <<'T'

TICKET  CHG-4.08 "Fabric AS renumbering 65000 → 65001 (phase 1: prepare) and
        prefix-list clean-up" ran tonight. Phase 2 (actually renumbering the
        fabric) is NEXT week. Since the window:
          docker exec lab-client curl -sS -m3 http://10.202.0.20/
          curl: (28) Connection timed out after 3002 milliseconds
        Roll forward or back — but end with verify.sh passing and the fabric
        still on AS 65000.
T
```
<!--/FAULT-->

Two changes from one "change window":

1. **Sessions.** The cluster's `lab-frr` peer now expects the fabric to be
   AS **65001** (the planned renumbering), but the fabric is still 65000.
   BIRD receives an OPEN from AS 65000, sends NOTIFICATION *Bad Peer AS*,
   and the session never establishes.
2. **Routes.** FRR's `CLUSTER-IN` was "simplified" to `permit 10.202.0.0/24`
   — without `le 32`. It now matches only the /24 itself; every /32 the
   cluster advertises is denied. Once sessions come back, FRR receives the
   routes and drops them all.

## Diagnosis path

| Beat | Answer (cause 1) |
|---|---|
| Hypothesis | No route on FRR and sessions not Established → session layer first. |
| Tool | `docker exec lab-frr vtysh -c 'show bgp summary'`; `docker logs lab-frr 2>&1 \| grep -i notification \| tail -3` |
| Expected if right | `% No BGP neighbors found in VRF default` — dynamic neighbors exist only while a session is up, so there is nothing to see cycling. The log has it: `%NOTIFICATION: received from neighbor 172.18.0.x 2/2 (OPEN Message Error/Bad Peer AS) 4 bytes 00 00 fd e8` — the *nodes* reject FRR, and the data is the AS FRR sent (0xfde8 = 65000). |
| Tool 2 | `calicoctl get bgppeer lab-frr -o yaml`; on a node: `kubectl -n kube-system exec <calico-node> -c calico-node -- birdcl show protocols` |
| Expected if right | `asNumber: 65001`; `Global_<frr ip> … Idle  BGP Error: Bad peer AS`. |
| What would have told me sooner | A NOTIFICATION names the problem exactly; read the router log before touching config. AS renumbering is a two-sided change: the side that moves first breaks the session until the other follows. |

| Beat | Answer (cause 2) |
|---|---|
| Hypothesis | Sessions up and curl *mostly* works again (27/30 in testing), yet `verify.sh` fails "FRR has a route to 10.202.0.20" → FRR forwards on something less specific; the /32s are filtered on input. |
| Tool | `docker exec lab-frr vtysh -c 'show ip route 10.202.0.20'`; `… -c 'show bgp summary'` |
| Expected if right | `Routing entry for 10.202.0.0/24` via **all three** nodes — the `serviceExternalIPs` aggregate every node announces. It hides the outage: the control plane gets a share and drops it (Local). `State/PfxRcd` is 1 per node: it counts *accepted* prefixes only. |
| Tool 2 | Received vs accepted needs Adj-RIB-In: `docker exec lab-frr vtysh -c 'conf t' -c 'router bgp 65000' -c 'address-family ipv4 unicast' -c 'neighbor CLUSTER soft-reconfiguration inbound' -c 'end' -c 'clear bgp * soft in'`, then `… -c 'show bgp ipv4 unicast neighbors <worker-ip> received-routes'` and `… filtered-routes` (both print `% Inbound soft reconfiguration not enabled` without it) |
| Expected if right | `Total number of prefixes 3 (2 filtered)` on a worker with endpoints: the /32 and its pod block filtered. |
| Tool 3 | `docker exec lab-frr vtysh -c 'show ip prefix-list detail CLUSTER-IN'` |
| Expected if right | `seq 10 permit 10.202.0.0/24 (hit count: …)` — no `le 32`. |
| What would have told me sooner | Alert on "no /32 for the Service IP in the fabric" — not on reachability, which the /24 aggregate keeps mostly green. Review prefix-list diffs for missing `ge`/`le` — it's the classic one-character outage. |

## Fix

The ticket says the fabric **hasn't** moved to 65001 yet, so the cluster
side jumped early: revert it. Restore the filter.

```bash
calicoctl patch bgppeer lab-frr -p '{"spec":{"asNumber":65000}}'
docker exec lab-frr vtysh -c 'conf t' -c 'no ip prefix-list CLUSTER-IN' -c 'ip prefix-list CLUSTER-IN seq 10 permit 10.202.0.0/24 le 32'
docker exec lab-frr vtysh -c 'clear bgp * soft in'
bash verify.sh
```
