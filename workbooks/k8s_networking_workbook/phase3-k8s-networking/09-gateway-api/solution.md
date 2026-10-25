# Lab 3.09 — solution

## What was injected

<!--FAULT-->
```bash
export KUBECONFIG="$WB_DIR/../../kubernetes/admin.conf"
kubectl apply -f "$LAB_DIR/base.yaml" >/dev/null
kubectl apply -f "$LAB_DIR/routes/01-basic.yaml" >/dev/null
kubectl -n lab-gw wait --for=condition=Programmed gateway/lab-gw --timeout=180s >/dev/null
# --- the fault ---
kubectl apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Namespace
metadata: {name: lab-gw-team2}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: team2, namespace: lab-gw-team2}
spec:
  replicas: 1
  selector: {matchLabels: {app: team2}}
  template:
    metadata: {labels: {app: team2}}
    spec:
      containers: [{name: whoami, image: "traefik/whoami:v1.10.3", args: ["--name", "team2"], ports: [{containerPort: 80}]}]
---
apiVersion: v1
kind: Service
metadata: {name: team2, namespace: lab-gw-team2}
spec: {selector: {app: team2}, ports: [{port: 80, targetPort: 80}]}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: team2, namespace: lab-gw-team2}
spec:
  parentRefs: [{name: lab-gw, namespace: lab-gw}]
  hostnames: ["team2.lab.local"]
  rules:
    - backendRefs: [{name: team2, port: 80}]
YAML
kubectl -n lab-gw-team2 rollout status deploy/team2 --timeout=120s >/dev/null
GW=$(kubectl -n lab-gw get gateway lab-gw -o jsonpath='{.status.addresses[0].value}')
cat <<T

TICKET  Team 2 onboarded to the shared Gateway (lab-gw, $GW) today.
        Their manifests applied cleanly, pods are Ready, the Service has
        endpoints. But:
          curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: team2.lab.local' http://$GW/   → 404
        web.lab.local (team 1) works on the same Gateway.
T
```
<!--/FAULT-->

Team 2's namespace lacks the `gateway-access: "true"` label that the
Gateway's listeners select on. The HTTPRoute is valid, so `kubectl apply`
succeeds, but the Gateway refuses to attach it: no listener accepts it, so
no Envoy route exists for `team2.lab.local`, and Envoy answers 404.

## Diagnosis path

| Beat | Answer |
|---|---|
| Hypothesis | 404 from the Gateway (not 503/500) = Envoy has no route for that host; the route never attached. |
| Tool | `st lab-gw-team2 team2` |
| Expected if right | `Accepted=False (NotAllowedByListeners)`. |
| Tool 2 | `kubectl -n lab-gw get gateway lab-gw -o jsonpath='{.spec.listeners[*].allowedRoutes}'` and `kubectl get ns lab-gw-team2 --show-labels` |
| Expected if right | listeners select `gateway-access=true`; the namespace doesn't have it. |
| What would have told me sooner | Route status, every time: a CI/ArgoCD health check on HTTPRoutes that requires `Accepted=True` would have failed the deploy instead of the users. `kubectl get httproute -A` shows nothing useful by default — the status is the only signal. |

## Fix

The platform's contract is the label; grant it (as the platform team would):

```bash
kubectl label ns lab-gw-team2 gateway-access=true
sleep 3; st lab-gw-team2 team2
curl -s -H 'Host: team2.lab.local' http://$GW/ | grep '^Name'
```

## Why it matters later

On OpenShift, Routes have a similar gate: router sharding by namespace or
route labels (`IngressController.spec.namespaceSelector` / `routeSelector`).
"Route admitted?" is the same first question: `oc get route -o yaml` →
`status.ingress[].conditions`.
