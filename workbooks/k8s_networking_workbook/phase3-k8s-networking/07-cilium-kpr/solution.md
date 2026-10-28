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
cat <<'T'

TICKET  After "a config cleanup" on lab-cilium:
          curl -m3 http://<any node IP>:30080        → fails (from the WSL host), every node
        Inside the cluster everything looks fine: the client pod reaches
        web by name, web pods answer on their IPs, all Cilium pods are
        Running. "We only removed settings we didn't recognise."
T
```
<!--/FAULT-->

Cilium's kube-proxy replacement was switched off on a cluster that has no
kube-proxy. With `kube-proxy-replacement=false`, Cilium 1.20 still
implements ClusterIP, but only that: NodePort, LoadBalancer, externalIPs
and HostPort are disabled, and nothing else implements them. ClusterIP
also changes how it works: the socket LB is off, so the VIP is DNATed per
packet at tc again. The client's capture shows the SYN going to the
ClusterIP, as in lab 3.02, not to a pod IP as in §2.4. In-cluster users
see no difference, which is why the cleanup looked harmless.

## Diagnosis path

| Beat | Answer |
|---|---|
| Hypothesis | NodePort fails on every node while ClusterIP works → the NodePort implementation is missing, not one Service or one node. |
| Tool | `kubectl -n kube-system get ds,pods \| grep -E 'kube-proxy\|cilium'` and `cilium config view \| grep kube-proxy-replacement` |
| Expected if right | no kube-proxy anywhere; `kube-proxy-replacement false`. |
| Tool 2 | `$X cilium-dbg status --verbose \| sed -n '/KubeProxyReplacement Details/,/^BPF Maps/p'` and `$X cilium-dbg service list \| grep -c NodePort` |
| Expected if right | `Status: False`, `Socket LB: Disabled`, `NodePort: Disabled`; 0 NodePort entries (only ClusterIPs left). |
| Tool 3 | repeat §2.4's capture in the client |
| Expected if right | the SYN goes to the ClusterIP now: the socket LB is off, so the datapath changed even though ClusterIP still works. |
| What would have told me sooner | Knowing, for every cluster you run, **which component implements Services** (kube-proxy in which mode, or the CNI). The first question on any "Services broken, pods fine" ticket. The `cilium` CLI's summary doesn't show KubeProxyReplacement any more; `cilium-dbg status` in an agent does, and so does the `cilium-config` ConfigMap. Alert on it if you run kube-proxy-free. |

## Fix

```bash
cilium config set kube-proxy-replacement true      # restarts the agents
cilium status --wait
for i in $(seq 9); do curl -s -m3 http://$W:30080 | grep Hostname; done | sort | uniq -c
kubectl -n lab-cil exec client -- sh -c "tcpdump -nni eth0 -c1 tcp port 80 2>/dev/null & sleep 1; curl -s -o /dev/null web; sleep 1"   # SYN to a pod IP again
```

## Why it matters later

Migrations from kube-proxy to Cilium KPR (or back) are exactly where this
happens: kube-proxy removed before KPR is on, or a Helm upgrade that drops
`kubeProxyReplacement` from the values. On OpenShift, OVN-Kubernetes
implements Services (OVN load balancers) and there is no kube-proxy either
(lab 3.10).
