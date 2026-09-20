# Session 6 — OpenShift monitoring and logging

**Objective:** work out, on a real cluster, what changes when the
monitoring stack is *the platform's* rather than yours — and where the
boundary sits between what you configure and what the operator owns.

Different cluster, different repo, same workbook. The k8s lab and CRC
**cannot run at the same time**: 24 GB host, the lab takes 16 GB, CRC
wants 10.5 GB minimum and appreciably more once monitoring is on.

**Prerequisites**
- Multipass stopped: `multipass stop --all` then confirm `multipass list`.
- CRC already set up and proven (`~/openshift-local-lab/openshift-local-lab/docs/skipped-checks.md`:
  24/24 operators Available, one skipped check, `wsl2`).
- `sg libvirt -c '...'` in front of every `crc` command until a full
  `wsl --shutdown` — see that repo's `docs/runbook-start-stop.md`.

**Read first:** Red Hat OpenShift documentation → *Monitoring* →
"Monitoring overview" and "Enabling monitoring for user-defined
projects". Product docs only; the version must match `crc version`
(4.22.x as configured).

---

## 6.0 — Two things must change before anything else works

`crc config view` currently shows only `consent-telemetry` and
`skip-check-wsl2`. Neither memory nor monitoring is set, and **CRC
disables the monitoring stack by default** to save resources — so none of
this session exists until that is turned on.

```bash
multipass stop --all

sg libvirt -c 'crc config set enable-cluster-monitoring true'
sg libvirt -c 'crc config set memory 14336'      # MiB; 10.5 GB minimum + monitoring headroom
sg libvirt -c 'crc config set cpus 6'
sg libvirt -c 'crc config view'

sg libvirt -c 'crc start'
eval "$(crc oc-env)"
oc whoami                                         # expect: kubeadmin
```

> **Hypothesis.** Enabling monitoring adds a large set of pods that were
> not merely scaled to zero — they did not exist at all.
>
> **Tool.** Before and after:
> ```bash
> oc get pods -n openshift-monitoring
> oc get clusteroperator monitoring
> ```
>
> **Expected if right.** Previously empty or minimal, now a full stack:
> Prometheus (2 replicas on a real cluster, likely 1 here), Alertmanager,
> Thanos Querier, `kube-state-metrics`, `node-exporter`,
> `openshift-state-metrics`, `telemeter-client`, `prometheus-operator`.
> Give it several minutes and expect the node to feel it.
>
> **What would have caught this sooner.** `crc config view` and the CRC
> docs' note on monitoring. This is also the single most likely place for
> the session to fail on memory — if `crc start` hangs at *Waiting for
> kube-apiserver*, that is symptom E in that repo's README, and the fix
> is more memory or fewer expectations.

---

## 6.1 — The structural difference from `kube-prometheus-stack`

You have just installed the same components twice by two entirely
different routes. That is the comparison this session exists for.

> **Hypothesis.** The platform stack cannot be modified the way a Helm
> release can: a direct edit to the Prometheus CR in
> `openshift-monitoring` is reverted, by an operator, without anyone
> asking.
>
> **Tool.**
> ```bash
> oc get prometheus -n openshift-monitoring
> oc -n openshift-monitoring patch prometheus k8s --type merge \
>   -p '{"spec":{"retention":"72h"}}'
> # wait, then:
> oc -n openshift-monitoring get prometheus k8s -o jsonpath='{.spec.retention}{"\n"}'
> ```
>
> **Expected if right.** It reverts. The **Cluster Monitoring Operator**
> owns those objects and continuously reconciles them to its own desired
> state. **This is `selfHeal` from session 2, in the platform's hands
> rather than yours** — and once you see that, OpenShift's monitoring
> model stops being unfamiliar. Same loop, different controller, and the
> git repo is replaced by the operator's built-in intent.
>
> **What would have caught this sooner.** `oc get clusteroperator
> monitoring` and asking what a ClusterOperator *is*. Anything with a
> ClusterOperator has an operator reconciling it and is not yours to
> edit.

The supported way in is a ConfigMap — a deliberately narrow API:

```bash
oc -n openshift-monitoring get cm cluster-monitoring-config -o yaml 2>/dev/null \
  || echo "does not exist yet — that is normal"
```

> **Hypothesis.** The supported configuration surface is strictly smaller
> than the Prometheus CR's, and that is a design decision, not a
> limitation.
>
> **Tool.** Compare the documented `cluster-monitoring-config` keys
> against the Prometheus CRD's schema:
> `oc explain prometheus.spec | head -60`
>
> **Expected if right.** A handful of supported keys — retention, storage
> class, node selectors, resource requests, `enableUserWorkload` — versus
> dozens of CR fields. Red Hat supports what that ConfigMap exposes and
> nothing else. **This is precisely why you do not install your own
> `kube-prometheus-stack` on OpenShift**: you would be running an
> unsupported second stack scraping the same targets, doubling the memory
> cost, and losing the console integration.
>
> **What would have caught this sooner.** Asking "is this component a
> ClusterOperator?" before reaching for Helm. On OpenShift the answer
> decides whether you configure or install.

---

## 6.2 — User workload monitoring

Platform monitoring deliberately does not scrape your applications.
Enabling that is one field — and the *effect* of that one field is the
exercise.

```bash
oc -n openshift-monitoring create configmap cluster-monitoring-config \
  --from-literal=config.yaml='enableUserWorkload: true' \
  --dry-run=client -o yaml | oc apply -f -

oc -n openshift-user-workload-monitoring get pods -w
```

> **Hypothesis.** One boolean creates an entire second Prometheus stack
> in its own namespace, separate from the platform's.
>
> **Tool.** The watch above, then:
> ```bash
> oc get pods -n openshift-user-workload-monitoring
> oc get prometheus -A
> ```
>
> **Expected if right.** A new namespace running its own
> `prometheus-operator`, `prometheus-user-workload`, and `thanos-ruler`.
> **Two Prometheus instances, deliberately separated** — so that a tenant
> flooding metrics cannot take down platform monitoring, and so tenants
> can be given access to their own data without access to the cluster's.
> Thanos Querier fans out across both, which is why the console shows one
> unified view.
>
> **What would have caught this sooner.** The namespace name. OpenShift
> names the boundary out loud: `openshift-monitoring` versus
> `openshift-user-workload-monitoring`.

### Expose an application to it

```bash
oc new-project uwm-demo
oc new-app --image=quay.io/brancz/prometheus-example-app:v0.3.0 --name=example-app
oc expose deployment example-app --port=8080
```

Then a `ServiceMonitor` **in your own namespace**:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: example-app
  namespace: uwm-demo
spec:
  selector:
    matchLabels:
      app: example-app
  endpoints:
    - port: "8080"
      interval: 30s
```

> **Hypothesis.** No label like session 2's `release:` is needed here —
> the user-workload Prometheus selects ServiceMonitors by *namespace*,
> not by label — and the metric is queryable from the console within a
> scrape interval or two.
>
> **Tool.** Console → Observe → Metrics, query `version` or
> `http_requests_total`. Or:
> ```bash
> oc -n uwm-demo get servicemonitor
> oc -n openshift-user-workload-monitoring logs -l app.kubernetes.io/name=prometheus -c prometheus | tail -30
> ```
>
> **Expected if right.** It works with no selector label, because scope
> is namespace-based: UWM watches all non-`openshift-*` namespaces. This
> is **the opposite** of session 2's failure mode, where a missing
> `release:` label silently dropped the rule. Same CRD, two different
> selection models, two different ways to lose a target — knowing which
> cluster you are on decides which mistake you are about to make.
>
> **What would have caught this sooner.** `oc get prometheus
> prometheus-user-workload -n openshift-user-workload-monitoring -o yaml
> | grep -A10 -i 'selector'` — read the selector, as in session 2. The
> method transfers even though the answer does not.

**Done when** one of your own metrics is visible in the OpenShift console
and you can explain why it needed no `release` label.

---

## 6.3 — LokiStack, and an honest limit

OpenShift's logging is the **Loki Operator** managing a `LokiStack` CR,
with the **Cluster Logging Operator** running Vector collectors and a
`ClusterLogForwarder` describing where logs go.

**Read this before attempting it:** `LokiStack` requires **object
storage** — a Secret holding S3/Azure/GCS/Swift credentials. There is no
`filesystem` mode. The self-hosted Loki in session 1 runs
`SingleBinary` + `filesystem` + `persistence: false`; LokiStack
structurally will not let you do that, which is itself the most important
finding of this section.

> **Hypothesis.** The comparison can be made from the CRD alone, without
> a working LokiStack.
>
> **Tool.** Install the Loki Operator from OperatorHub (console, or
> `oc get packagemanifests -n openshift-marketplace | grep -i loki`),
> then read the schema without creating an instance:
> ```bash
> oc explain lokistack.spec
> oc explain lokistack.spec.storage
> oc explain lokistack.spec.size
> ```
>
> **Expected if right.** `storage.secret` is required; `size` takes
> t-shirt values (`1x.demo`, `1x.extra-small`, …) that each imply a fixed
> topology — ingester/distributor/querier/query-frontend/compactor as
> separate deployments, not one binary. Compare field by field with
> `../kubernetes/manifests/observability/loki-values.yaml`.
>
> **What would have caught this sooner.** `oc explain` on a CRD you have
> not instantiated. Reading the schema is a legitimate way to learn an
> operator's model and costs no memory.

**Attempt a running LokiStack only if memory allows.** `1x.demo` plus
MinIO for object storage, on top of cluster monitoring and user workload
monitoring, on a 14 GB CRC VM, is optimistic. If it does not fit, that is
a result, not a failure — record it in
`~/openshift-local-lab/openshift-local-lab/docs/experiment-log.md` with
the numbers, and carry the schema comparison forward instead. **Do not
spend a whole session fighting memory.** The topic you actually need on
day one is the ownership boundary, and 6.1–6.2 already teach it.

### The comparison to write down

| | Session 1's Loki | OpenShift LokiStack |
|---|---|---|
| Who installs it | you, via Helm | an Operator, from OperatorHub |
| Topology | `SingleBinary` | fixed by `size`, multi-component |
| Storage | filesystem, ephemeral | object storage, mandatory |
| Collector | Grafana Alloy, your config | Vector, via `ClusterLogForwarder` |
| Query UI | Grafana Explore | OpenShift console (Logging view) |
| Tenancy | none (`auth_enabled: false`) | application / infrastructure / audit tenants |
| Yours to fix at 03:00 | all of it | the CR and the forwarder; the rest is the operator's |

That last row is the one that matters at Claranet.

---

## 6.4 — EX280 as a checklist, not a curriculum

Pull the **official objectives list** from Red Hat's EX280 exam page. Do
not work from a summary, and do not study the whole thing here — this is
a gap-check for monitoring and logging only.

Take only the objectives touching monitoring, logging, metrics or
troubleshooting, and mark each: **done in this session / needs a real
cluster / not applicable to CRC**. The third category is real —
multi-node, upgrades, and storage-backed logging genuinely cannot be
exercised here, and having that list written down is what turns "I have
not done OpenShift" into a precise, defensible statement in a
conversation with your new team.

---

## Afterwards — hand the machine back

```bash
sg libvirt -c 'crc stop'
multipass start --all          # only if you want the k8s lab back
```

Do **not** run `crc delete` or `crc cleanup` — see that repo's
`runbook-start-stop.md`, "Do not run these".

---

## Done-criteria

- [ ] Cluster monitoring enabled and healthy on CRC, with the memory setting recorded.
- [ ] A platform Prometheus edit made, reverted by CMO, and observed.
- [ ] User workload monitoring enabled; your own metric visible in the console.
- [ ] A written comparison of the two Loki models, from the CRD schema if not from a running instance.
- [ ] EX280 monitoring/logging objectives triaged into the three categories.
- [ ] `runbooks/06-openshift-monitoring-logging.md` written.

## Runbook seeds

| Symptom | Tool | Cause | Fix | What would have told me this first |
|---|---|---|---|---|
| No monitoring pods on CRC | `crc config view` | Monitoring disabled by default | `enable-cluster-monitoring true`, restart | The CRC docs' resource note |
| Edit to platform Prometheus disappears | `oc get clusteroperator` | CMO reconciles it | Use `cluster-monitoring-config` | It is a ClusterOperator |
| App metric not in the console | UWM Prometheus selector | UWM not enabled, or `ServiceMonitor` in an `openshift-*` namespace | Enable UWM; use your own namespace | Selection is by namespace, not label |
| `crc start` hangs at kube-apiserver | `crc status`, host `free -h` | Not enough memory, Multipass still up | `multipass stop --all`, raise memory | The 24 GB budget written down |
| `LokiStack` will not create | `oc explain lokistack.spec.storage` | Object storage secret is mandatory | Provide one, or stop at the schema | No filesystem mode exists |
| Every `crc` command fails on libvirt group | `id -nG` | Group not in this session | `sg libvirt -c`, or `wsl --shutdown` | That repo's start/stop runbook |
