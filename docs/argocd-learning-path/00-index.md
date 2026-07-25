# ArgoCD: Zero to Hero — the full path

This is the complete, self-paced curriculum, written out end to end so
you can work through it without needing a check-in for every step.
Each tier is its own file. Work through them in order — later tiers
assume the file structure and Applications built in earlier ones.

## Branch policy — read this once, then forget about it

**Every file this path touches lives on `feature/argocd`, in both
`k8s-production-lab` and `k8s-gitops`, forever.** It is never merged
to `main`. `main` stays exactly what it is today — the clean,
recruiter-facing state of the lab. You never need to think about
merging, rebasing onto `main`, or keeping the two in sync. Just work
on `feature/argocd` in both repos, always.

The one file this affects mechanically:
`kubernetes/manifests/argocd/apps/root-app.yaml` has
`targetRevision: feature/argocd` (not `main`) for exactly this reason
— it's already set correctly, nothing to change.

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
git checkout feature/argocd           # both repos
cd ~/k8s-gitops && git checkout feature/argocd
```

If the cluster isn't up: `./scripts/lab-management.sh rebuild --force`,
then `bash scripts/pipeline/main.sh` and choose **ArgoCD** at the
prompt (RAM budget only fits one of Rancher/ArgoCD/Observability at a
time — some modules below call out when you need a different one
running instead, and how to work around that).

Access ArgoCD itself with `./scripts/tunnels/argocd-tunnel.sh`, then
`https://localhost:8444/`.
