# Lab 3.03 — solution

## What was injected

<!--FAULT-->
```bash
K="kubectl --kubeconfig $HOME/.kube/config --context kind-lab-ipvs"
$K get nodes >/dev/null || { echo "kind cluster lab-ipvs not reachable"; exit 1; }
$K delete ns lab-modes --ignore-not-found --wait=true >/dev/null
# --- the fault ---
$K -n kube-system get cm kube-proxy -o yaml | sed -E 's/scheduler: .*/scheduler: sh/' | $K apply -f - >/dev/null
$K -n kube-system rollout restart ds/kube-proxy >/dev/null
$K -n kube-system rollout status ds/kube-proxy --timeout=120s >/dev/null
$K apply -f "$LAB_DIR/web.yaml" >/dev/null
$K -n lab-modes rollout status deploy/web --timeout=120s >/dev/null
$K -n lab-modes wait --for=condition=Ready pod/client --timeout=120s >/dev/null
cat <<'T'

TICKET  On lab-ipvs, "web" has 3 healthy replicas but all traffic from the
        frontend lands on one of them; the other two are idle.
          kubectl -n lab-modes exec client -- sh -c 'for i in $(seq 30); do curl -s web | grep Hostname; done' | sort | uniq -c
        Nobody touched the web Service.
T
```
<!--/FAULT-->

kube-proxy's IPVS scheduler was set to `sh` (source hashing): every
connection from one client IP goes to the same real server. With a single
client pod, one backend takes all the traffic.

## Diagnosis path

| Beat | Answer |
|---|---|
| Hypothesis | "Always the same backend" = affinity. Either the Service asks for it (`sessionAffinity: ClientIP`) or the balancer does it by itself. |
| Tool | `kubectl -n lab-modes get svc web -o jsonpath='{.spec.sessionAffinity}'` |
| Expected if right | `None` — the Service is innocent (the decoy). |
| Tool 2 | `dbg lab-ipvs-worker ipvsadm -Ln -t $VIP:80` |
| Expected if right | `TCP <VIP>:80 sh` instead of `rr`; ActiveConn/InActConn on one real server only. With ClientIP affinity you'd see `persistent 10800` instead. |
| Tool 3 | `kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' \| grep -A3 '^ipvs:'` |
| Expected if right | `scheduler: sh` |
| What would have told me sooner | Per-pod request rate (any RED dashboard) showing one pod hot and the rest idle. On the node, `ipvsadm -Ln --stats` shows the skew directly. |

## Fix

```bash
kubectl -n kube-system get cm kube-proxy -o yaml | sed 's/scheduler: sh/scheduler: ""/' | kubectl apply -f -
kubectl -n kube-system rollout restart ds/kube-proxy && kubectl -n kube-system rollout status ds/kube-proxy
kubectl -n lab-modes delete svc web && kubectl apply -f web.yaml     # fresh virtual server, to be sure
kubectl -n lab-modes exec client -- sh -c 'for i in $(seq 30); do curl -s web | grep Hostname; done' | sort | uniq -c
```

## Why it matters later

`sh` is legitimate (cheap stickiness), but behind a NAT or a gateway every
request has the same source IP, and "load balancing" becomes "one pod".
Same lesson as gRPC in lab 4.06: what the balancer hashes on decides the spread.
