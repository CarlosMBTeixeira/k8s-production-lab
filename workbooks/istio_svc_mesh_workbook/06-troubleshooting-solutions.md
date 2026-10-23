# Session 6 — Hints and solutions

**Spoilers.** Each scenario has a **hint** first, then the answer behind
a heading. Read the hint only after your 20-minute time box, and the
answer only after you have written a diagnosis.

Every signal quoted here was observed on this lab on 2026-10-23
(Istio 1.30.7), when the scenario was applied with `mesh-break.sh`.

---

## Scenario 1

**Hint:** "A third" is not random. Which reviews version is affected?
Then look at that pod's container list.

### Answer

- **Signal:** the affected loads are all served by **reviews-v3**, whose
  pod is `1/1` instead of `2/2`. On the ratings side, its sidecar logs
  `"- - -" 0 NR filter_chain_not_found` for every call from v3.
- **Cause:** reviews-v3 lost its sidecar
  (label `sidecar.istio.io/inject: "false"` on the pod template), and a
  namespace-wide `PeerAuthentication` in `STRICT` mode is in force.
  v3 calls ratings in plaintext; ratings' inbound listener has no
  plaintext filter chain under STRICT, so the connection matches nothing
  and is reset.
- **Fix:** remove the label (or set it to `"true"`) and roll out;
  or, if the workload genuinely cannot be meshed, a port-level
  `PeerAuthentication` exception for ratings — a decision, not a fix.
- **What would have told me first:** `kubectl get pods` READY column —
  `1/1` in a meshed namespace — and Kiali's "Missing sidecar" badge on
  the workload. `NR filter_chain_not_found` on a server is always
  "plaintext arrived at an mTLS-only listener".
- **istioctl analyze:** no. (With the older *annotation* form of the
  same setting, it reports only `IST0135` — the annotation is
  deprecated in favour of the label — which is a hint, not a diagnosis.)
- **Real-world variants:** a Job or CronJob created with injection off;
  a pod from before the namespace was labelled; an operator-managed pod
  with its own `inject: false`.

---

## Scenario 2

**Hint:** read the error in the *caller's* sidecar log, especially the
two letters after the status code.

### Answer

- **Signal:** productpage's sidecar logs
  `"GET /reviews/0 HTTP/1.1" 503 NC cluster_not_found`.
  `istioctl analyze -n bookinfo` reports
  `Error [IST0101] … Referenced host+subset in destinationrule not found: "reviews+v2"`.
- **Cause:** a VirtualService routes reviews to subsets `v2`/`v3`, but no
  DestinationRule defines them. A subset *is* a cluster (session 1.1);
  the route points at a cluster Envoy does not have.
- **Fix:** apply the DestinationRule with the subsets (or remove the
  VirtualService). In a rollout: DestinationRule first, VirtualService
  second.
- **What would have told me first:** `istioctl analyze` — this is the
  one class of mistake it is built for. Run it in CI on every mesh
  change (session 1.5).
- **istioctl analyze:** **yes**.

---

## Scenario 3

**Hint:** compare with scenario 1 — every reviews pod has its sidecar
this time. What is the caller's flag, and does `analyze` see anything?

### Answer

- **Signal:** reviews-v2/v3 sidecars log
  `"GET /ratings/0 HTTP/1.1" 503 UC upstream_reset_before_response_started{connection_termination}`.
  `istioctl analyze`: **✔ No validation issues found.**
- **Cause:** a `PeerAuthentication` puts ratings in `STRICT`, and a
  `DestinationRule` for ratings sets `trafficPolicy.tls.mode: DISABLE` —
  so callers deliberately send plaintext to a workload that only accepts
  mTLS. The DestinationRule overrides auto mTLS.
- **Fix:** delete the DestinationRule's `tls` block (let auto mTLS
  decide) or set it to `ISTIO_MUTUAL`.
- **What would have told me first:** `istioctl x describe pod <ratings-pod>`
  shows the effective PeerAuthentication; `kubectl get dr -n bookinfo -o yaml | grep -A1 tls`
  shows the client side. A DestinationRule with `tls.mode` set is rare
  and almost always the culprit when it disagrees with the server.
- **istioctl analyze:** **no** — both objects are valid on their own.

---

## Scenario 4

**Hint:** the status code is not a 503 this time.

### Answer

- **Signal:** details' sidecar logs
  `"GET /details/0 HTTP/1.1" 403 - rbac_access_denied_matched_policy[none]`;
  productpage's logs `403 … via_upstream`.
- **Cause:** an `AuthorizationPolicy` on details allows only principal
  `cluster.local/ns/bookinfo/sa/bookinfo-productpge` — a typo for
  `bookinfo-productpage`. Being an ALLOW policy, everything not matching
  it is denied, including the real productpage.
- **Fix:** correct the principal.
- **What would have told me first:** the **403** itself. A 403 between
  meshed services means identity was established and refused (session
  3.4); `matched_policy[none]` means no ALLOW rule matched — look for a
  typo in principals, namespaces or paths.
- **istioctl analyze:** no (a principal string can't be checked against
  ServiceAccounts that might exist later).

---

## Scenario 5

**Hint:** compare productpage's listeners with session 0.3.

### Answer

- **Signal:** `istioctl pc listener <productpage> --port 9080` shows a
  **new** listener on reviews' ClusterIP:
  `10.108.x.x 9080 ALL Cluster: outbound|9080||reviews…` — a TCP proxy.
  Access-log lines for reviews become `"- - -"` (no HTTP).
  `kubectl get svc reviews -o jsonpath='{.spec.ports}'` → `"name":"tcp"`.
- **Cause:** the reviews Service port was renamed from `http` to `tcp`.
  Istio selects the protocol from the port name (or `appProtocol`);
  `tcp` forces TCP proxying, so no HTTP metrics, no per-request load
  balancing, no HTTP routing or retries — but the app still works, so
  nobody notices except the dashboards.
- **Fix:** name it `http` (or `http-…`), or set `appProtocol: http`.
- **What would have told me first:** `istio_requests_total` for reviews
  dropping to zero while `istio_tcp_connections_opened_total` rises — a
  service that "went quiet" in HTTP metrics but still serves traffic.
- **istioctl analyze:** no (on this lab it reported nothing; `IST0118`
  only flags names that match no convention at all).

---

## Scenario 6

**Hint:** start from the Gateway, not from Bookinfo.

### Answer

- **Signal:** every load returns **404**. The Gateway's listener reports
  `attachedRoutes=0`:
  `kubectl -n bookinfo get gateway bookinfo-gateway -o jsonpath='{.status.listeners[*].attachedRoutes}'`.
  The HTTPRoute's `status.parents` is **empty** — no controller has
  accepted it.
- **Cause:** the HTTPRoute's `parentRefs[0].name` points at
  `bookinfo-gw`, a Gateway that does not exist. The route is valid YAML
  attached to nothing.
- **Fix:** set `parentRefs[0].name: bookinfo-gateway`.
- **What would have told me first:** `attachedRoutes` on the Gateway.
  For Gateway API, status is the debugging interface: a route whose
  `status.parents` is empty was never picked up; one with
  `Accepted=False` was picked up and rejected (wrong namespace,
  `allowedRoutes`, hostname mismatch).
- **istioctl analyze:** no.

---

## Scenario 7

**Hint:** the data plane is fine. What do the failing `kubectl` command
and the stuck ReplicaSet have in common?

### Answer

- **Signal:** `kubectl apply` of any Istio object fails with
  `failed calling webhook "validation.istio.io" … connect: connection refused`.
  The ratings rollout's new ReplicaSet has `0` pods and a `FailedCreate`
  event: `failed calling webhook "namespace.sidecar-injector.istio.io"`.
  `istioctl proxy-status` → `Error: no running Istio pods in "istio-system"`.
  `kubectl -n istio-system get endpoints istiod` → `<none>`.
- **Cause:** istiod is down (scaled to 0). Both Istio webhooks run
  `failurePolicy: Fail`, so config changes and new injected pods are
  refused. Existing proxies keep their last config and keep serving —
  **the data plane survives the control plane**, which is why the site
  works.
- **Fix:** bring istiod back (`kubectl -n istio-system scale deploy istiod --replicas=1`),
  then retry the rollout (`kubectl -n bookinfo rollout restart deploy/ratings-v1`).
- **What would have told me first:** an alert on istiod availability.
  Without one, the first symptom is a deployment that won't start —
  possibly hours later — because nothing user-facing breaks.
- **istioctl analyze:** n/a.

---

## Scenario 8

**Hint:** reviews-v1 is unaffected; v2 and v3 are. Ask reviews' proxy
which clusters it has.

### Answer

- **Signal:** reviews sidecars log
  `"GET /ratings/0 HTTP/1.1" 502 - direct_response … block_all`.
  `istioctl pc cluster <reviews-v2> --fqdn ratings.bookinfo.svc.cluster.local`
  returns **no rows** — ratings does not exist for this proxy.
- **Cause:** a `Sidecar` resource selecting `app: reviews` limits its
  egress to details and `istio-system`, with
  `outboundTrafficPolicy: REGISTRY_ONLY`. ratings is outside its egress
  hosts, so it is unknown, and REGISTRY_ONLY blocks unknown destinations.
  (Without REGISTRY_ONLY the call would have gone out through
  `PassthroughCluster` and silently lost mTLS instead.)
- **Fix:** add `./ratings.bookinfo.svc.cluster.local` (or `./*`) to the
  `Sidecar`'s egress hosts.
- **What would have told me first:** `block_all` in the log is always
  REGISTRY_ONLY at work (session 5.0). Then `kubectl get sidecar -A` —
  a `Sidecar` is the only object that removes a destination from a
  proxy.
- **istioctl analyze:** no.

---

## Scenario 9

**Hint:** Kiali draws edges from one place (session 0.5). Ask that
place directly.

### Answer

- **Signal:** `sum(rate(istio_requests_total[1m]))` falls to zero within
  a couple of minutes. Prometheus → Status → Targets: the
  `podMonitor/istio-system/envoy-stats-monitor` pool is **gone**
  (dropped within ~30 s on this lab). `kubectl -n istio-system get podmonitor --show-labels`
  → no `release=kube-prometheus-stack`.
- **Cause:** the PodMonitor lost its `release` label, so Prometheus'
  `podMonitorSelector` no longer selects it (ADR-038). Nothing errors:
  the object is valid, it is just ignored.
- **Fix:** `kubectl -n istio-system label podmonitor envoy-stats-monitor release=kube-prometheus-stack`.
- **What would have told me first:** an `absent()` alert —
  `absent(istio_requests_total{reporter="destination"})` for a namespace
  that should always have traffic. Telemetry that disappears is a
  failure that never produces an error.
- **istioctl analyze:** no — outside its scope.

---

## Scenario 10

**Hint:** the failing container is not `details` and not `istio-proxy`.

### Answer

- **Signal:** the new details pod is `Init:Error` / `Init:CrashLoopBackOff`.
  `kubectl logs <pod> -c istio-validation` says traffic redirection was
  not set up: *"When using Istio CNI, this can occur if a pod is
  scheduled before the node is ready … this pod will need to be manually
  removed so that it is scheduled on a node with istio-cni running"*.
  `kubectl -n istio-system get pods -l k8s-app=istio-cni-node` → **none**.
- **Cause:** the istio-cni DaemonSet has no pods on any node (a
  `nodeSelector` that matches nothing). Without the node agent, new pods
  get no iptables redirection; `istio-validation` checks for it and
  fails. Existing pods were set up before and keep working.
- **Fix:** restore the DaemonSet (remove the bad `nodeSelector`, or
  `helm upgrade` istio-cni with the repo's values), wait for its pods,
  then delete the failed pod or roll the deployment.
- **What would have told me first:** `kubectl -n istio-system get ds istio-cni-node`
  — `DESIRED` should equal the node count. Its real-world twin is the
  inotify exhaustion from the bring-up
  (`workbooks/observability_workbook/runbooks/mesh-istio-kiali-install.md`,
  ADR-040): there the agent crash-looped on one node only.
- **istioctl analyze:** no.

---

## The pattern across all ten

| Scenario | Caught by `istioctl analyze` | Fastest discriminating signal |
|---|---|---|
| 1 | no | `1/1` pod + `NR filter_chain_not_found` on the server |
| 2 | **yes** | `503 NC cluster_not_found` on the caller |
| 3 | no | `503 UC` on the caller, both sides have sidecars |
| 4 | no | `403 rbac_access_denied_matched_policy[none]` |
| 5 | no | extra TCP listener on the Service IP; `"- - -"` log lines |
| 6 | no | `attachedRoutes=0`, empty `status.parents` |
| 7 | n/a | webhook `connection refused`; istiod endpoints `<none>` |
| 8 | no | `502 direct_response … block_all`; cluster missing in `pc cluster` |
| 9 | no | scrape pool gone in Prometheus targets |
| 10 | no | `istio-validation` init container failing; CNI DaemonSet `DESIRED 0` |

One in ten. `analyze` is a linter for references; the access log and
`proxy-config` are how you debug behaviour.
