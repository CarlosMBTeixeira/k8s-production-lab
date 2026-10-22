# ArgoCD: Zero to Hero — the full path

This is the complete, self-paced curriculum, written out end to end so
you can work through it without needing a check-in for every step.
Each tier is its own file. Work through them in order — later tiers
assume the file structure and Applications built in earlier ones.

## Branch policy — read this once, then forget about it

> **Superseded by ADR-037 (2026-10-22).** The original policy here was
> that this path lived on `feature/argocd` forever, never merged, so
> `main` stayed a clean showcase. That is no longer the rule: **`main`
> is the single source of truth** and holds the most up-to-date state
> of the lab, including study material. Feature branches are short-lived
> and get merged back.

What that means for this path:

- Work from `main` in `k8s-production-lab`. `feature/argocd` is
  historical, already merged (PR #1).
- `kubernetes/manifests/argocd/apps/root-app.yaml` points at **this
  repo**, `targetRevision: main`, `path: gitops/apps/root`, not at
  `k8s-gitops`.
- The separate `k8s-gitops` repo that the tier files below refer to was
  never used. Wherever a tier says `~/k8s-gitops/<path>`, read
  `~/k8slab/gitops/<path>`.

## How this path is organized

| File | Tier | What it covers |
|---|---|---|
| [01-repo-structure.md](01-repo-structure.md) | 1 | App-of-Apps, Kustomize overlays (dev/staging/prod), Helm as a source, ApplicationSets |
| [02-access-control.md](02-access-control.md) | 2 | AppProjects, RBAC, SSO |
| [03-deployment-orchestration.md](03-deployment-orchestration.md) | 3 | Sync waves, resource hooks, custom health checks, Argo Rollouts (canary) |
| [04-securing-pipeline.md](04-securing-pipeline.md) | 4 | Sealed Secrets, private repo auth, image automation |
| [05-operating-argocd.md](05-operating-argocd.md) | 5 | Notifications, monitoring ArgoCD itself, HA reasoning, disaster recovery |
| [06-multicluster-as-code.md](06-multicluster-as-code.md) | 6 | Second cluster, ApplicationSet cluster generator, ArgoCD-as-code |
| [07-capstone.md](07-capstone.md) | — | Bring it all together on one small fleet |
| [youtube_course.md](youtube_course.md) | — | Companion video course, watched alongside these tiers |

**Tier 0 isn't a file** — it's what you'd already done before this
path started: Helm install via Artifact Hub, Gateway API exposure,
first Application, manual sync, auto-sync + selfHeal proven against
live drift, rollback via `git revert`. Nothing to redo.

## How to read each module

Every module in every tier follows the same shape:

- **Goal** — one line, what exists at the end that didn't before.
- **Files to create/change** — exact paths and exact YAML. Create
  these yourself, in your own editor — typing them is part of how
  this sticks.
- **Commands** — exact `kubectl`/`git`/`argocd`/`helm` invocations,
  in order.
- **Verify** — what to check, and what "correct" looks like, so you
  know you're done before moving on.
- **Why this matters in client work** — the production reasoning
  behind the exercise, not just the mechanics.

I'm not going to pre-create these files for you tier by tier — that
was the confusing part last time. This path is documentation only
from here. You drive the `kubectl apply`s, the `git commit`s, the
`helm install`s. Ask whenever a step doesn't behave the way its
"Verify" section says it should — that's the useful moment to dig in
together, not a sign something's wrong with you.

## Before you start any session

```bash
cd ~/k8slab
export KUBECONFIG=~/k8slab/kubernetes/admin.conf
kubectl get nodes                     # cluster up?
git checkout main && git pull         # one repo, one branch (ADR-037)
```

If the cluster isn't up: `bash scripts/pipeline/main.sh` (it builds the
VMs itself; if old VMs exist, `./scripts/lab-management.sh destroy
--force` first). Choose **ArgoCD** at the application prompt, or
**ArgoCD + Observability** on the 1-worker topology (ADR-035/036).

Access ArgoCD itself with `./scripts/tunnels/argocd-tunnel.sh`, then
`https://localhost:8444/`.
