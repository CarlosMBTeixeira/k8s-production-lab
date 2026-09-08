# Tier 5 — Operating ArgoCD itself

Everything so far treats ArgoCD as infrastructure that just works.
Production engagements treat ArgoCD as a service you're on the hook
for — it gets monitored, alerted on, reasoned about at scale, and
backed up like anything else you run.

---

## 5.1 — Notifications

**Goal:** an alert fires the moment something goes wrong — self-heal
already *fixes* drift silently, but nobody currently finds out drift
happened at all.

### Step 1 — Get a webhook URL to send to

Easiest without a Slack workspace: go to
[webhook.site](https://webhook.site), which hands you a unique,
disposable URL and shows every request it receives live — good
enough to prove the notification actually fires. (If you do have
Slack, the chart's `notifications.notifiers` block supports a native
Slack notifier the same way — swap the webhook config below for
that.)

### Files to change

Add to `kubernetes/manifests/argocd/values.yaml`:
```yaml
notifications:
  notifiers:
    service.webhook.generic: |
      url: https://webhook.site/<your-unique-id>
      headers:
        - name: Content-Type
          value: application/json
```

The chart ships a default catalog of triggers/templates already —
`on-sync-failed`, `on-health-degraded`, etc. — so you don't need to
author those yourself, just subscribe an Application to them. Edit
`apps/root/waved-demo-app.yaml` (in `k8s-gitops`):
```yaml
metadata:
  name: waved-demo
  namespace: argocd
  annotations:
    notifications.argoproj.io/subscribe.on-sync-failed.generic: ""
    notifications.argoproj.io/subscribe.on-health-degraded.generic: ""
```

### Commands

```bash
cd ~/k8slab
export KUBECONFIG=~/k8slab/kubernetes/admin.conf
helm upgrade argocd argo/argo-cd --version 10.1.4 --namespace argocd -f kubernetes/manifests/argocd/values.yaml

cd ~/k8s-gitops
git add apps/root/waved-demo-app.yaml && git commit -m "Subscribe waved-demo to sync-failed/health-degraded notifications" && git push
```

### Verify

Reuse the broken-hook trick from Tier 3.2: break
`waved-demo-premigration`'s command again (`exit 1`), push, and watch
`webhook.site` receive a POST within a minute or so. Then revert.

### Why this matters in client work

Self-heal fixes drift; it doesn't tell anyone it happened. Someone
still needs to know — that's what turns a GitOps setup from "silently
correct" into "operable."

---

## 5.2 — Monitor ArgoCD with your own Grafana

**Goal:** ArgoCD's own Prometheus metrics flowing into the
kube-prometheus-stack Grafana you already run (ADR-031), with one
real alert rule.

> **RAM budget note:** same constraint as Tier 3.4 — this needs
> ArgoCD and the observability stack running together. Reuse whatever
> workaround you picked there.

### Files to change

Add to `kubernetes/manifests/argocd/values.yaml`:
```yaml
controller:
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true
server:
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true
repoServer:
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true
applicationSet:
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true
```

### Commands

```bash
helm upgrade argocd argo/argo-cd --version 10.1.4 --namespace argocd -f kubernetes/manifests/argocd/values.yaml
kubectl get servicemonitor -n argocd   # four new ServiceMonitors
```

In Grafana (via `./scripts/tunnels/grafana-tunnel.sh`): Dashboards →
Import, search grafana.com's dashboard library for an official
**Argo CD** dashboard (published by `argoproj` — check the author
before importing anything from a public library) and import by ID.

Add one real alert rule — ArgoCD flagging its own drift for longer
than it should:
```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: argocd-outofsync
  namespace: monitoring
  labels:
    release: kube-prometheus-stack   # matches the chart's default PrometheusRule selector
spec:
  groups:
    - name: argocd
      rules:
        - alert: ArgoCDAppOutOfSync
          expr: argocd_app_info{sync_status="OutOfSync"} == 1
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "ArgoCD app {{ $labels.name }} has been OutOfSync for 10+ minutes"
```
The `release: kube-prometheus-stack` label matters — without it, the
chart's Prometheus CR won't pick this rule up by default.

```bash
kubectl apply -f argocd-outofsync-rule.yaml
```

### Verify

Confirm the dashboard shows real data (sync status, app count,
reconciliation duration). Trigger the alert for real: pause
auto-sync on an app (`argocd app set waved-demo --sync-policy none`),
drift it (scale a deployment out-of-band), wait 10 minutes, and check
Prometheus's **Alerts** page shows `ArgoCDAppOutOfSync` firing. Then
re-enable auto-sync.

### Why this matters in client work

Same reasoning as the Network Policy validation you already did
against Prometheus's own `/targets` page (ADR-034) — trust the
dashboard, not the assumption.

---

## 5.3 — HA architecture: reason about it, don't necessarily build it

**Goal:** not a full HA deployment — the lab's RAM budget genuinely
doesn't support it — but a written answer to "how would this scale,"
grounded in actually reading the chart's HA-relevant values, not
guesswork.

### Do

```bash
helm show values argo/argo-cd --version 10.1.4 | grep -A 20 "redis-ha:"
helm show values argo/argo-cd --version 10.1.4 | grep -B 2 -A 10 "^controller:"
```

Read (don't apply) what `redis-ha.enabled`, `controller.replicas`,
and `server.replicas`/`repoServer.replicas` actually do. The
non-obvious part worth understanding specifically: the
`application-controller` shards its work **by cluster**, not by
Application — so its replica count mostly matters once you're
managing *multiple* clusters (Tier 6), not as a single-cluster HA
lever. `server` and `repo-server` are stateless and scale
horizontally the ordinary way.

Write yourself a short note — you already have the ADR habit, 34 of
them — answering:
- What would you turn on first if a client needed ArgoCD to survive a
  node failure?
- What doesn't actually help until you're running multiple clusters?
- What's the honest gap between what this lab demonstrates and a
  real HA deployment, and why that gap is fine here?

### Why this matters in client work

Being able to reason correctly about HA topology in an architecture
review matters more than having personally run 3 replicas once in a
lab — and being explicit about what a homelab can't demonstrate is
more credible than pretending it can.

---

## 5.4 — Backup & disaster recovery

**Goal:** destroy the entire `argocd` namespace, then bring ArgoCD's
own state back from a backup — and see, concretely, what Git alone
already gave you back for free versus what actually needed the
backup.

### Commands

```bash
export KUBECONFIG=~/k8slab/kubernetes/admin.conf

# 1. Back up ArgoCD's own state — Applications, AppProjects, RBAC
#    config, repo credentials, everything living as a K8s object in
#    the argocd namespace.
argocd admin export --kubeconfig kubernetes/admin.conf > /tmp/argocd-backup.yaml

# 2. Destroy it. This is real — think before running it.
kubectl delete namespace argocd

# 3. Reinstall a bare chart (no Applications yet — just ArgoCD itself)
kubectl create namespace argocd
helm upgrade --install argocd argo/argo-cd --version 10.1.4 \
  --namespace argocd -f kubernetes/manifests/argocd/values.yaml
kubectl wait --for=condition=Available --timeout=300s -n argocd deployment/argocd-server

# 4. The self-signed TLS secret + Gateway + HTTPRoute lived in this
#    namespace too — regenerate them the same way 06_argocd.sh did originally
#    (Steps 3-4 in that script: openssl req ..., kubectl apply gateway-argocd.yaml/httproute-argocd.yaml)

# 5. Restore ArgoCD's own state from the backup
argocd admin import --kubeconfig kubernetes/admin.conf < /tmp/argocd-backup.yaml
```

### Verify

```bash
kubectl get applications,appprojects,applicationsets -n argocd
```
Everything from Tiers 1-4 should reappear — `root`, the AppProject,
every Application, the ApplicationSet, the repo credential secret —
without you re-`kubectl apply`-ing a single one of them. Then check
the workloads that were **never actually deleted** (they're in
`hello-world-dev`, `podinfo`, `waved-demo`, etc. — different
namespaces, untouched by deleting `argocd`):

```bash
kubectl get pods -n hello-world-prod -n podinfo -n waved-demo
```
Same pods, same `AGE` as before the drill — they kept running the
entire time ArgoCD itself was gone.

### Why this matters in client work

"Git is the backup" is only half true. Git backs up *what to
deploy* — which is why your actual workloads never even noticed
ArgoCD was gone. It does **not** back up ArgoCD's own configuration
(RBAC roles, repo credentials, AppProjects) — that's what
`admin export`/`import` is actually for. Knowing the difference
before an incident, not during one, is the entire point of this
drill.

---

**Tier 5 done.** State at this point: alerts on both failed syncs and
sustained drift, ArgoCD's own health visible in your existing
Grafana, a written HA reasoning note, and a proven DR path. Next:
[Tier 6 — multi-cluster & ArgoCD-as-code](06-multicluster-as-code.md).
