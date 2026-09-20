# Session 4 — Recording and alerting rules as a CRD

**Objective:** articulate precisely what changes when rules become a
Kubernetes object managed by an operator, rather than a file shipped by a
pipeline — and find the validation boundary that the CRD gives you for
free.

You already write PromQL and already ship alerts as code. This session is
about the *delivery mechanism*, not the queries.

**Prerequisites:** sessions 1–2. Observability up.

**Read first:** Prometheus Operator API reference → `PrometheusRule`.

---

## 4.1 — Where the rules physically end up

The operator's job is to turn `PrometheusRule` objects into rule files on
Prometheus's disk and trigger a reload. Follow the whole path — this is
the part that makes the abstraction stop being magic.

```bash
kubectl -n monitoring get prometheusrule
kubectl -n monitoring get prometheus -o jsonpath='{.items[0].spec.ruleSelector}{"\n"}'
kubectl -n monitoring get cm | grep rulefiles
kubectl -n monitoring get cm prometheus-kube-prometheus-stack-prometheus-rulefiles-0 \
  -o jsonpath='{.data}' | head -c 800
```

> **Hypothesis.** Every selected `PrometheusRule` is concatenated into
> one or more generated ConfigMaps, mounted into the Prometheus pod, and
> the operator triggers a reload without restarting it.
>
> **Tool.** The commands above, then:
> ```bash
> kubectl -n monitoring get pod -l app.kubernetes.io/name=prometheus \
>   -o jsonpath='{.items[0].spec.containers[*].name}{"\n"}'
> ```
>
> **Expected if right.** A generated `…rulefiles-0` ConfigMap containing
> your rules as plain YAML, and a `config-reloader` sidecar next to
> Prometheus. Same pattern as Grafana's dashboard sidecar in session 2:
> **a controller watching Kubernetes objects and writing files into a
> container that only understands files.** Once you see the shape, every
> operator in the ecosystem looks the same.
>
> **What would have caught this sooner.** `kubectl get cm | grep
> rulefiles` — the generated object is right there, and its content is
> the ground truth about what Prometheus loaded.

**This is the honest comparison to ASML.** There, CI wrote a file and
reloaded Prometheus. Here, you write an object and a controller writes
the file and reloads Prometheus. The file still exists — you just no
longer own the step that produces it.

---

## 4.2 — What the CRD gives you that a JSON pipeline did not

> **Hypothesis.** A `PrometheusRule` with syntactically invalid PromQL is
> rejected at `kubectl apply` time, not discovered at reload time.
>
> **Tool.**
> ```bash
> cat <<'YAML' | kubectl apply -f -
> apiVersion: monitoring.coreos.com/v1
> kind: PrometheusRule
> metadata:
>   name: bad-rule
>   namespace: monitoring
>   labels:
>     release: kube-prometheus-stack
> spec:
>   groups:
>     - name: broken
>       rules:
>         - alert: Nonsense
>           expr: 'sum by ((((( up'
> YAML
> ```
> Then check whether the validating webhook is actually running:
> ```bash
> kubectl get validatingwebhookconfiguration | grep -i prometheus
> ```
>
> **Expected if right.** The apply is **rejected**, with a parse error
> naming the expression — `kube-prometheus-stack` deploys a
> prometheus-operator admission webhook that runs `promtool`-equivalent
> validation on `PrometheusRule` objects. If no webhook is listed, the
> apply succeeds and the rule silently fails to load instead, which tells
> you the validation is a *deployment choice*, not a property of CRDs.
>
> **What would have caught this sooner.** Listing the webhooks. This is
> the single strongest argument for the CRD over a file pipeline: the
> API server refuses bad rules at admission, so bad PromQL cannot reach
> production even if CI is skipped. At ASML the equivalent guarantee was
> `promtool check rules` in the pipeline — real, but bypassable by
> anyone with cluster access and a `kubectl apply`.

Clean up: `kubectl -n monitoring delete prometheusrule bad-rule --ignore-not-found`

---

## 4.3 — A recording rule that earns its keep

Recording rules exist to pre-compute expensive queries. Build one over
something genuinely expensive here — a Loki-derived figure is not
available to Prometheus, so use a multi-series aggregation instead.

Add to `~/k8slab/gitops/observability/dashboards/lab-alerts.yaml`:

```yaml
    - name: lab.recording
      interval: 30s
      rules:
        - record: lab:container_memory_working_set_bytes:sum_by_namespace
          expr: |
            sum by (namespace) (
              container_memory_working_set_bytes{container!="",namespace!=""}
            )
```

> **Hypothesis.** After one `interval`, the recorded series exists and
> querying it is measurably cheaper than the raw aggregation.
>
> **Tool.** Prometheus UI (`kubectl -n monitoring port-forward
> svc/kube-prometheus-stack-prometheus 9090:9090`), run both the raw
> expression and the recorded name, and compare the *Query stats* line.
>
> **Expected if right.** Identical values; the recorded one touches one
> series per namespace instead of one per container. The naming
> convention (`level:metric:operation`) is not decoration — it is how the
> next person knows it is recorded rather than scraped.
>
> **What would have caught this sooner.** The series count in the raw
> query. Anything aggregating hundreds of series on every dashboard
> refresh is a recording-rule candidate, and the number is visible before
> you write the rule.

---

## 4.4 — Close the loop with session 2

Put the recording rule through the ArgoCD path: commit, push, watch it
sync, then delete the `PrometheusRule` by hand and watch `selfHeal`
restore it *and* the operator regenerate the rulefiles ConfigMap.

> **Hypothesis.** There are three propagation steps, and each can fail
> independently: git → object (ArgoCD), object → ConfigMap (operator),
> ConfigMap → loaded rules (config-reloader).
>
> **Tool.** Break the middle one on purpose — remove the `release` label
> as in session 2.5 — and confirm the object is `Synced` while the
> rulefiles ConfigMap no longer contains the rule.
>
> **Expected if right.** ArgoCD green, ConfigMap missing the rule,
> Prometheus not alerting. Three green lights are needed and only one of
> them is ArgoCD's.
>
> **What would have caught this sooner.** Checking the *last* step
> instead of the first. On a real platform the useful question is never
> "is ArgoCD synced" but "is the rule in `/api/v1/rules`":
> ```bash
> curl -s localhost:9090/api/v1/rules | grep -o 'LabPodNotReady' | head -1
> ```

---

## Done-criteria

- [ ] Point at the exact ConfigMap and sidecar that turn a CRD into loaded rules.
- [ ] Reproduce a rejected invalid rule, or prove the webhook isn't deployed.
- [ ] One recording rule live, named to convention, with a measured reason it exists.
- [ ] A written comparison, in your own words, of this vs. the ASML pipeline: what you gained, what you gave up.
- [ ] `runbooks/04-prometheusrule-crd.md` written.

## Runbook seeds

| Symptom | Tool | Cause | Fix | What would have told me this first |
|---|---|---|---|---|
| Rule object exists, never fires | `/api/v1/rules` | `ruleSelector` label mismatch | Add `release: <helm release>` | `ruleSelectorNilUsesHelmValues: true` |
| Invalid PromQL reached the cluster | `validatingwebhookconfiguration` | Admission webhook not deployed | Enable it, or keep `promtool` in CI | Listing webhooks before trusting admission |
| Rule loads but alert never fires | Prometheus → Alerts, expression evaluated live | `for:` window longer than the condition lasts | Shorten `for:`, or fix the expression | Running the raw expression by hand first |
| Dashboard slow on a big aggregation | Prometheus query stats | No recording rule | Add one, `level:metric:operation` | Series count in the raw query |
