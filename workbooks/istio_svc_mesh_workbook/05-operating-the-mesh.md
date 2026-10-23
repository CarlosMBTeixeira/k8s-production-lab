# Session 5 — Operating the mesh

**Objective:** the work that never appears in an intro course but fills
a platform team's week — controlling egress, keeping proxy config small
as the cluster grows, scoping which namespaces istiod watches, and
upgrading the control plane without a maintenance window.

**Prerequisites**
- Sessions 1 and 3. Lab with choice **5** or **6**.
- `S=https://raw.githubusercontent.com/istio/istio/1.30.7/samples`
- A meshed client: `kubectl apply -n bookinfo -f $S/curl/curl.yaml`, then
  `C=$(kubectl -n bookinfo get pod -l app=curl -o jsonpath='{.items[0].metadata.name}')`
- `P=$(kubectl -n bookinfo get pod -l app=productpage -o jsonpath='{.items[0].metadata.name}')`

**Read first:**
- istio.io → *Tasks* → *Traffic Management* → *Egress* → "Accessing
  External Services".
- istio.io → *Reference* → "Sidecar" (`egress`, `outboundTrafficPolicy`).
- istio.io → *Setup* → *Upgrade* → "Canary Upgrades" (Helm tab) and the
  "Stable revision labels" (revision tags) section.
- istio.io → *Reference* → MeshConfig → `discoverySelectors`.
- Red Hat → OpenShift Service Mesh 3 → *Updating* (to see that the same
  revision model is what the Sail Operator automates).

Course equivalents: none — this is the production layer.

---

## 5.0 — Egress: what may leave the mesh

```bash
kubectl -n bookinfo exec "$C" -c curl -- curl -s -o /dev/null -w '%{http_code}\n' http://httpbin.org/get
kubectl -n bookinfo exec "$C" -c curl -- curl -s -o /dev/null -w '%{http_code}\n' https://httpbin.org/get
kubectl -n bookinfo logs "$C" -c istio-proxy --tail=2
```

> **Hypothesis.** A service mesh controls egress by default.
>
> **Tool.** The calls and the sidecar log.
>
> **Expected if right.** It does not. Both return `200`, and the log
> shows `PassthroughCluster` — the default `outboundTrafficPolicy` is
> `ALLOW_ANY`: anything not in the registry is passed through untouched,
> with no mTLS, no metrics labels, no policy.
>
> **What would have caught this sooner.** `PassthroughCluster` in the
> outbound log, or in Kiali as a *PassthroughCluster* node. Any traffic
> there is traffic you do not control.

Now lock the namespace down and open one destination explicitly:

```bash
kubectl apply -n bookinfo -f - <<'EOF'
apiVersion: networking.istio.io/v1
kind: Sidecar
metadata: {name: default}
spec:
  egress: [{hosts: ["./*", "istio-system/*"]}]
  outboundTrafficPolicy: {mode: REGISTRY_ONLY}
EOF
```

> **Hypothesis.** Both external calls now fail the same way.
>
> **Tool.** Repeat the two curls.
>
> **Expected if right.** They fail **differently**, and you need both
> shapes: HTTP gets **`502`** (Envoy answers itself with a
> `direct_response` from the `block_all` route — it can read the Host
> header); HTTPS gets **no status**, curl exit **35** (TLS handshake
> reset — Envoy only sees an SNI it has no cluster for). Then:
>
> ```yaml
> apiVersion: networking.istio.io/v1
> kind: ServiceEntry
> metadata: {name: httpbin-org}
> spec:
>   hosts: [httpbin.org]
>   location: MESH_EXTERNAL
>   resolution: DNS
>   ports: [{number: 443, name: tls, protocol: TLS}, {number: 80, name: http, protocol: HTTP}]
> ```
> → both `200` again, and `istioctl pc cluster "$C" -n bookinfo | grep httpbin.org`
> shows two `STRICT_DNS` clusters. Egress is now an allowlist in git.
>
> **What would have caught this sooner.** The two failure shapes
> themselves. "502 from nowhere" and "TLS reset" in an app log after a
> mesh change are the signature of `REGISTRY_ONLY` missing a
> `ServiceEntry`.

---

## 5.1 — `Sidecar` scoping: proxy config is O(cluster), unless you say otherwise

The `Sidecar` you just applied also did something else.

```bash
istioctl pc cluster "$P" -n bookinfo | tail -n +2 | wc -l     # with the Sidecar
kubectl -n bookinfo delete sidecar default
sleep 10; istioctl pc cluster "$P" -n bookinfo | tail -n +2 | wc -l   # without
```

> **Hypothesis.** productpage's proxy only knows about the four services
> it calls.
>
> **Tool.** The two counts.
>
> **Expected if right.** Without a `Sidecar`, it knows **every Service in
> the cluster**: on this lab **69 clusters** (monitoring, argocd,
> cert-manager, metallb, …). With `egress: ["./*", "istio-system/*"]` it
> drops to **21**, and the page is unaffected. Each proxy holds — and
> istiod pushes on every change to — config for the whole cluster. On a
> platform with thousands of services, that is the dominant cost of the
> mesh: proxy memory, istiod CPU, and push latency.
>
> **What would have caught this sooner.** Proxy memory per pod, over
> time, against the cluster's Service count:
> ```promql
> avg(container_memory_working_set_bytes{container="istio-proxy", namespace="bookinfo"})
> ```
> A sidecar whose memory grows while its own app does not is carrying
> other teams' config.

---

## 5.2 — `discoverySelectors`: what istiod watches at all

`Sidecar` limits what each proxy *receives*. `discoverySelectors` limits
what istiod *knows*. Change it via Helm, never by hand:

```bash
kubectl label ns bookinfo istio-discovery=enabled
helm upgrade istiod istio/istiod --version 1.30.7 -n istio-system \
  -f kubernetes/manifests/istio/istiod-values.yaml \
  --set 'meshConfig.discoverySelectors[0].matchLabels.istio-discovery=enabled' --wait
sleep 15; istioctl pc cluster "$P" -n bookinfo | tail -n +2 | wc -l
```

> **Hypothesis.** The effect is the same as the `Sidecar` from 5.1.
>
> **Tool.** The count, and what is left:
> `istioctl pc cluster "$P" -n bookinfo | awk 'NR>1{print $1}' | sort -u`.
>
> **Expected if right.** Stronger: **68 → 14** on this lab, and what
> remains is Bookinfo plus Envoy's own internal clusters. Namespaces
> without the label do not exist for the mesh at all — not as
> destinations, not as config sources. It applies to **every** proxy at
> once, which makes it a platform setting (OpenShift Service Mesh 3 uses
> it for multi-tenant meshes), while `Sidecar` is a per-team setting.
>
> **What would have caught this sooner.** A meshed workload that cannot
> reach a Service which plainly exists: if the target's namespace lacks
> the discovery label, istiod never told anyone about it.

**Revert** (the rest of the workbook assumes the default):
```bash
helm upgrade istiod istio/istiod --version 1.30.7 -n istio-system \
  -f kubernetes/manifests/istio/istiod-values.yaml --wait
kubectl label ns bookinfo istio-discovery-
```

---

## 5.3 — Canary control-plane upgrade with revisions

The in-place `helm upgrade istiod` you just did is how most people
start, and what platforms avoid: one bad istiod affects every proxy at
once. The alternative is two control planes side by side, moving
namespaces one at a time. The lab is already on the latest patch, so
rehearse with a second revision of the **same** version — the mechanics
are identical.

```bash
helm install istiod-canary istio/istiod --version 1.30.7 -n istio-system \
  -f kubernetes/manifests/istio/istiod-values.yaml --set revision=canary --wait
kubectl -n istio-system get pods -l app=istiod -L istio.io/rev
```

Now move Bookinfo. **Before running each step, predict which istiod
each Bookinfo proxy — and the ingress gateway — will be connected to.**

```bash
# step 1: add the revision label, keep the old one
kubectl label ns bookinfo istio.io/rev=canary
kubectl -n bookinfo rollout restart deploy/details-v1
# step 2: remove the old label
kubectl label ns bookinfo istio-injection-
kubectl -n bookinfo rollout restart deploy/details-v1
```

> **Hypothesis.** `istioctl proxy-status` shows the whole mesh, with the
> `ISTIOD` column telling which revision each proxy uses; and nothing
> moves until you restart a pod.
>
> **Tool.** `istioctl proxy-status`, then `istioctl proxy-status --revision canary`,
> and `kubectl -n bookinfo get pods -l gateway.networking.k8s.io/gateway-name=bookinfo-gateway`.
>
> **Expected if right.** Wrong twice — both observed on this lab.
> 1. `proxy-status` **without** `--revision` lists only the proxies of the
>    **default** revision. details disappears from it rather than showing
>    the canary. Use `--revision canary` for the other side, or check the
>    pod's `sidecar.istio.io/status` annotation (`"revision":"canary"`).
> 2. **The ingress gateway moved without any restart from you.** The
>    moment the namespace got `istio.io/rev=canary`, the canary istiod's
>    gateway controller took over the auto-deployed `bookinfo-gateway-istio`
>    and rolled it — even in step 1, while `istio-injection=enabled` was
>    still there. In a real upgrade, **your ingress moves to the new
>    control plane first, before any workload you chose to move.** Plan
>    for it: label the Gateway itself with an explicit `istio.io/rev`
>    if it must stay put.
>
> **What would have caught this sooner.** Watching gateway pods during
> the label change (`kubectl get pods -w`), not just the workloads you
> restarted. Anything istiod *deploys* follows the revision label, not a
> restart.

**Revision tags** make the move a single switch instead of relabelling
every namespace:

```bash
istioctl tag set prod --revision canary --skip-confirmation
kubectl label ns bookinfo istio.io/rev=prod --overwrite
kubectl -n bookinfo rollout restart deploy/ratings-v1      # injected by canary, via tag "prod"
```

Namespaces point at `prod`; an upgrade becomes "install new revision →
move the tag → restart → remove old revision", and a rollback is moving
the tag back.

**Roll back and clean up** (verified to return the lab to its baseline):
```bash
kubectl label ns bookinfo istio.io/rev- ; kubectl label ns bookinfo istio-injection=enabled --overwrite
istioctl tag remove prod --skip-confirmation
kubectl -n bookinfo rollout restart deploy/details-v1 deploy/ratings-v1
helm uninstall istiod-canary -n istio-system
istioctl version        # 7 proxies on one control plane again
```

---

**Done when**
- Egress for `bookinfo` is `REGISTRY_ONLY` with exactly the
  `ServiceEntry` objects it needs, and you can name the two failure
  shapes of a missing one.
- You have before/after numbers for proxy cluster count with `Sidecar`
  scoping and with `discoverySelectors`, and can say which one you would
  own as a platform team and which you would give to app teams.
- You have moved a namespace to a second revision and back, with no
  failed requests in `mesh-break.sh check`, and you know where the
  gateway went at each step.
- Clean up: `kubectl -n bookinfo delete sidecar,serviceentry --all`, and
  `kubectl delete -n bookinfo -f $S/curl/curl.yaml`.

**Runbook:** `runbooks/05-operating-the-mesh.md`.
