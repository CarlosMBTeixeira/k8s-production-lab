# Workbook — Observability, GitOps and OpenShift

The practical path from "I can do this with a push pipeline" to "I can do
this the way the Claranet platform does it." Six sessions, each one
exercises against a real cluster, each one ending in a runbook worth
keeping.

Start date of the job being prepared for: **19 October 2026.**

---

The brief this answers is kept verbatim in [`00-brief.md`](00-brief.md).

## The four gaps this exists to close

Everything else in this lab is already at working level. These are not.

| # | Gap | Where it stands |
|---|---|---|
| 1 | **LogQL.** Grafana with a datasource that isn't Prometheus. | The Loki datasource is already wired in (ADR-032) — the gap is purely the query language and the label model behind it. |
| 2 | **The *pull* model for dashboards and alerts.** | Doing this with GitLab CI pushing JSON is familiar. ArgoCD reconciling it — `selfHeal`, drift detection — has never been done. |
| 3 | **OpenShift.** | Never worked on it directly. Platform-managed monitoring is a different model from installing your own `kube-prometheus-stack`, and native logging (LokiStack) is a different model from the self-hosted Loki here. |
| 4 | **ArgoCD beyond the basics.** | ApplicationSet generators in a multi-environment scenario, and secrets end-to-end with External Secrets Operator. |

**Explicitly not in scope:** ArgoCD fundamentals (done — see
`../docs/argocd-learning-path/`), the CKS syllabus (runs separately), and
any video course.

---

## The sessions

| # | Session | Cluster | Blocked on |
|---|---|---|---|
| 1 | [Loki as a datasource + LogQL](01-loki-logql.md) | k8slab | nothing |
| 2 | [Dashboards and alerts reconciled by ArgoCD](02-dashboards-alerts-via-argocd.md) | k8slab | nothing |
| 3 | [kube-prometheus-stack installed *by* ArgoCD](03-kube-prometheus-stack-via-argocd.md) | k8slab | session 2 |
| 4 | [Recording and alerting rules as `PrometheusRule`](04-prometheusrule-crd.md) | k8slab | session 1 (for the log-derived alert) |
| 5 | [ApplicationSets, sync waves, External Secrets](05-applicationsets-and-eso.md) | k8slab | sessions 2–3 |
| 6 | [OpenShift monitoring and logging](06-openshift-monitoring-logging.md) | CRC | CRC memory raised; Multipass stopped |

Sessions 1–5 run on this lab. Session 6 runs on CRC in
`~/openshift-local-lab/openshift-local-lab/` — **the two clusters cannot
be up at the same time** (24 GB host; the k8s lab takes 16 GB, CRC wants
11 GB minimum and more once monitoring is on). The workbook lives here
regardless, so there is one place to look.

No calendar. Each session is a self-contained block, executable whenever
the time exists.

---

## The method

Every unit in every session follows the same four beats. This is
deliberate — it is the same shape used in the rest of the study plan, and
it is what turns an exercise into something transferable.

> **Hypothesis** — what you believe is true, stated before you look.
> **Tool** — the single command or view that tests it.
> **Expected if right** — what you should see. Written *before* running it.
> **What would have caught this sooner** — the signal that existed before
> the symptom did. This column is the actual product.

Writing the expectation before running the command is the whole
discipline. An exercise where you ran the command first and rationalised
afterwards has taught you the tool's output, not the system's behaviour.

## Done-criteria

Every session states what "finished" looks like as something checkable —
a query that returns a specific shape, a resource that reappears within a
time bound, a status that flips. Not "read and understood."

## Runbooks

Each session ends by writing one, into `runbooks/`, from
[`runbooks/_template.md`](runbooks/_template.md):

| Symptom | Tool | Cause | Fix | What would have told me this first |
|---|---|---|---|---|

These are the deliverable. The cluster gets destroyed; the runbooks do
not. Write them for the person you will be in January, on someone else's
platform, at the wrong hour.

---

## Before any session

```bash
cd ~/k8slab
git checkout feature/argo-and-observability-study
export KUBECONFIG=~/k8slab/kubernetes/admin.conf

kubectl get nodes                 # already up? then skip the next line
bash scripts/pipeline/main.sh     # ~20-30 min from nothing; choose 4) ArgoCD + Observability
```

**`main.sh` is the only script you run.** It builds the three VMs itself
as step 1/7. Running `lab-management.sh build` or `rebuild` first makes
`main.sh` abort — `build` refuses when lab VMs already exist and the
pipeline runs under `set -e`. To start over from VMs that are already up:
`./scripts/lab-management.sh destroy --force`, then `main.sh`.

Then confirm the ADR-035 premise actually holds — this is the first real
test of it:

```bash
kubectl describe node worker-1 | grep -A6 'Allocated resources'
kubectl get pods -A --field-selector=status.phase!=Running
```

Memory requests should sit near 3.5–4 Gi of the 8 Gi, and nothing should
be `Pending` or `OOMKilled`. If something is, that is session zero, and
`docs/decisions.md` ADR-035 is where the correction gets recorded.

## Repo layout this block touches

```
~/k8slab/                 everything for sessions 1–5
├── scripts/              infra-as-code — provisioning pipeline
├── kubernetes/           Helm values, the root Application
├── docs/decisions.md     ADR-001…035
├── workbook/             this path, its sessions and runbooks
└── gitops/               desired state — what ArgoCD syncs
~/openshift-local-lab/…   CRC, for session 6 only
```

**One repo, one branch, nothing to clone.** ArgoCD syncs `gitops/` out of
this repository on `feature/argo-and-observability-study`.

The `k8s-gitops` repo mentioned in `../docs/argocd-learning-path/` and in
`main`'s root Application has never been used — ignore it. Keeping
desired state next to infra-as-code is a deliberate simplification for
this block; on a real platform the split is worth arguing about, here it
would only mean a second clone to keep in sync.
