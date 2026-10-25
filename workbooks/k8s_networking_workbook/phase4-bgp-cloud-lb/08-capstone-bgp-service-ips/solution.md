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

## What was injected

<!--FAULT-->
```bash
export KUBECONFIG="$HOME/.kube/config" DATASTORE_TYPE=kubernetes
[ "$(kubectl config current-context)" = kind-lab-calico ] || { echo "run: kubectl config use-context kind-lab-calico"; exit 1; }
calicoctl get bgppeer lab-frr >/dev/null 2>&1 || { echo "Calico BGPPeer 'lab-frr' not found — build the capstone first"; exit 1; }
docker exec lab-frr vtysh -c 'show ip prefix-list CLUSTER-IN' 2>/dev/null | grep -q CLUSTER-IN || { echo "FRR prefix-list CLUSTER-IN not found — build the capstone first"; exit 1; }
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
          docker exec lab-client curl -m3 http://10.202.0.20/   → timeout
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
| Expected if right | neighbors cycling Idle/Active; "Bad peer AS" (code 2, subcode 2) received from the nodes. |
| Tool 2 | `calicoctl get bgppeer lab-frr -o yaml` |
| Expected if right | `asNumber: 65001`. |
| What would have told me sooner | A NOTIFICATION names the problem exactly; read the router log before touching config. AS renumbering is a two-sided change: the side that moves first breaks the session until the other follows. |

| Beat | Answer (cause 2) |
|---|---|
| Hypothesis | Sessions up but still no route → filtered on input. |
| Tool | `docker exec lab-frr vtysh -c 'show bgp summary'` (PfxRcd vs PfxSnt / accepted) and `… -c 'show bgp neighbors <node-ip> received-routes'` (needs `soft-reconfiguration inbound`) or `… -c 'show bgp ipv4 unicast neighbors <node-ip> filtered-routes'` |
| Expected if right | routes received, none accepted. |
| Tool 2 | `docker exec lab-frr vtysh -c 'show ip prefix-list CLUSTER-IN'` |
| Expected if right | `seq 10 permit 10.202.0.0/24` — no `le 32`. |
| What would have told me sooner | Alert on "accepted prefixes from the cluster = 0" (or on the Service IP disappearing from the fabric). Review prefix-list diffs for missing `ge`/`le` — it's the classic one-character outage. |

## Fix

The ticket says the fabric **hasn't** moved to 65001 yet, so the cluster
side jumped early: revert it. Restore the filter.

```bash
calicoctl patch bgppeer lab-frr -p '{"spec":{"asNumber":65000}}'
docker exec lab-frr vtysh -c 'conf t' -c 'no ip prefix-list CLUSTER-IN' -c 'ip prefix-list CLUSTER-IN seq 10 permit 10.202.0.0/24 le 32'
docker exec lab-frr vtysh -c 'clear bgp * soft in'
bash verify.sh
```
