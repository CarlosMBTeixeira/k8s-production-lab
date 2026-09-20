# Session 2 — Dashboards and alerts reconciled by ArgoCD

**Objective:** take a dashboard defined as code, have ArgoCD apply and
continuously reconcile it, and feel — with a stopwatch — the difference
between a pipeline that pushed once and a controller that keeps pushing
forever.

This is the centre of the whole workbook. Everything else is scaffolding
around it.

**Prerequisites**
- `main.sh` choice **4** (ArgoCD *and* observability).
- `~/k8slab/gitops/` cloned, on branch `feature/argocd`.
- Both tunnels usable: ArgoCD `:8444`, Grafana `:8445`.

**Read first:** ArgoCD *User Guide* → "Auto Sync" and "Diffing". Nothing
else.

---

## 2.0 — Name the difference before you build it

At ASML the loop was: commit JSON → GitLab CI runs → `kubectl apply` →
pipeline exits. State converges **once, at commit time**, and the
pipeline is the only thing that ever writes.

ArgoCD's loop is: a controller holds the desired state and compares it to
live state **forever**. Nothing "runs". There is no exit.

> **Hypothesis.** The push pipeline and the pull controller differ in
> exactly one place: what happens between commits. Everything at commit
> time looks the same.
>
> **Tool.** Write the two failure modes down, now, before building
> anything:
> 1. Someone edits the live resource by hand at 02:00. What happens under
>    each model, and when does anyone find out?
> 2. The CI runner's credentials expire. What happens under each model?
>
> **Expected if right.** Under push, (1) is invisible until the next
> commit — possibly months — and (2) fails loudly at the next commit.
> Under pull, (1) is reverted in seconds and shows as `OutOfSync` on a
> dashboard, and (2) has no equivalent, because there is no runner. The
> credential that matters moved from CI into the cluster.
>
> **What would have caught this sooner.** Nothing to catch — this is the
> hypothesis the rest of the session tests.

---

## 2.1 — How a dashboard gets into this Grafana at all

Grafana here does not read files and has no persistent database worth
trusting. `kube-prometheus-stack` runs a **sidecar** next to Grafana that
watches ConfigMaps carrying a specific label and writes their contents
into Grafana's provisioning directory.

Don't take the label on trust — read it off the running Deployment:

```bash
kubectl -n monitoring get deploy -l app.kubernetes.io/name=grafana -o name
kubectl -n monitoring get deploy kube-prometheus-stack-grafana \
  -o jsonpath='{range .spec.template.spec.containers[?(@.name=="grafana-sc-dashboard")]}{.env[*].name}{"\n"}{.env[*].value}{"\n"}{end}'
```

> **Hypothesis.** The sidecar selects on a label (expect
> `grafana_dashboard=1`) and is scoped to one namespace.
>
> **Tool.** The command above; read `LABEL`, `LABEL_VALUE`, `FOLDER`,
> `NAMESPACE`.
>
> **Expected if right.** A label key/value pair and a namespace scope
> (often the release namespace only). **Whatever it prints is
> authoritative — use those exact values below, not the ones written
> here.**
>
> **What would have caught this sooner.** This command. A dashboard
> ConfigMap that never appears in Grafana is almost always a label
> mismatch or a namespace scope, and both are visible here in one line.

**This is the seam.** The dashboard is a ConfigMap. A ConfigMap is an
ordinary Kubernetes resource. Anything that can manage a Kubernetes
resource can manage a dashboard — which is why ArgoCD can do this at all,
and why it needs no Grafana-specific integration.

---

## 2.2 — A dashboard as code, in the `gitops/` tree

Build something you can verify at a glance — a single stat panel showing
pod count in `monitoring`.

```bash
mkdir -p ~/k8slab/gitops/observability/dashboards
```

`~/k8slab/gitops/observability/dashboards/lab-overview-cm.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: lab-overview-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"          # ← whatever 2.1 printed
  annotations:
    grafana_folder: "Lab"
data:
  lab-overview.json: |
    {
      "title": "Lab Overview",
      "uid": "lab-overview",
      "timezone": "browser",
      "schemaVersion": 39,
      "panels": [
        {
          "type": "stat",
          "title": "Pods running in monitoring",
          "gridPos": { "h": 6, "w": 8, "x": 0, "y": 0 },
          "targets": [
            {
              "expr": "count(kube_pod_status_phase{namespace=\"monitoring\",phase=\"Running\"})",
              "refId": "A"
            }
          ]
        }
      ]
    }
```

The JSON is embedded in YAML, so the PromQL's inner quotes need
escaping. That friction is real and it is the reason people reach for
Kustomize's `configMapGenerator` with the JSON in its own file — worth
knowing, not worth doing on the first pass.

Then the Application, `~/k8slab/gitops/apps/root/observability-dashboards.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: observability-dashboards
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/CarlosMBTeixeira/k8s-production-lab.git
    targetRevision: feature/argo-and-observability-study
    path: gitops/observability/dashboards
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

It lands in `apps/root/` so the existing App-of-Apps root
(`../kubernetes/manifests/argocd/apps/root-app.yaml`) adopts it — no
`kubectl apply` of your own. That root Application is the only one ever
applied by hand.

```bash
cd ~/k8slab
git add -A && git commit -m "Add lab-overview dashboard as an ArgoCD-managed ConfigMap" && git push
```

**Done when** the dashboard appears in Grafana under the *Lab* folder
without you having run `kubectl apply` once.

---

## 2.3 — The two clocks

Two different latencies are about to matter, and conflating them is the
most common misunderstanding of how ArgoCD works.

> **Hypothesis.** A change committed to git and a change made directly to
> a live resource are detected by *different mechanisms*, on *different*
> timescales — and the git one is the slower.
>
> **Tool.** Time both.
>
> ```bash
> # git → cluster: change the panel title, commit, push, then watch
> time kubectl -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced \
>   application/observability-dashboards --timeout=300s
>
> # cluster → cluster: mutate live state and watch it come back
> kubectl -n monitoring patch cm lab-overview-dashboard --type merge \
>   -p '{"metadata":{"annotations":{"drift":"manual-edit"}}}'
> kubectl -n argocd get application observability-dashboards -w
> ```
>
> **Expected if right.** Git changes wait for a **polling** cycle —
> ArgoCD re-fetches the repo on `timeout.reconciliation`, default
> **180s**. Live-state changes are caught by a **watch** on the cluster,
> so `OutOfSync` appears within seconds, and `selfHeal` reverts shortly
> after. Drift correction is fast; git propagation is slow. Backwards
> from most people's intuition.
>
> **What would have caught this sooner.** `kubectl -n argocd get cm
> argocd-cm -o yaml | grep -i timeout` — the git-side number is
> configurable and written down. The cluster side isn't a timer at all.

Confirm the interval rather than believing the paragraph above:

```bash
kubectl -n argocd get cm argocd-cm -o yaml | grep -iA1 reconciliation
```

(Empty means the default is in force. Webhooks are how real platforms
collapse the 180s to near-zero — worth knowing exists; nothing here can
receive one.)

---

## 2.4 — Drift, properly

The obvious experiment is "edit the dashboard in the Grafana UI and watch
ArgoCD revert it." **It will not work, and the reason is the good part.**

> **Hypothesis.** Editing a provisioned dashboard in the Grafana UI and
> pressing Save will fail, and ArgoCD will have nothing to do with it.
>
> **Tool.** Grafana → Lab → Lab Overview → edit the panel title → Save.
>
> **Expected if right.** Grafana refuses — provisioned dashboards are
> read-only in the UI unless `allowUiUpdates` is set. ArgoCD never sees
> anything, because nothing in Kubernetes changed. The dashboard lives in
> a ConfigMap; the UI was never the source of truth.
>
> **What would have caught this sooner.** Asking "what Kubernetes object
> would this edit modify?" The answer is none — which is the whole point
> of provisioning. **The push model let you edit in the UI and silently
> lose it at the next pipeline run. The pull model makes the mistake
> structurally impossible instead of merely recoverable.**

So drift has to be introduced where the state actually lives:

```bash
# Time it properly.
date +%T
kubectl -n monitoring patch cm lab-overview-dashboard --type merge \
  -p '{"data":{"lab-overview.json":"{\"title\":\"HACKED\",\"uid\":\"lab-overview\",\"panels\":[]}"}}'

# In another pane:
kubectl -n argocd get application observability-dashboards \
  -o jsonpath='{.status.sync.status}{" "}{.status.health.status}{"\n"}' -w
```

> **Hypothesis.** The ConfigMap returns to its committed content without
> anyone acting, and the Application passes through `OutOfSync` on the
> way.
>
> **Tool.** The watch above, plus
> `kubectl -n monitoring get cm lab-overview-dashboard -o jsonpath='{.data}'`
> before and after, and the ArgoCD UI's own event history.
>
> **Expected if right.** `OutOfSync` within seconds, back to `Synced`
> shortly after (`selfHeal` has a short base delay and an exponential
> backoff on repeated failures). Grafana shows the real dashboard again
> once the sidecar re-reads the ConfigMap — note the *two* propagation
> steps: ArgoCD → ConfigMap, sidecar → Grafana. A dashboard that is
> correct in `kubectl` but stale in the browser means the second step,
> not the first.
>
> **What would have caught this sooner.** Knowing the sidecar sits
> between them. The ConfigMap is ArgoCD's boundary; everything past it is
> Grafana's problem.

Then the harder version — **delete it entirely**:

```bash
kubectl -n monitoring delete cm lab-overview-dashboard
```

> **Hypothesis.** It comes back.
>
> **Expected if right.** It does. `selfHeal` handles deletions as
> divergence like any other. Now try it the other way — add a ConfigMap
> with the dashboard label that *isn't* in git, and confirm it is **not**
> deleted: `prune: true` only removes resources ArgoCD once created and
> git no longer declares. ArgoCD owns what it applied, not the namespace.
>
> **What would have caught this sooner.** The ownership question is
> answered by the `app.kubernetes.io/instance` label and the tracking
> annotation ArgoCD stamps on resources it manages:
> `kubectl -n monitoring get cm lab-overview-dashboard -o yaml | grep -i argocd`

**Done when** you can state the revert time you measured, and explain
why an identical dashboard created by hand survives a sync while the
managed one cannot be deleted.

---

## 2.5 — The same thing for an alert

Alerts are the same seam with a different object — a `PrometheusRule`
CRD instead of a ConfigMap. Add one to the same Application path:

`~/k8slab/gitops/observability/dashboards/lab-alerts.yaml`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: lab-alerts
  namespace: monitoring
  labels:
    release: kube-prometheus-stack      # ← see below; this is load-bearing
spec:
  groups:
    - name: lab.rules
      rules:
        - alert: LabPodNotReady
          expr: kube_pod_status_ready{namespace="monitoring",condition="true"} == 0
          for: 2m
          labels:
            severity: warning
          annotations:
            summary: "Pod {{ $labels.pod }} not ready for 2m"
```

That `release` label is where this goes wrong for everyone once.
`kube-prometheus-stack` sets `ruleSelectorNilUsesHelmValues: true` by
default, which makes the Prometheus CR select **only** rules labelled
with the Helm release name. A `PrometheusRule` without it is a valid
object, syncs green in ArgoCD, and is silently never loaded.

> **Hypothesis.** ArgoCD reports `Synced` and `Healthy` while Prometheus
> has never heard of the rule.
>
> **Tool.** Remove the `release` label, commit, let it sync, then check
> both sides:
> ```bash
> kubectl -n monitoring get prometheusrule lab-alerts        # exists
> kubectl -n monitoring get prometheus -o yaml | grep -A5 ruleSelector
> # Prometheus UI → Alerts, via port-forward:
> kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
> ```
>
> **Expected if right.** The object exists, ArgoCD is green, and
> Prometheus's Alerts page does not list `LabPodNotReady`. Put the label
> back and it appears within a reconcile.
>
> **What would have caught this sooner.** `ruleSelector` on the
> Prometheus CR — one `kubectl get` that tells you exactly which labels
> are required. **Green in ArgoCD means "the object matches git", never
> "the object is doing anything."** That sentence is the most valuable
> thing in this session.

Session 4 goes deeper into `PrometheusRule`. Here it exists only to prove
the reconciliation seam is identical for alerts and dashboards.

---

## Done-criteria for the whole session

- [ ] A dashboard visible in Grafana that you never `kubectl apply`ed.
- [ ] A measured revert time for a `kubectl`-introduced drift, written down.
- [ ] An explanation of why the Grafana UI edit was refused, and why that is better than reverting it.
- [ ] A `PrometheusRule` that is `Synced` in ArgoCD and absent from Prometheus, then fixed.
- [ ] `runbooks/02-dashboards-alerts-via-argocd.md` written.

## Runbook seeds

| Symptom | Tool | Cause | Fix | What would have told me this first |
|---|---|---|---|---|
| Dashboard ConfigMap exists, Grafana doesn't show it | sidecar env (`LABEL`, `NAMESPACE`) | Label mismatch or out-of-scope namespace | Match the sidecar's selector | Reading the sidecar env before writing the ConfigMap |
| Git push doesn't appear for ~3 min | `argocd-cm` `timeout.reconciliation` | Polling interval, not a fault | Wait, `argocd app sync`, or a webhook | Knowing git is polled and drift is watched |
| Grafana UI "cannot save dashboard" | Grafana provisioning docs | Provisioned dashboards are read-only | Edit the ConfigMap in git | The dashboard was never UI-owned |
| Alert green in ArgoCD, absent in Prometheus | `ruleSelector` on the Prometheus CR | Missing `release` label | Add the label | `ruleSelectorNilUsesHelmValues: true` |
| Hand-made resource not pruned | ArgoCD tracking annotation | ArgoCD prunes only what it created | Expected; declare it in git to own it | The `app.kubernetes.io/instance` label |
