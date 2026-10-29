# Lab 4.04 — solution

## What was injected

<!--FAULT-->
```bash
export KUBECONFIG="$HOME/.kube/config"
K="kubectl --context kind-lab-cilium"
$K get ciliumbgpclusterconfig lab >/dev/null 2>&1 || { echo "CiliumBGPClusterConfig 'lab' not found — do §2.1 first"; exit 1; }
$K apply -f "$LAB_DIR/web.yaml" >/dev/null
$K -n lab-cbgp rollout status deploy/web --timeout=120s >/dev/null
# --- the fault ---
for n in $($K get nodes -o name); do $K label "$n" bgp- >/dev/null 2>&1 || true; done
sleep 12
LB=$($K -n lab-cbgp get svc web -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
cat <<T

TICKET  The nodes of lab-cilium were "recycled" (same names, fresh config).
        Since then the LoadBalancer of lab-cbgp/web (${LB}) is unreachable
        from outside:
          docker exec lab-client curl -sS -m3 http://${LB}/   → curl: (28) Connection timed out
        lab-frr: "show bgp summary" lists no cluster neighbors. Cilium is healthy.
T
```
<!--/FAULT-->

The nodes lost the `bgp=on` label (as after a node pool replacement whose
template didn't carry it). The ClusterConfig's `nodeSelector` now matches
no node, so no node runs a BGP instance: no sessions, no advertisements.
The LB IP is still allocated and the Service looks healthy.

## Diagnosis path

| Beat | Answer |
|---|---|
| Hypothesis | No neighbors on FRR at all → the cluster isn't trying; BGP is configured for nobody. |
| Tool | `cilium bgp peers` |
| Expected if right | only the header line: no node has a peer. |
| Tool 2 | `kubectl get ciliumbgpnodeconfigs` and `kubectl get ciliumbgpclusterconfig lab -o jsonpath='{.spec.nodeSelector}'` |
| Expected if right | `No resources found`; selector `{"matchLabels":{"bgp":"on"}}`. |
| Tool 3 | `kubectl get nodes -L bgp` |
| Expected if right | the `BGP` column empty. |
| What would have told me sooner | The ClusterConfig says it outright: `kubectl get ciliumbgpclusterconfig lab -o json \| jq -r '.status.conditions[] \| "\(.type) \(.status) \(.message)"'` → `cilium.io/NoMatchingNode True No node matches spec.nodeSelector`. Alert on that condition. Node labels that carry configuration belong in the node pool / machine template, not in a one-off `kubectl label`. An alert on "fabric sees fewer cluster BGP neighbors than there are nodes". |

## Fix

```bash
kubectl label nodes --all bgp=on
sleep 10; cilium bgp peers
docker exec lab-client curl -s -m3 http://$(kubectl -n lab-cbgp get svc web -o jsonpath='{.status.loadBalancer.ingress[0].ip}')/ | grep Hostname
```
