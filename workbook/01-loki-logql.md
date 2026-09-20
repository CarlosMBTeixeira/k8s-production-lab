# Session 1 — Loki as a datasource, and LogQL

**Objective:** find the cause of a deliberately broken application using
only its logs, and be able to explain why every LogQL query starts with a
label selector when no PromQL query does.

**Prerequisites**
- Lab up, `main.sh` choice **3** or **4** (observability installed).
- `export KUBECONFIG=~/k8slab/kubernetes/admin.conf`
- Grafana reachable: `./scripts/tunnels/grafana-tunnel.sh` → `https://localhost:8445/`

**Read first (and only this):** Grafana Labs — *LogQL: Log query
language*, the "Log queries" and "Metric queries" pages. Twenty minutes.
Skip anything about multi-tenancy; `auth_enabled: false` here (ADR-032).

---

## 1.0 — The datasource is already done. Read it instead of adding it.

The instinct is to start by adding the datasource. Don't — it was added
in ADR-032 and it is four lines, in `kubernetes/manifests/observability/values.yaml`:

```yaml
grafana:
  additionalDataSources:
    - name: Loki
      type: loki
      url: http://loki.monitoring.svc.cluster.local:3100
      access: proxy
      isDefault: false
```

That is the whole configuration. **The comparison with Prometheus is the
exercise, not the typing.**

> **Hypothesis.** A Loki datasource needs materially less configuration
> than a Prometheus one, because the differences that matter between them
> are not in the connection.
>
> **Tool.** Grafana → Connections → Data sources → open Loki, then open
> Prometheus. Compare the forms field by field.
>
> **Expected if right.** Both are a URL plus an access mode. The Loki
> form's distinctive sections are *derived fields* (turn a trace ID in a
> log line into a link) and a maximum-lines limit. Nothing about the
> query language is visible in either — the difference is entirely on the
> query side.
>
> **What would have caught this sooner.** The chart values. Four lines of
> YAML was the signal that the connection is not where the difficulty is.

Now the part that matters. Prometheus ingests **metrics already carrying
labels**, from targets it discovers. Loki ingests **opaque log lines**,
and labels are attached by the *collector* at scrape time. So in Loki,
the label set is not a property of the data — it is a property of your
Alloy config. Which means you can read it:

```bash
kubectl -n monitoring get cm alloy -o yaml | sed -n '/discovery.relabel/,/^ *}/p'
```

That `discovery.relabel "pods"` block produces exactly three labels:
`namespace`, `pod`, `container`. **Nothing else exists.** Most LogQL
examples on the internet start `{job="..."}` or `{app="..."}`, and every
one of them will return nothing here. Prove it before you trust it.

---

## 1.1 — What labels actually exist

> **Hypothesis.** `{job="..."}` returns nothing, and Grafana's label
> browser will show exactly three label keys.
>
> **Tool.** Grafana → Explore → Loki → the **Label browser**, then run
> `{job="alloy"}`.
>
> **Expected if right.** Three keys: `namespace`, `pod`, `container`.
> `{job=...}` errors or returns "no data". A query with no selector at
> all — a bare `|= "error"` — is rejected outright, because Loki needs a
> stream selector to know which index shards to open. This is the
> structural difference from PromQL: `up` is a valid PromQL query;
> there is no valid LogQL equivalent.
>
> **What would have caught this sooner.** Reading `alloy-values.yaml`
> before writing a query. The collector config *is* the schema.

**Done when** you can state, without looking, why adding a fourth label
requires editing `alloy-values.yaml` and a `helm upgrade`, not a Loki
setting — and why adding a high-cardinality one (say, `pod_ip`) would be
a bad idea.

---

## 1.2 — Line filters, and the order that costs you

Work in Explore, `monitoring` namespace, last 1 hour.

```logql
{namespace="monitoring"}
{namespace="monitoring"} |= "error"
{namespace="monitoring"} |= "error" != "context deadline exceeded"
{namespace="monitoring"} |~ "(?i)err(or)?"
{namespace="monitoring", container="grafana"} |= "error"
```

> **Hypothesis.** Narrowing by label is cheaper than narrowing by line
> filter, and the last query is materially faster than the second even
> though both return roughly the same rows.
>
> **Tool.** Explore's query inspector — the **Stats** tab, after each run.
> Watch *Total bytes processed* and *Lines examined*.
>
> **Expected if right.** Adding `container="grafana"` cuts bytes
> processed by roughly the fraction of `monitoring` logs that aren't
> Grafana's. Adding `|= "error"` barely moves it — the line filter runs
> *after* the chunks are already fetched and decompressed. Labels select
> chunks; filters scan them.
>
> **What would have caught this sooner.** Nothing in the output. This is
> only visible in Stats, which is why knowing the panel exists is the
> lesson. On a lab this small, a bad query is merely slow; against a
> platform's retention it is an incident.

---

## 1.3 — Parsers: turning a line into fields

Grafana logs are logfmt. Prometheus's are too.

```logql
{namespace="monitoring", container="grafana"} | logfmt
{namespace="monitoring", container="grafana"} | logfmt | level="error"
{namespace="monitoring", container="grafana"} | logfmt | duration > 100ms
```

> **Hypothesis.** `| logfmt | level="error"` and `|= "level=error"`
> return the same rows, and one of them is honest about why.
>
> **Tool.** Run both. Then break the assumption: find a line where the
> string `level=error` appears inside a *message* rather than as a field.
>
> **Expected if right.** The line filter matches it; the parsed
> comparison does not. The parser knows structure, the filter knows
> bytes. The corollary is the trap: `| json` on a line that isn't JSON
> doesn't error loudly, it drops the line from the parsed set and quietly
> shrinks your result.
>
> **What would have caught this sooner.** Running the unparsed query
> first and comparing row counts. A parser that silently halves your
> results is the single most common way a LogQL query lies to you.

---

## 1.4 — Metric queries: logs become a time series

This is the bridge from what you already know. These return a graph, not
lines, and everything you know about PromQL aggregation applies.

```logql
rate({namespace="monitoring"} |= "error" [5m])
count_over_time({namespace="monitoring"} |= "error" [5m])
sum by (container) (rate({namespace="monitoring"} |= "error" [5m]))
topk(3, sum by (pod) (count_over_time({namespace="monitoring"}[5m])))
```

> **Hypothesis.** `rate` and `count_over_time` over the same range differ
> only by a factor of the range in seconds, so `count_over_time(...[5m])`
> ≈ `rate(...[5m]) * 300`.
>
> **Tool.** Put both on one graph in Explore and read the axis.
>
> **Expected if right.** The shapes are identical, the magnitudes differ
> by 300. `rate` is per-second, `count_over_time` is per-range — exactly
> as in PromQL, which is the point: **the aggregation layer is the part
> you already know.** The genuinely new surface is only the selector and
> the pipeline before it.
>
> **What would have caught this sooner.** Recognising `[5m]` as a range
> vector. If it has range-vector syntax, PromQL intuition transfers.

---

## 1.5 — The main exercise: break something, find it by logs alone

Deploy an app that will fail in a way metrics describe badly.

```bash
kubectl create namespace logdemo
kubectl -n logdemo create deployment badapp --image=busybox:1.36 \
  -- /bin/sh -c 'i=0; while true; do
       i=$((i+1));
       if [ $((i % 7)) -eq 0 ]; then
         echo "level=error msg=\"failed to reach upstream\" attempt=$i backend=payments-api";
       else
         echo "level=info msg=\"request served\" attempt=$i";
       fi;
       sleep 2;
     done'
```

**Now stop.** Before querying, write down: what fraction of lines should
be errors, and what error rate per second do you expect?

*(Every 7th line, one line per 2s → ~0.071 errors/sec.)*

> **Hypothesis.** `rate({namespace="logdemo"} |= "error" [5m])` converges
> on ~0.07/s, and the same value is reachable through the parser with
> `| logfmt | level="error"`.
>
> **Tool.** Explore, both queries on one graph, range 15m.
>
> **Expected if right.** Both converge on the same number. If the parsed
> one reads lower, the parser is dropping lines — go back to 1.3.
>
> **What would have caught this sooner.** Predicting the number first.
> A query you can't predict the output of is a query you can't use to
> detect anything, because you have no basis for an alert threshold.

Then the real question — **which backend is failing?** The error text
names it, but `backend` is not a label:

```logql
sum by (backend) (
  count_over_time({namespace="logdemo"} | logfmt | level="error" [5m])
)
```

> **Hypothesis.** You can aggregate by `backend` even though Alloy never
> created such a label.
>
> **Tool.** The query above.
>
> **Expected if right.** It works. `| logfmt` promotes every field in the
> line to a queryable label *at query time*, for the duration of that
> query only. This is the thing Prometheus cannot do and the reason logs
> are worth keeping: **unbounded cardinality at query time, zero
> cardinality cost at ingest.** Putting `backend` in `alloy-values.yaml`
> as a real label would make it fast and make your index pay for it
> forever.
>
> **What would have caught this sooner.** The label-browser result in
> 1.1. Knowing only three labels exist is what makes the query-time
> parser the obvious move rather than a surprise.

**Done when** you can answer, from logs alone: *how many distinct
backends are failing, which one is worst, and when did it start* — and
name which of those three a Prometheus counter could have answered.

---

## 1.6 — The edge that will bite on the real platform

```bash
kubectl -n monitoring rollout restart statefulset loki   # or deployment, check first
```

> **Hypothesis.** Every log line ingested so far is gone.
>
> **Tool.** Re-run 1.5's query over the last hour after the pod restarts.
>
> **Expected if right.** Empty. `loki-values.yaml` sets
> `singleBinary.persistence.enabled: false` — filesystem storage on an
> ephemeral volume. This is fine for a lab and a catastrophe in
> production, and it is precisely the difference you will meet in session
> 6: OpenShift's LokiStack *requires* object storage and will not let you
> make this mistake.
>
> **What would have caught this sooner.** `persistence.enabled: false`
> in the values file. Four words, read once, before trusting a retention
> window.

## Cleanup

```bash
kubectl delete namespace logdemo
```

---

## Done-criteria for the whole session

- [ ] Explain why `{job="x"}` returns nothing here, citing the file that decides it.
- [ ] Predict a `rate()` result before running it, within ~10%.
- [ ] Aggregate by a field that is not a label, and explain the ingest/query cardinality trade.
- [ ] Name the two queries in 1.2 that differ ~10× in bytes processed, and why.
- [ ] `runbooks/01-loki-logql.md` written.

## Runbook seeds

Fill these in from what actually happened, and add the ones that bit you.

| Symptom | Tool | Cause | Fix | What would have told me this first |
|---|---|---|---|---|
| Query returns "no data", no error | Label browser | Selector uses a label Alloy never creates | Use `namespace`/`pod`/`container` | `alloy-values.yaml` relabel rules |
| Parsed query returns fewer rows than unparsed | Row counts, side by side | Parser silently drops non-conforming lines | Match the parser to the format, or filter first | Comparing counts before trusting the parse |
| Query is slow, results are small | Explore → Stats | Filtering by line instead of by label | Narrow the stream selector | Bytes processed, not row count |
| All history gone after a restart | `loki-values.yaml` | `persistence.enabled: false` | Expected in this lab; object storage in real ones | The values file, before relying on retention |
