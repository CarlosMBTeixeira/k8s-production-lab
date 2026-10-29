# Lab 3.10 — solution

## What was injected

<!--FAULT-->
```bash
export KUBECONFIG="${OVN_KUBECONFIG:-$HOME/ovn.conf}"
kubectl -n ovn-kubernetes get pods >/dev/null || { echo "OVN-K cluster not reachable with $KUBECONFIG"; exit 1; }
kubectl delete ns lab-ovn --ignore-not-found --wait=true >/dev/null
kubectl apply -f "$LAB_DIR/apps.yaml" >/dev/null
kubectl -n lab-ovn rollout status deploy/web --timeout=180s >/dev/null
kubectl -n lab-ovn wait --for=condition=Ready pod/client --timeout=180s >/dev/null
# --- the fault ---
kubectl apply -f - >/dev/null <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-monitoring
  namespace: lab-ovn
  annotations: {description: "let Prometheus scrape our pods"}
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress:
    - from: [{namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: monitoring}}}]
YAML
cat <<'T'

TICKET  In lab-ovn, the client can no longer reach the web Service:
          kubectl -n lab-ovn exec client -- curl -m3 web    → timeout
        Pods are Ready, the Service has 2 endpoints, nobody deployed app
        changes. "The monitoring team added something to let Prometheus
        scrape us, that's all."
T
```
<!--/FAULT-->

A NetworkPolicy called `allow-monitoring` selects **every pod** in lab-ovn
for Ingress and allows only the `monitoring` namespace. Its name says
"allow"; its effect is default-deny for everyone else, including `client`.
OVN-K renders it as ACLs on a port group containing every lab-ovn pod.

## Diagnosis path

| Beat | Answer |
|---|---|
| Hypothesis | Pods, Service and endpoints are fine (nothing changed there), so something in the logical pipeline drops the flow — policy is the usual suspect. |
| Tool | `$T -src-namespace lab-ovn -src client -dst-namespace lab-ovn -dst $WEB -tcp -dst-port 80 -loglevel 2 2>&1 \| grep -B2 'reg8\[17\] = 1'` (the summary line says "indicates failure") |
| Expected if right | the trace dies on the destination side in `ls_out_acl_eval`, matching `outport == @a<number>`; `reg8[17] = 1` is OVN's drop flag. Name the port group: `$NB --columns=name,external_ids find Port_Group name=a<number>` → `NetpolNamespace:lab-ovn:Ingress`, the namespace's ingress default-deny. Grepping the trace for `acl\|drop` only shows the stages it passed. |
| Tool 2 | `kubectl -n lab-ovn get networkpolicy`; `$NB find ACL 'external_ids{>=}{"k8s.ovn.org/name"="lab-ovn:allow-monitoring"}'` (external_ids keys vary by version; `$NB list ACL \| grep -B5 lab-ovn` works anywhere) |
| Expected if right | one policy, `podSelector: {}`, ingress from `kubernetes.io/metadata.name=monitoring` only. |
| What would have told me sooner | `kubectl get networkpolicy -n <ns>` is step one for any "pods can't talk" ticket in a namespace that just changed — names lie, selectors don't. ovnkube-trace names the stage in one command. |

## Fix

Either delete it, or make it what its name claims (an allow that doesn't
isolate everything) — which in NetworkPolicy terms is impossible: any
ingress policy selecting a pod isolates it. So add the missing allow:

```bash
kubectl -n lab-ovn delete networkpolicy allow-monitoring
# or keep it and allow in-namespace traffic too:
kubectl -n lab-ovn apply -f - <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: allow-same-namespace, namespace: lab-ovn}
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress: [{from: [{podSelector: {}}]}]
YAML
kubectl -n lab-ovn exec client -- curl -s -m3 web | grep Hostname
```

## Why it matters later

On OpenShift, cluster admins may also have AdminNetworkPolicies and
BaselineAdminNetworkPolicies that you won't see with `oc get networkpolicy`
(lab 3.11). The trace finds them anyway; that's why it's the first tool.
