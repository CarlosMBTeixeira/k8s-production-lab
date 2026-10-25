# Lab 3.12 — solution

## What was injected

<!--FAULT-->
```bash
export KUBECONFIG="$WB_DIR/../../kubernetes/admin.conf"
kubectl get crd peerauthentications.security.istio.io >/dev/null || { echo "Istio not installed (pipeline option 8)"; exit 1; }
kubectl apply -f "$LAB_DIR/apps.yaml" >/dev/null
# --- the fault ---
kubectl apply -f - >/dev/null <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata: {name: client-v2, namespace: lab-mesh}
spec:
  replicas: 1
  selector: {matchLabels: {app: client-v2}}
  template:
    metadata:
      labels: {app: client-v2}
      annotations:
        traffic.sidecar.istio.io/excludeOutboundPorts: "80"
    spec:
      containers:
        - {name: netshoot, image: "nicolaka/netshoot:v0.13", command: ["sleep", "infinity"]}
YAML
for d in web client client-v2; do kubectl -n lab-mesh rollout status deploy/$d --timeout=180s >/dev/null; done
cat <<'T'

TICKET  The new client-v2 in lab-mesh can't call web:
          kubectl -n lab-mesh exec deploy/client-v2 -c netshoot -- curl -s -m3 web   → "Recv failure: Connection reset by peer"
          kubectl -n lab-mesh exec deploy/client    -c netshoot -- curl -s -m3 web   → works
        Both pods are 2/2 Running (sidecar injected). "It's the same image
        and the same namespace."
T
```
<!--/FAULT-->

client-v2 carries `traffic.sidecar.istio.io/excludeOutboundPorts: "80"`.
istio-cni writes a RETURN for destination port 80 into ISTIO_OUTPUT, so the
app's request to web:80 skips the sidecar and leaves as plaintext. web's
sidecar is in STRICT mode and resets it. The pod shows 2/2 Ready — the
sidecar is there, it's just not in the path.

## Diagnosis path

| Beat | Answer |
|---|---|
| Hypothesis | Same namespace, same mesh, one client works → that client's traffic isn't going through its sidecar. |
| Tool | `kubectl -n lab-mesh get pod -l app=client-v2 -o jsonpath='{.items[0].metadata.annotations}'` vs client's |
| Expected if right | an `excludeOutboundPorts: "80"` annotation on v2 only. |
| Tool 2 | ephemeral netshoot in client-v2 (§2.2): `iptables-save -t nat \| grep -- '--dport 80'` |
| Expected if right | `-A ISTIO_OUTPUT -p tcp -m tcp --dport 80 -j RETURN` before the redirect. |
| Tool 3 | the §2.4 capture on web's veth while client-v2 curls |
| Expected if right | a plaintext `GET / HTTP/1.1` from client-v2's IP followed by a RST — not a ClientHello. |
| What would have told me sooner | `istioctl x describe pod` and Kiali show "no mTLS" edges; `istio_requests_total` from client-v2 never appears (its sidecar never sees the request) while web's sidecar logs connection resets. The annotations on a pod template are part of the network config — review them like policy. |

## Fix

```bash
kubectl -n lab-mesh patch deploy client-v2 --type json \
  -p '[{"op":"remove","path":"/spec/template/metadata/annotations/traffic.sidecar.istio.io~1excludeOutboundPorts"}]'
kubectl -n lab-mesh rollout status deploy/client-v2
kubectl -n lab-mesh exec deploy/client-v2 -c netshoot -- curl -s -o /dev/null -w '%{http_code}\n' web
```

(`~1` is JSON-Patch's escape for `/` in a key.)

## Why it matters later

The same bypass appears as `excludeOutboundIPRanges` (to "speed up" calls
to a database), as apps running as uid 1337, or as hostNetwork pods. On
OpenShift Service Mesh 3 the redirect is the same mechanism, installed by
the IstioCNI resource.
