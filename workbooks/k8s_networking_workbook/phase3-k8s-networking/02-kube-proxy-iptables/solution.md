# Lab 3.02 — solution

## What was injected

<!--FAULT-->
```bash
export KUBECONFIG="$WB_DIR/../../kubernetes/admin.conf"
if [ -n "$(kubectl -n kube-system get ds kube-proxy -o jsonpath='{.spec.template.spec.affinity}')" ]; then
  echo "kube-proxy already has an affinity — refusing to overwrite it."; exit 1
fi
kubectl apply -f "$LAB_DIR/web.yaml" >/dev/null
kubectl -n lab-svc rollout status deploy/web --timeout=120s >/dev/null
kubectl -n lab-svc wait --for=condition=Ready pod/client-w1 pod/client-w2 --timeout=120s >/dev/null
# --- the fault ---
kubectl -n kube-system patch ds kube-proxy --type merge -p '{"spec":{"template":{"spec":{"affinity":{"nodeAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"kubernetes.io/hostname","operator":"NotIn","values":["worker-2"]}]}]}}}}}}}' >/dev/null
for i in $(seq 60); do
  kubectl -n kube-system get pods -l k8s-app=kube-proxy -o wide --no-headers | grep -q worker-2 || break
  sleep 2
done
kubectl -n lab-svc rollout restart deploy/web >/dev/null
kubectl -n lab-svc rollout status deploy/web --timeout=120s >/dev/null
cat <<'T'

TICKET  "web" in lab-svc is down — but only for some callers.
          kubectl -n lab-svc exec client-w2 -- curl -m3 web   → timeout
          kubectl -n lab-svc exec client-w1 -- curl -m3 web   → fine
        The web pods are Running and Ready; the Service and its
        EndpointSlice look correct. Nothing changed in lab-svc except a
        routine rollout restart.
T
```
<!--/FAULT-->

kube-proxy no longer runs on worker-2. Its iptables rules stay where they
were (kube-proxy doesn't flush on exit), so worker-2 keeps DNATing `web` to
the **old** pod IPs. After the rollout restart, those pods are gone: clients
on worker-2 time out, clients elsewhere are fine.

## Diagnosis path

| Beat | Answer |
|---|---|
| Hypothesis | Only clients on worker-2 fail → per-node Service rendering is stale on worker-2. |
| Tool | `kubectl -n lab-svc get endpointslices -l kubernetes.io/service-name=web -o jsonpath='{..addresses}'` vs `ssh w-2 "sudo iptables-save -t nat \| grep 'lab-svc/web' \| grep -o 'to-destination [0-9.:]*'"` |
| Expected if right | worker-2's DNAT targets don't match the slice; worker-1's do. |
| Tool 2 | `kubectl -n kube-system get pods -l k8s-app=kube-proxy -o wide` |
| Expected if right | 3 pods; none on worker-2. `kubectl -n kube-system get ds kube-proxy` shows DESIRED 3. |
| Tool 3 | `kubectl -n kube-system get ds kube-proxy -o jsonpath='{.spec.template.spec.affinity}'` |
| Expected if right | a `NotIn [worker-2]` node affinity. |
| What would have told me sooner | DaemonSet `DESIRED` < node count, and `kubeproxy_sync_proxy_rules_last_timestamp_seconds` missing for one node. An alert on "kube-proxy (or the CNI agent) not running on a Ready node" catches this class instantly. |

## Fix

```bash
kubectl -n kube-system patch ds kube-proxy --type json -p '[{"op":"remove","path":"/spec/template/spec/affinity"}]'
kubectl -n kube-system rollout status ds/kube-proxy
kubectl -n lab-svc exec client-w2 -- sh -c 'for i in $(seq 10); do curl -s -m2 -o /dev/null -w "%{http_code}\n" web; done' | sort | uniq -c
```

## Why it matters later

The same failure shape — stale datapath on one node — happens with a
crash-looping Cilium agent, a kube-proxy that can't reach the API server
(expired cert, network partition), or an OVN-K node component down. The
check is always the same: source of truth vs what that node rendered.
