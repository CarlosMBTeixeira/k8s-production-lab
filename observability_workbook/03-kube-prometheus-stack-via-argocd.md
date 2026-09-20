# Session 3 — `kube-prometheus-stack` installed *by* ArgoCD

**Objective:** move an existing Helm release under ArgoCD's control
without reinstalling it from scratch, and meet the two failure modes that
only appear when a Helm chart is large.

Short session. The chart is already familiar — the only new surface is
the wrapper and what breaks at scale.

**Prerequisites:** session 2 complete; `~/k8slab/gitops/` on `feature/argocd`.

**Read first:** ArgoCD *User Guide* → "Helm" and "Sync Options".

---

## 3.1 — The wrapper

An `Application` whose source is a Helm repository rather than a git
path. Note `targetRevision` now means *chart version*, not a git ref —
the same field carrying a different meaning depending on source type,
which is a genuine trap when reading someone else's manifests.

`~/k8slab/gitops/apps/root/kube-prometheus-stack.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kube-prometheus-stack
  namespace: argocd
spec:
  project: default
  sources:
    - repoURL: https://prometheus-community.github.io/helm-charts
      chart: kube-prometheus-stack
      targetRevision: 87.17.0          # chart version, NOT a git ref
      helm:
        valueFiles:
          - $values/gitops/observability/kps-values.yaml
    - repoURL: https://github.com/CarlosMBTeixeira/k8s-production-lab.git
      targetRevision: feature/argo-and-observability-study
      ref: values                      # makes $values resolvable above
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
```

The two-source shape is the interesting part: chart from upstream, values
from your repo. It is how you version chart and configuration
independently, and it is what a platform team actually runs.

Copy the existing values across, minus the secret:

```bash
cp ~/k8slab/kubernetes/manifests/observability/values.yaml \
   ~/k8slab/gitops/observability/kps-values.yaml
```

**The admin password cannot come with it.** `07_observability.sh` prompts
for it and writes it to a temp file precisely so it is never committed.
Under GitOps it has to live somewhere the cluster can read and git
cannot — which is the problem session 5 solves with External Secrets. For
now, let the chart generate one and read it back:

```bash
kubectl -n monitoring get secret kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

> **Hypothesis.** This is the first thing in the workbook that GitOps
> makes *harder* rather than easier.
>
> **Expected if right.** It is. A push pipeline reads a CI variable at
> apply time; a pull controller has no such context. Every GitOps secret
> story (Sealed Secrets, ESO, SOPS) exists because of exactly this gap.
>
> **What would have caught this sooner.** Asking "where does the
> pipeline get its secrets from, and does the controller have that?"
> before starting the migration.

---

## 3.2 — Taking over a live Helm release

The release already exists, installed by `07_observability.sh`. Two
routes, and the choice is the lesson.

```bash
helm -n monitoring list
helm -n monitoring uninstall kube-prometheus-stack     # route A
```

> **Hypothesis.** `helm uninstall` leaves the CRDs behind, so the
> Prometheus/Alertmanager/ServiceMonitor CRs survive the uninstall and
> ArgoCD adopts a namespace that is not actually empty.
>
> **Tool.**
> ```bash
> kubectl get crd | grep monitoring.coreos.com
> kubectl -n monitoring get prometheus,alertmanager,servicemonitor
> ```
>
> **Expected if right.** CRDs are still there. Helm installs everything
> in a chart's `crds/` directory but **never** deletes it on uninstall —
> deliberate, because deleting a CRD deletes every CR of that kind
> cluster-wide. The custom *resources* go with the release; the
> *definitions* stay.
>
> **What would have caught this sooner.** `helm uninstall`'s own output,
> which says so. And the general rule: if a CRD outlives its chart, an
> "uninstall then reinstall" is never a clean-room test.

Route B — adopt in place, without uninstalling — is what you would do on
a platform you cannot take down. ArgoCD will claim resources it did not
create as long as they match; the Helm release metadata simply becomes
stale. Worth understanding, not worth practising on a lab you rebuild
nightly. **Note which route you took in the runbook**, because on a real
migration the answer is never route A.

Commit, push, wait for the root Application to adopt it.

---

## 3.3 — The annotation-size wall

This is the failure everyone meets exactly once with this chart.

> **Hypothesis.** Without `ServerSideApply=true`, the sync fails on the
> CRDs with an error about annotations being too long.
>
> **Tool.** Remove the `syncOptions` block, commit, sync, and read the
> error:
> ```bash
> kubectl -n argocd get application kube-prometheus-stack \
>   -o jsonpath='{.status.operationState.message}{"\n"}'
> ```
>
> **Expected if right.** `metadata.annotations: Too long: must have at
> most 262144 bytes`. Client-side apply stores the entire previous object
> in the `kubectl.kubernetes.io/last-applied-configuration` annotation,
> and this chart's CRDs are far larger than the 256 KB limit on
> annotation values. Server-side apply tracks field ownership in
> `metadata.managedFields` instead, so no such annotation exists.
>
> **What would have caught this sooner.** The size of the object:
> `kubectl get crd prometheuses.monitoring.coreos.com -o yaml | wc -c`.
> Any CRD near or past 256 KB will hit this under client-side apply, and
> knowing *why* means you recognise it instantly on any large chart —
> Istio, Crossplane, Gatekeeper all do this.

Put `ServerSideApply=true` back and confirm the sync completes.

---

## 3.4 — Does ArgoCD fight the chart?

> **Hypothesis.** Helm charts that generate a value on each render
> (passwords, certificates, random suffixes) make an Application
> permanently `OutOfSync`, because every refresh renders something new.
>
> **Tool.** Let it settle, then:
> ```bash
> kubectl -n argocd get application kube-prometheus-stack \
>   -o jsonpath='{.status.sync.status}{"\n"}'
> argocd app diff kube-prometheus-stack        # if the CLI is installed
> ```
>
> **Expected if right.** Either stably `Synced`, or a recurring diff on a
> generated field. If you see the latter, you have found the reason
> `ignoreDifferences` exists — and the reason `selfHeal` plus a
> self-generating chart can become a hot loop that rewrites a Secret
> every few seconds.
>
> **What would have caught this sooner.** Asking which fields the chart
> generates rather than templates. `helm template` twice and diff the
> output — anything that differs between two renders of identical inputs
> will never be stably `Synced`.

---

## Done-criteria

- [ ] `kube-prometheus-stack` `Synced`/`Healthy`, managed by an Application, values from the `gitops/` tree.
- [ ] Grafana and Prometheus still working, reachable through the same tunnels, with session 2's dashboard and alert intact.
- [ ] The annotation-size error reproduced deliberately and explained.
- [ ] A written answer to: where does the Grafana admin password live now, and why is that unsatisfactory?
- [ ] `runbooks/03-kube-prometheus-stack-via-argocd.md` written.

## Runbook seeds

| Symptom | Tool | Cause | Fix | What would have told me this first |
|---|---|---|---|---|
| Sync fails, "annotations: Too long" | `.status.operationState.message` | Client-side apply on a >256 KB CRD | `ServerSideApply=true` | Object size vs. the annotation limit |
| CRs gone, CRDs remain after uninstall | `kubectl get crd` | Helm never deletes CRDs | Expected; delete explicitly if you mean it | `helm uninstall` output |
| Permanently `OutOfSync`, no one changed anything | `argocd app diff` | Chart generates a value per render | `ignoreDifferences` | `helm template` twice, diff |
| `targetRevision` "branch not found" | Application spec | It means chart version for Helm sources | Use the chart version | The field means two different things |
