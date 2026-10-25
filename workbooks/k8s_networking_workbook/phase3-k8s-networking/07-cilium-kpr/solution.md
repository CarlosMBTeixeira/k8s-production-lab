# Lab 3.07 — solution

## What was injected

<!--FAULT-->
```bash
export KUBECONFIG="$HOME/.kube/config"
K="kubectl --context kind-lab-cilium"; CI="cilium --context kind-lab-cilium"
$CI status >/dev/null 2>&1 || { echo "Cilium not healthy on lab-cilium — finish §2.1 first"; exit 1; }
$K apply -f "$LAB_DIR/web.yaml" >/dev/null
$K -n lab-cil rollout status deploy/web --timeout=120s >/dev/null
$K -n lab-cil wait --for=condition=Ready pod/client --timeout=120s >/dev/null
# --- the fault ---
$CI config set kube-proxy-replacement false >/dev/null
$CI status --wait >/dev/null 2>&1 || true
sleep 10
if $K -n lab-cil exec client -- curl -s -m3 -o /dev/null "$($K -n lab-cil get svc web -o jsonpath='{.spec.clusterIP}')"; then
  echo "(note: on this Cilium version ClusterIP from pods still answers — chase the NodePort symptom)"
fi
cat <<'T'

TICKET  After "a config cleanup" on lab-cilium:
          kubectl -n lab-cil exec client -- curl -m3 web       → fails
          curl -m3 http://<any node IP>:30080                       → fails (from the WSL host)
        Calling a web pod by its IP works. All Cilium pods are Running.
        "We only removed settings we didn't recognise."
T
```
<!--/FAULT-->

Cilium's kube-proxy replacement was switched off on a cluster that has no
kube-proxy. Nothing implements ClusterIP or NodePort any more: pods talk to
pod IPs fine, Service VIPs go nowhere, and even the `kubernetes` Service
breaks for anything that relies on it (CoreDNS reaching the API, for one —
watch it degrade).

## Diagnosis path

| Beat | Answer |
|---|---|
| Hypothesis | Pod IP works, ClusterIP and NodePort don't, everywhere → the Service implementation is missing, not one Service. |
| Tool | `kubectl -n lab-cil exec client -- curl -s -m3 <a web pod IP>` vs `… curl -m3 <ClusterIP>` |
| Expected if right | pod IP 200; ClusterIP timeout. |
| Tool 2 | `kubectl -n kube-system get ds,pods \| grep -E 'kube-proxy\|cilium'` and `cilium config view \| grep kube-proxy-replacement` |
| Expected if right | no kube-proxy anywhere; `kube-proxy-replacement false`. |
| Tool 3 | `$X cilium-dbg status \| grep KubeProxyReplacement` and `$X cilium-dbg service list` |
| Expected if right | `KubeProxyReplacement: False`; the service table empty or missing ClusterIP/NodePort entries. |
| What would have told me sooner | Knowing, for every cluster you run, **which component implements Services** (kube-proxy in which mode, or the CNI). The first question on any "Services broken, pods fine" ticket. `cilium status` prints KubeProxyReplacement on its summary; alert on it if you run kube-proxy-free. |

If on your Cilium version ClusterIP from pods still worked after the change
(break.sh tells you), the NodePort from the WSL host is the symptom to chase.

## Fix

```bash
cilium config set kube-proxy-replacement true
cilium status --wait
kubectl -n lab-cil exec client -- curl -s -m3 web | grep Hostname
curl -s http://$W:30080 | grep Hostname
kubectl -n kube-system rollout restart deploy/coredns     # if CoreDNS got stuck while the API Service was gone
```

## Why it matters later

Migrations from kube-proxy to Cilium KPR (or back) are exactly where this
happens: kube-proxy removed before KPR is on, or a Helm upgrade that drops
`kubeProxyReplacement` from the values. On OpenShift, OVN-Kubernetes
implements Services (OVN load balancers) and there is no kube-proxy either
(lab 3.10).
