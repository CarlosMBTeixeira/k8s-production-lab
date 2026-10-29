# Lab 3.05 — solution

## What was injected

<!--FAULT-->
```bash
export KUBECONFIG="$WB_DIR/../../kubernetes/admin.conf"
kubectl delete ns lab-np-front lab-np-back lab-np-other --ignore-not-found --wait=true >/dev/null
kubectl apply -f "$LAB_DIR/apps.yaml" >/dev/null
for f in 01-back-default-deny 02-allow-frontend-to-api 03-allow-api-to-db 05-front-default-deny-egress 07-allow-frontend-egress-to-back; do
  kubectl apply -f "$LAB_DIR/policies/$f.yaml" >/dev/null
done
# --- the fault ---
kubectl apply -f - >/dev/null <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: allow-dns, namespace: lab-np-front}
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - podSelector: {matchLabels: {k8s-app: kube-dns}}
      ports:
        - {protocol: UDP, port: 53}
        - {protocol: TCP, port: 53}
YAML
kubectl -n lab-np-back rollout status deploy/api --timeout=120s >/dev/null
kubectl -n lab-np-front wait --for=condition=Ready pod --all --timeout=120s >/dev/null
kubectl -n lab-np-other wait --for=condition=Ready pod --all --timeout=120s >/dev/null
cat <<'T'

TICKET  The frontend team rolled out "zero trust" in lab-np-front: default
        deny egress, plus allows for DNS and for the api. Now:
          kubectl -n lab-np-front exec frontend -- curl -m3 http://api.lab-np-back   → fails
          kubectl -n lab-np-front exec frontend -- curl -m3 http://<api ClusterIP>  → works
        "The api allow is there and DNS is allowed — we checked."
        Run: bash test-matrix.sh
T
```
<!--/FAULT-->

The DNS egress policy has a `podSelector: k8s-app=kube-dns` **without a
namespaceSelector**. A lone podSelector means "pods in this policy's
namespace" — lab-np-front, where no pod has that label. So DNS egress is
allowed to nobody, and every name lookup from lab-np-front is dropped.

## Diagnosis path

| Beat | Answer |
|---|---|
| Hypothesis | By IP works, by name fails → the data path to api is allowed; DNS isn't. |
| Tool | `kubectl -n lab-np-front exec frontend -- dig +short +time=2 api.lab-np-back.svc.cluster.local` |
| Expected if right | timeout (`connection timed out; no servers could be reached`), not NXDOMAIN. |
| Tool 2 | `kubectl -n lab-np-front get networkpolicy allow-dns -o yaml` (or `kubectl describe`) |
| Expected if right | `to:` has only `podSelector: k8s-app=kube-dns`. `kubectl describe` spells it out: "To: PodSelector: k8s-app=kube-dns" with no NamespaceSelector. |
| What would have told me sooner | `kubectl describe networkpolicy` reads selectors back in English — always read it after writing a policy. Policy linting in CI (or a dry-run reachability tool) catches "selector matches zero pods". On Cilium, `hubble observe --verdict DROPPED --port 53` names it in one line (lab 3.08). |

## Fix

```bash
kubectl -n lab-np-front patch networkpolicy allow-dns --type json -p '[{"op":"add","path":"/spec/egress/0/to/0/namespaceSelector","value":{"matchLabels":{"kubernetes.io/metadata.name":"kube-system"}}}]'
bash test-matrix.sh
```

Or apply `policies/06-allow-dns.yaml`, which is the correct version.

## Why it matters later

This is the most common NetworkPolicy outage there is: a default-deny
egress rolled out with a DNS allow that selects nothing. Symptoms are
always "names don't work, IPs do", and on clusters with NodeLocal DNSCache
the fix also needs an `ipBlock` for the link-local cache address.
