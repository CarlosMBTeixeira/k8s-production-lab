# Lab 3.13 — solution

## Reference build

```bash
# 1. Gateway API CRDs — the version Cilium's docs list for your release
#    (Cilium 1.20 → v1.6.1, whose standard channel includes TLSRoute):
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml

# 2. Cilium
cilium install \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=lab-cilium-control-plane --set k8sServicePort=6443 \
  --set ipam.mode=kubernetes \
  --set gatewayAPI.enabled=true \
  --set l2announcements.enabled=true --set devices='{eth0}' \
  --set k8sClientRateLimit.qps=20 --set k8sClientRateLimit.burst=40 \
  --set hubble.relay.enabled=true --set hubble.ui.enabled=true
cilium status --wait
kubectl get gatewayclass cilium

# 3–6
envsubst < reference/lb.yaml.tpl | kubectl apply -f -
kubectl apply -f reference/app.yaml -f reference/gateway.yaml -f reference/policies.yaml
kubectl -n lab-cap wait --for=condition=Programmed gateway/app --timeout=120s

# 7
cilium hubble port-forward &
kubectl apply -f probes.yaml && bash verify.sh
```

## What was injected

<!--FAULT-->
```bash
export KUBECONFIG="$HOME/.kube/config"
K="kubectl --context kind-lab-cilium"
$K -n lab-cap get httproute app >/dev/null 2>&1 || { echo "HTTPRoute lab-cap/app not found — build the capstone first"; exit 1; }
# --- fault 1: DNS ---
POD=$($K -n kube-system get pods -l k8s-app=kube-dns -o jsonpath='{.items[0].metadata.name}')
ORIG=$($K -n kube-system get cep "$POD" -o jsonpath='{.status.identity.id}')
$K -n kube-system label pod "$POD" lab-quarantine=true --overwrite >/dev/null
$K apply -f - >/dev/null <<'YAML'
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: platform-dns-maintenance
  annotations: {description: "drain coredns pod for maintenance"}
spec:
  endpointSelector:
    matchLabels: {k8s:io.kubernetes.pod.namespace: lab-cap}
  egressDeny:
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            k8s:lab-quarantine: "true"
      toPorts: [{ports: [{port: "53", protocol: ANY}]}]
YAML
# a label change gives the pod a new identity, asynchronously (~30 s)
for i in $(seq 60); do
  [ "$($K -n kube-system get cep "$POD" -o jsonpath='{.status.identity.id}')" != "$ORIG" ] && break
  sleep 2
done
# --- fault 2: web ---
$K -n lab-cap patch httproute app --type json -p '[{"op":"replace","path":"/spec/rules/0/backendRefs/0/port","value":8080}]' >/dev/null
GW=$($K -n lab-cap get gateway app -o jsonpath='{.status.addresses[0].value}')
cat <<T

TICKET  P2, two reports within ten minutes on lab-cap:
        1. "The app is down": curl -H 'Host: app.lab.local' http://$GW/  → HTTP 503, "no healthy upstream"
        2. "Everything in lab-cap is slow and flaky — DNS?"
             kubectl -n lab-cap exec probe-frontend -- sh -c 'for i in 1 2 3 4 5 6; do time dig +short api.lab-cap.svc.cluster.local; done'
        The platform team did "some CoreDNS maintenance" this morning.
        Nobody changed lab-cap's policies.
T
```
<!--/FAULT-->

Two independent changes:

1. **DNS.** One CoreDNS pod got a label, and a cluster-wide policy denies
   lab-cap's DNS egress to pods with that label. Lookups that land on the
   other CoreDNS pod work; the rest time out and retry. Intermittent DNS
   with multi-second stalls (dig's 5 s timeout), and some lookups fail
   outright: the socket LB picks the backend once per UDP socket, so
   dig's retries go to the same blocked pod.

   The label change doesn't act at once: Cilium gives the pod a new
   security identity (labels are part of it) asynchronously, here in
   about 30 s, and only then does the deny match. "Maintenance at 9:00,
   DNS broke at 9:01" is normal for label-driven policy.
2. **Web.** The HTTPRoute's backend port was changed to 8080. The
   `frontend` Service has no port 8080, so the route's backend can't be
   resolved: Cilium's Envoy has a route for the host but an empty cluster,
   and answers 503 "no healthy upstream".

## Diagnosis path — DNS

| Beat | Answer |
|---|---|
| Hypothesis | Intermittent, not total → one of several backends is unreachable for these clients (DNS has 2 CoreDNS pods behind one VIP). |
| Tool | `hubble observe --from-namespace lab-cap --to-namespace kube-system --port 53 --since 2m -o compact` (`-n` can't be combined with `--to-namespace`) |
| Expected if right | drops only toward **one** coredns pod, `Policy denied by denylist DROPPED (UDP)`; flows to the other pod FORWARDED. Not `--protocol dns`: the drop happens at L3/L4 before the DNS proxy, so there's no DNS-level record of it. |
| Tool 2 | `kubectl get ccnp`; `kubectl -n kube-system get pods -l k8s-app=kube-dns --show-labels` |
| Expected if right | `platform-dns-maintenance` with an `egressDeny`; one CoreDNS pod labelled `lab-quarantine=true`, with a different identity from its twin (`kubectl -n kube-system get cep`). |
| What would have told me sooner | Per-backend DNS success, not per-Service: Hubble's DNS metrics by destination, or CoreDNS's own `coredns_dns_requests_total` per pod showing one pod receiving nothing from lab-cap. `kubectl get ccnp` belongs in the first minute of any policy-shaped incident — namespace owners can't see cluster-wide policies from `kubectl get cnp`. |

## Diagnosis path — web

| Beat | Answer |
|---|---|
| Hypothesis | 503 "no healthy upstream" from the Gateway (not 404, not timeout) → a route matched but its backend has no usable endpoints. |
| Tool | `kubectl -n lab-cap get httproute app -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}'` |
| Expected if right | `ResolvedRefs=False (BackendNotFound)`: "Service port 8080 could not be resolved for backend lab-cap/frontend". |
| Tool 2 | `kubectl -n lab-cap get svc frontend -o jsonpath='{.spec.ports}'` |
| Expected if right | port 80 only. |
| What would have told me sooner | Route status in the deploy pipeline (lab 3.09's lesson). `hubble observe --from-identity 8 --to-namespace lab-cap --since 1m` (8 = the reserved `ingress` identity) shows **no** flows during the 503s — Envoy never even tried. After the fix it shows Gateway → frontend flows. |

## Fix

```bash
kubectl delete ccnp platform-dns-maintenance
kubectl -n kube-system label pod -l k8s-app=kube-dns lab-quarantine-
kubectl -n lab-cap patch httproute app --type json -p '[{"op":"replace","path":"/spec/rules/0/backendRefs/0/port","value":80}]'
bash verify.sh
```
