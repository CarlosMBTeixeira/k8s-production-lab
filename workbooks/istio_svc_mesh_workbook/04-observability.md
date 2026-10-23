# Session 4 — Observability for daily operations

**Objective:** answer "is service X healthy, and since when?" from mesh
telemetry alone; control how much telemetry the mesh produces; and own
one alert on mesh metrics that fires for the right reason.

**Prerequisites**
- Sessions 0–2 (the alert in 4.4 reuses fault injection).
- Lab with choice **5** or **6**. Grafana `:8445`, Kiali `:8446`.
- `B=https://raw.githubusercontent.com/istio/istio/1.30.7/samples/bookinfo`

**Read first:**
- istio.io → *Reference* → *Config* → *Metrics* ("Istio Standard
  Metrics": the metric names and every label).
- istio.io → *Tasks* → *Observability* → "Telemetry API" and
  "Envoy Access Logs" (the `filter` field).
- Kiali docs → *Features* → "Validations" and "Health".
- Prometheus Operator → `PrometheusRule` CRD (you already know it — only
  re-read `ruleSelector`).

Course equivalents: *Observability* — Prometheus and Grafana, Kiali in
detail; Jaeger as the optional 4.5. Links to `observability_workbook`
sessions 1 (LogQL), 2 (dashboards via ArgoCD) and 4 (`PrometheusRule`).

---

## 4.0 — RED from one metric

Every request through a sidecar increments `istio_requests_total` and
`istio_request_duration_milliseconds` — **twice**, once per side
(`reporter="source"` and `reporter="destination"`).

```promql
# Rate
sum by (destination_service_name) (rate(istio_requests_total{reporter="destination", destination_workload_namespace="bookinfo"}[5m]))
# Errors (ratio)
sum by (destination_service_name) (rate(istio_requests_total{reporter="destination", destination_workload_namespace="bookinfo", response_code=~"5.."}[5m]))
  / sum by (destination_service_name) (rate(istio_requests_total{reporter="destination", destination_workload_namespace="bookinfo"}[5m]))
# Duration (p99)
histogram_quantile(0.99, sum by (destination_service_name, le) (rate(istio_request_duration_milliseconds_bucket{reporter="destination", destination_workload_namespace="bookinfo"}[5m])))
```

> **Hypothesis.** Summing without filtering on `reporter` gives the true
> request rate.
>
> **Tool.** `sum(rate(istio_requests_total{destination_service_name="details"}[5m]))`
> with and without `reporter="destination"`.
>
> **Expected if right.** Without the filter the rate is **double**:
> each meshed call is counted by both proxies. Always pin `reporter`.
> Which one is a choice with consequences — 4.4 is about exactly that.
>
> **What would have caught this sooner.** `count by (reporter) (istio_requests_total)`
> — two values for every edge.

---

## 4.1 — The Istio dashboards, delivered like any other dashboard

Grafana's dashboard sidecar here loads every ConfigMap labelled
`grafana_dashboard: "1"`, in any namespace. Istio publishes its
dashboards on grafana.com (Mesh 7639, Service 7636, Workload 7630,
Control Plane 7645, Performance 11829).

```bash
curl -sL https://grafana.com/api/dashboards/7636/revisions/latest/download -o istio-service.json
kubectl -n monitoring create configmap istio-service-dashboard --from-file=istio-service.json \
  --dry-run=client -o yaml | kubectl label --local -f - grafana_dashboard=1 -o yaml | kubectl apply -f -
```

> **Hypothesis.** The dashboard loads and every panel works, exactly as
> it would through Grafana's *Import* button.
>
> **Tool.** Grafana → Dashboards → *Istio Service Dashboard*; then
> `jq '.__inputs, ([.. | strings | select(contains("${DS_PROMETHEUS}"))] | length)' istio-service.json`.
>
> **Expected if right.** Not quite. The JSON is written for the *Import*
> UI: it declares `__inputs: [DS_PROMETHEUS]` and still contains one
> literal `${DS_PROMETHEUS}` (checked 2026-10-23). The UI substitutes it;
> **sidecar provisioning does not**. Find what that one reference breaks
> on screen, then fix the JSON (replace it with the datasource UID or
> `${datasource}`), and — the real deliverable — commit the fixed JSON
> under `gitops/observability/dashboards/` so ArgoCD owns it
> (observability workbook, session 2).
>
> **What would have caught this sooner.** `__inputs` in any downloaded
> dashboard. It means "this file expects an interactive import".

---

## 4.2 — Telemetry API: decide how much the mesh tells you

The access logs from session 0 cost real volume. Measure, then change it:

```logql
sum(count_over_time({namespace="bookinfo", container="istio-proxy"} |= "HTTP/1.1" [1m]))
```

```bash
kubectl apply -n bookinfo -f - <<'EOF'
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata: {name: errors-only-access-log}
spec:
  accessLogging:
  - providers: [{name: envoy}]
    filter: {expression: "response.code >= 400"}
EOF
```

> **Hypothesis.** The filter trims logs a little; most lines are
> interesting.
>
> **Tool.** The LogQL count, before and 90 s after.
>
> **Expected if right.** It removes nearly all of them: on this lab
> **399 → 1 lines/min**. A healthy mesh's access log is almost entirely
> 200s. On a platform, an errors-only default per namespace, with full
> logging switched on per workload during an incident (a second
> `Telemetry` with a `selector`), is a common cost decision.
>
> **What would have caught this sooner.** Grouping the existing volume by
> status before deciding anything:
> `sum by (code) (count_over_time({namespace="bookinfo", container="istio-proxy"} | regexp `" (?P<code>\d{3}) ` [5m]))`.

Telemetry objects resolve **mesh (`istio-system`) → namespace →
workload `selector`**, most specific wins. Delete it when done —
sessions 2 and 6 need full logs.

---

## 4.3 — Kiali beyond the graph

Work through these in Kiali, predicting before each click:

| Where | Predict first | What it is actually reading |
|---|---|---|
| Istio Config → any VirtualService | which validation it shows | Kiali's own validators (KIA codes) — overlapping with, but not the same as, `istioctl analyze` |
| Workloads → reviews-v2 → *Envoy* tab | does it match `istioctl pc` | the same config dump, from the proxy's admin API |
| Workloads → reviews-v2 → *Logs* | which containers | app + `istio-proxy`, interleaved by time |
| Services → reviews → *Health* | why "degraded" | error-rate thresholds over the graph's time window |
| Graph → edge → *Traffic* | response-flag breakdown | `istio_requests_total` by `response_flags` |

> **Hypothesis.** With the `kiali-viewer` token you can still use the
> traffic-shifting wizards.
>
> **Tool.** Services → reviews → *Actions*.
>
> **Expected if right.** The wizards are visible but fail on apply (or
> are hidden): the token is bound to a read-only ClusterRole (ADR-038).
> That is deliberate — on a GitOps platform, mesh config changes go
> through git (session 1.5), and Kiali is for *seeing*.
>
> **What would have caught this sooner.** `kubectl auth can-i create virtualservices -n bookinfo --as=system:serviceaccount:istio-system:kiali-login`.

---

## 4.4 — An alert on mesh metrics that fires for the right reason

Write a `PrometheusRule` in `monitoring`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: mesh-5xx
  namespace: monitoring
  labels: {release: kube-prometheus-stack}     # ruleSelector, same trap as the PodMonitor (ADR-038)
spec:
  groups:
  - name: mesh
    rules:
    - alert: MeshServiceHigh5xx
      expr: |
        sum by (destination_service_name) (rate(istio_requests_total{reporter="destination", response_code=~"5.."}[2m]))
          / sum by (destination_service_name) (rate(istio_requests_total{reporter="destination"}[2m])) > 0.1
      for: 2m
      labels: {severity: warning}
```

Then make ratings fail with the fault from session 2 (50% abort, 503).

> **Hypothesis.** The alert fires within ~4 minutes.
>
> **Tool.** Prometheus → Alerts, and:
> ```promql
> sum by (reporter, response_flags) (rate(istio_requests_total{destination_service_name="ratings", response_code=~"5.."}[1m]))
> ```
>
> **Expected if right.** **It never fires.** The injected 503s exist
> only with `reporter="source"` and `response_flags="FI"` — on this lab,
> ~0.27 req/s of them, and **zero** on the destination side, because the
> request never reached ratings. An alert on the destination's view is
> blind to everything that fails *before* the callee: faults, circuit
> breaking (`UO`), no healthy upstream (`UH`), connection failures. Those
> are exactly the mesh-level failures. Rewrite the rule on
> `reporter="source"` and watch it fire.
>
> **What would have caught this sooner.** Testing the alert with a
> failure, which is the only test an alert has. Choosing `reporter` is
> choosing which failures you can see: destination = what the service
> did; source = what its callers experienced.

**Why `for:` is not optional here.** Every Bookinfo install produces a
burst of `UH` (no healthy upstream) while pods start: on this lab's
first install, 750 lines from productpage and 59 from the gateway in the
first six minutes, before anything was wrong. An alert without `for:`
pages on every rollout.

---

## 4.5 — Optional: distributed tracing

*Optional because of CPU* (README): Tempo and Envoy's span export add
load to a worker already at 65% CPU requests. **Not yet run on this lab
— expect to adjust values on the way, and record what you change.**

Shape of the work (Istio's OpenTelemetry integration sends OTLP straight
from the sidecars; no separate collector is needed for a lab):

1. Tempo, monolithic, from **`grafana-community/tempo` 3.2.1** (Tempo
   3.1.1 — the chart in the `grafana` repo is deprecated). Read
   `helm show values grafana-community/tempo --version 3.2.1` for the
   OTLP gRPC receiver and set small resources.
2. Register the provider in istiod (Helm values, not a hand edit):
   ```yaml
   meshConfig:
     extensionProviders:
     - name: otel-tracing
       opentelemetry: {service: tempo.monitoring.svc.cluster.local, port: 4317}
   ```
3. Turn it on with a `Telemetry` resource: `tracing: [{providers:
   [{name: otel-tracing}], randomSamplingPercentage: 10}]`.
4. Add Tempo as a Grafana datasource and, optionally, point Kiali's
   `external_services.tracing` at it.

> **Hypothesis.** The sidecars produce complete traces on their own.
>
> **Tool.** A trace for one product page load in Grafana → Explore → Tempo.
>
> **Expected if right.** Only because Bookinfo **propagates the trace
> headers** from each incoming request to its outgoing calls. Envoy
> starts and reports spans; it cannot connect an inbound request to the
> app's outbound call. An application that drops the headers yields one
> disconnected span per hop. Same contract with the app team as header
> routing in session 1.3.
>
> **What would have caught this sooner.** Istio's FAQ on tracing: "Do I
> need to change my application?" — yes, for propagation.

On OpenShift Service Mesh 3, the supported stack is the Tempo Operator
plus the Red Hat build of OpenTelemetry; session 7 notes the difference.

---

**Done when**
- A Grafana panel (yours, in git) shows rate, error ratio and p99 per
  Bookinfo service, with `reporter` pinned and the choice justified.
- `MeshServiceHigh5xx` fires on an injected fault and resolves after it
  is removed, and you can explain why the first version could not.
- The access-log volume change from 4.2 is written down with numbers.
- Clean up: `kubectl -n bookinfo delete telemetry --all`, the fault
  VirtualService, and keep (or commit) the alert.

**Runbook:** `runbooks/04-observability.md`.
