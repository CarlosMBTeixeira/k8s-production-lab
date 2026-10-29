# Lab 4.03 — solution

## What was injected

<!--FAULT-->
```bash
export KUBECONFIG="$HOME/.kube/config" DATASTORE_TYPE=kubernetes
kubectl config use-context kind-lab-calico >/dev/null
docker inspect lab-frr >/dev/null 2>&1 || { echo "lab-frr not running: bash ../lib/frr-kind.sh up lab-calico frr.conf.tpl"; exit 1; }
export FRR_IP=$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' lab-frr)
# reset to a clean BGP state
calicoctl delete bgppeer peer-with-rr >/dev/null 2>&1 || true
for n in lab-calico-control-plane lab-calico-worker lab-calico-worker2; do
  kubectl label node $n route-reflector- >/dev/null 2>&1 || true
  calicoctl patch node $n -p '{"spec":{"bgp":{"routeReflectorClusterID":""}}}' >/dev/null 2>&1 || true
done
envsubst < "$LAB_DIR/bgp.yaml.tpl" | calicoctl apply -f - >/dev/null
kubectl apply -f "$LAB_DIR/web.yaml" >/dev/null
kubectl apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Pod
metadata: {name: client-w2, namespace: lab-bgp}
spec:
  nodeSelector: {kubernetes.io/hostname: lab-calico-worker2}
  containers: [{name: netshoot, image: "nicolaka/netshoot:v0.13", command: ["sleep", "infinity"]}]
---
apiVersion: v1
kind: Pod
metadata: {name: server-cp, namespace: lab-bgp}
spec:
  nodeSelector: {kubernetes.io/hostname: lab-calico-control-plane}
  tolerations: [{key: node-role.kubernetes.io/control-plane, operator: Exists, effect: NoSchedule}]
  containers: [{name: whoami, image: "traefik/whoami:v1.10.3", ports: [{containerPort: 80}]}]
YAML
kubectl -n lab-bgp wait --for=condition=Ready pod/client-w2 pod/server-cp --timeout=180s >/dev/null
# --- the fault ---
kubectl label node lab-calico-worker route-reflector=true --overwrite >/dev/null
calicoctl apply -f "$LAB_DIR/rr.yaml" >/dev/null
calicoctl patch bgpconfiguration default -p '{"spec":{"nodeToNodeMeshEnabled":false}}' >/dev/null
sleep 15
cat <<'T'

TICKET  "Migrated lab-calico from full mesh to route reflectors, as per the
        scaling plan." Since then:
          kubectl -n lab-bgp exec client-w2 -- curl -sS -m3 http://<server-cp pod IP>/   → curl: (28) Connection timed out
        Pods on lab-calico-worker still talk to everyone. All BGP sessions
        are Established. Keep the mesh disabled — that's the point of the change.
T
```
<!--/FAULT-->

The mesh is off and every node peers with the node labelled
`route-reflector=true` — but that node has **no `routeReflectorClusterID`**.
It's a plain iBGP peer, and iBGP's split-horizon rule says a route learned
from one iBGP peer is not re-advertised to another. So worker2 never learns
the control-plane's block (and vice versa); both still learn the "RR"
node's own block directly. FRR has everything and lists those blocks as
advertised to worker2, but they carry AS 64512 in the path, so BIRD imports
none of them (`bird lab-calico-worker2 show protocols all Global_<FRR_IP>`:
`0 imported`). eBGP loop prevention stops the fabric from papering over the
broken iBGP design.

## Diagnosis path

| Beat | Answer |
|---|---|
| Hypothesis | Cross-node fails for some node pairs only → missing routes between those nodes, a routing-protocol problem, not policy or the pods. |
| Tool | `docker exec lab-calico-worker2 ip route \| grep bird` (and on control-plane) |
| Expected if right | worker2 has the worker's block but **not** the control-plane's; control-plane lacks worker2's. |
| Tool 2 | `bird lab-calico-worker2 show protocols` and `bird lab-calico-worker show protocols` |
| Expected if right | sessions Established to the "RR" and FRR, no mesh — so the topology depends on reflection. |
| Tool 3 | `calicoctl get node lab-calico-worker -o yaml \| grep -i routeReflectorClusterID` |
| Expected if right | absent. |
| What would have told me sooner | "Every node has a route to every block" is a checkable invariant (count `proto bird` routes per node = number of blocks − own). Calico's docs list the RR migration order: configure RRs (cluster ID + label + BGPPeer) and verify **before** disabling the mesh. |

## Fix

```bash
calicoctl patch node lab-calico-worker -p '{"spec":{"bgp":{"routeReflectorClusterID":"244.0.0.1"}}}'
sleep 10
docker exec lab-calico-worker2 ip route | grep bird
kubectl -n lab-bgp exec client-w2 -- curl -s -m3 http://$(kubectl -n lab-bgp get pod server-cp -o jsonpath='{.status.podIP}')/ | grep Hostname
```

## Why it matters later

On large Calico (and Cilium BGP) estates the RRs are usually dedicated
nodes or the ToR switches themselves. "Some node pairs can't talk after a
BGP change" is this, or an RR that went down without a second one.
