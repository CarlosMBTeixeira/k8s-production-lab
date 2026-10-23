# Session 1 — Traffic routing

**Objective:** move traffic between versions deliberately — by weight,
by header, through the ingress — with both APIs the platform may use,
and deliver a canary the way it is done in production: as git commits
that ArgoCD applies.

**Prerequisites**
- Session 0. Lab with choice **6** for unit 1.5 (ArgoCD); **5** is enough for the rest.
- `B=https://raw.githubusercontent.com/istio/istio/1.30.7/samples/bookinfo`
- A quick way to see what users see, 10 page loads at a time:
  `./scripts/mesh-break.sh check` (it only reads; it breaks nothing).
  `ratings=none` is reviews **v1**, `ratings=stars` is **v2/v3**.

**Read first:**
- istio.io → *Tasks* → *Traffic Management* → "Request Routing" and
  "Traffic Shifting". Read both tabs (Istio APIs / Gateway API).
- istio.io → *Reference* → *Configuration* → "Virtual Service" and
  "Destination Rule" — the `http`/`route`/`subsets` fields only.
- Gateway API → "GAMMA" (mesh support) overview page.

Course equivalents: *Traffic Management* — Gateways, Virtual Services,
Destination Rules, A/B Testing.

---

## 1.0 — Two APIs, and which one is in front of you

The lab already uses **both**, in different places:

```bash
kubectl get gateway,httproute -A                       # Gateway API
kubectl get gateways.networking.istio.io,virtualservice,destinationrule -A   # Istio API
```

> **Hypothesis.** Bookinfo's ingress is an Istio `Gateway` +
> `VirtualService`, as in most tutorials.
>
> **Tool.** The two commands above.
>
> **Expected if right.** Wrong. Ingress is a **Gateway API** `Gateway`
> (class `istio`) + `HTTPRoute`; istiod deployed `bookinfo-gateway-istio`
> for it. No Istio-API objects exist yet. Both APIs are supported by
> OpenShift Service Mesh 3, and a real platform usually has both —
> knowing which one owns a route is the first question in any routing
> incident. Note `kubectl get gateway` is ambiguous between the two;
> use the full resource name for the Istio one.
>
> **What would have caught this sooner.** `kubectl api-resources | grep -i gateway`
> — two different `Gateway` kinds in two API groups.

---

## 1.1 — Subsets: why routing by version needs a DestinationRule

```bash
kubectl apply -n bookinfo -f $B/networking/destination-rule-all.yaml
kubectl apply -n bookinfo -f $B/networking/virtual-service-all-v1.yaml
./scripts/mesh-break.sh check
```

> **Hypothesis.** All traffic goes to v1 within seconds.
>
> **Tool.** `mesh-break.sh check`, then
> `istioctl pc route "$P" -n bookinfo --name 9080` and
> `istioctl pc cluster "$P" -n bookinfo --fqdn reviews.bookinfo.svc.cluster.local`.
>
> **Expected if right.** `10 … ratings=none`. The route table's
> `VIRTUAL SERVICE` column now says `reviews.bookinfo`, and there are
> four reviews clusters instead of one: the plain one plus
> `outbound|9080|v1|…`, `|v2|`, `|v3|`. **The subset is a cluster.** The
> DestinationRule creates it; the VirtualService only points at it.
>
> **What would have caught this sooner.** Applying the VirtualService
> *without* the DestinationRule first — exactly session 06 scenario 2.
> Order matters in a rollout: DestinationRule before VirtualService, and
> the reverse on removal.

---

## 1.2 — Weighted shift (canary), and how exact it is

```bash
kubectl apply -n bookinfo -f $B/networking/virtual-service-reviews-90-10.yaml
for i in 1 2; do ./scripts/mesh-break.sh check; done
```

> **Hypothesis.** 20 page loads show 18 v1 and 2 v2.
>
> **Tool.** The loop above, then the Envoy view:
> ```bash
> istioctl pc route "$P" -n bookinfo --name 9080 -o json \
>   | jq '.[].virtualHosts[] | select(.name|startswith("reviews")) | .routes[].route.weightedClusters'
> ```
>
> **Expected if right.** Roughly — on this lab one run gave **19/1**.
> Weights are per-request probabilities, so small samples are noisy. The
> config is exact (`v1: 90`, `v2: 10` in `weightedClusters`); the
> *observation* needs volume. Use Prometheus instead of page loads:
> ```promql
> sum by (destination_version) (rate(istio_requests_total{destination_service_name="reviews", reporter="destination"}[2m]))
> ```
>
> **What would have caught this sooner.** Asking how many requests a
> split needs before you trust it. With ~1 req/s from the generator, a
> 2-minute window holds ~120 requests: enough for 90/10, not for 99/1.

Then `virtual-service-reviews-50-v3.yaml` and `virtual-service-reviews-v3.yaml`
— the full progression a canary takes.

---

## 1.3 — Header-based routing (A/B, test users)

```bash
kubectl apply -n bookinfo -f $B/networking/virtual-service-reviews-jason-v2-v3.yaml
```

Log in on the product page as `jason` (any password) through
`./scripts/tunnels/bookinfo-tunnel.sh`.

> **Hypothesis.** The VirtualService matches on a cookie or the login.
>
> **Tool.** `kubectl -n bookinfo get vs reviews -o yaml | yq '.spec.http[0].match'`
>
> **Expected if right.** It matches a header, `end-user: jason`, which
> **productpage adds** to its outbound call after login. The mesh routes
> on what the *caller* puts in the request — so header routing only works
> for services that propagate the header. That is a contract with the
> application team, not a mesh feature you can switch on.
>
> **What would have caught this sooner.** The productpage access log for
> a logged-in request — the header is visible on the outbound call, and
> absent on calls from services that don't forward it.

---

## 1.4 — The same canary with the Gateway API (GAMMA)

Remove the Istio-API routing, then do the 90/10 with an `HTTPRoute`
whose parent is a **Service**:

```bash
kubectl delete -n bookinfo -f $B/networking/virtual-service-all-v1.yaml
kubectl delete -n bookinfo -f $B/networking/destination-rule-all.yaml
kubectl apply  -n bookinfo -f $B/platform/kube/bookinfo-versions.yaml   # Services reviews-v1, -v2, -v3
kubectl apply  -n bookinfo -f $B/gateway-api/route-reviews-90-10.yaml
```

> **Hypothesis.** GAMMA also uses subsets.
>
> **Tool.** `kubectl -n bookinfo get httproute reviews -o yaml` and
> `istioctl pc cluster "$P" -n bookinfo | grep reviews`.
>
> **Expected if right.** No subsets: `backendRefs` point at **per-version
> Services** (`reviews-v1`, `reviews-v2`). In Envoy that becomes clusters
> for those Services, not `|v1|` subsets of one. Same behaviour, different
> objects — which matters when you are reading someone else's config at
> 03:00.
>
> **What would have caught this sooner.** `parentRefs.kind: Service` in
> the route. A route attached to a Service is mesh (east-west) routing;
> attached to a Gateway, it is ingress.

Clean up: `kubectl delete -n bookinfo httproute reviews` and
`kubectl delete -n bookinfo -f $B/platform/kube/bookinfo-versions.yaml`.

---

## 1.5 — The canary as GitOps (requires ArgoCD)

On the platform, nobody `kubectl apply`s a VirtualService. Do the
progression 90/10 → 50/50 → 100 as three commits.

1. Apply the root App-of-Apps once (the only manual apply, per
   `gitops/README.md`):
   `kubectl apply -f kubernetes/manifests/argocd/apps/root-app.yaml`
2. Create `gitops/mesh/bookinfo-routing/` with
   `destination-rule-reviews.yaml` (subsets v1–v3) and
   `virtual-service-reviews.yaml` (weights 90/10).
3. Add `gitops/apps/root/bookinfo-routing.yaml`: an `Application` with
   `path: gitops/mesh/bookinfo-routing`, destination namespace
   `bookinfo`, `targetRevision: main`, automated sync with `selfHeal`.
4. Merge to `main` (ADR-037: nothing in `gitops/` is live until then).
   Change the weights in two more commits.

> **Hypothesis.** ArgoCD shows the Application *Healthy* as soon as it is
> *Synced*, because Istio objects have no status worth checking.
>
> **Tool.** ArgoCD UI → the Application → each resource's health; and
> `kubectl -n bookinfo get vs reviews -o jsonpath='{.status}'`.
>
> **Expected if right.** ArgoCD has no built-in health check for Istio
> kinds, so they show without a health status (or *Healthy* by default),
> regardless of whether they work. A VirtualService pointing at a missing
> subset syncs green. **Synced ≠ working** for mesh config. The signal
> that something is wrong lives in `istioctl analyze` — and, if istiod
> runs its analyzers in-cluster (`global.istiod.enableAnalysis: true`,
> off in this lab), in each object's `status.validationMessages` — not
> in ArgoCD.
>
> **What would have caught this sooner.** Running `istioctl analyze` on
> the rendered manifests *before* the commit (`istioctl analyze gitops/mesh/bookinfo-routing/` — it merges the files
> with the live cluster state; add `--use-kube=false` to check the files
> alone, as a CI job would)
> — the same check belongs in the pipeline that reviews the merge
> request.

Then try `selfHeal`: `kubectl -n bookinfo edit vs reviews` and set
100/0. ArgoCD reverts it within its reconciliation interval. That is the
answer to "someone hot-fixed routing in prod" on a GitOps platform.

---

**Done when**
- A PromQL query over 2 minutes shows the reviews split within ±5
  percentage points of each weight you committed (90/10 and 50/50).
- You can say, for any routing object on the cluster, which API it
  belongs to and which Envoy objects it produced.
- Clean slate restored: no VirtualService, DestinationRule or extra
  HTTPRoute in `bookinfo` (or the GitOps Application removed from
  `gitops/apps/root/`).

**Runbook:** `runbooks/01-traffic-routing.md`.
