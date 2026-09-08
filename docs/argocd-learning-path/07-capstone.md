# Capstone — a fleet shaped like a real client engagement

Unlike the earlier tiers, this isn't new infrastructure to build —
by the end of Tier 6 you already have four apps
(`hello-world-{dev,staging,prod}`, `podinfo`, `waved-demo`,
`ci-demo-app`) each demonstrating a different slice of production
GitOps. The capstone is where you step back, look at the fleet as a
whole the way a client would ask you to explain it, and close the two
gaps that only show up once you look at everything together.

---

## Part 1 — Audit the fleet

Fill in this table honestly from what's actually running, not from
memory of what you intended:

| App | AppProject-restricted (2.1) | RBAC-visible to `viewer` (2.2) | Sync wave / hook (3.1/3.2) | Custom health check (3.3) | Canary + analysis (3.4) | Secret via Sealed Secrets (4.1) | Notifications wired (5.1) |
|---|---|---|---|---|---|---|---|
| `hello-world-{dev,staging,prod}` | | | | | | | |
| `podinfo` | | | | | | | |
| `waved-demo` | | | | | | | |
| `ci-demo-app` | | | | | | | |

```bash
export KUBECONFIG=~/k8slab/kubernetes/admin.conf
kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,PROJECT:.spec.project,HEALTH:.status.health.status,SYNC:.status.sync.status
```

Every row should have gaps — that's expected and correct, not a
failure. Real fleets are uneven too: not every service gets a canary
strategy, not every service needs a custom health check. What matters
is that every gap is a *decision* you can name a reason for, not an
oversight.

## Part 2 — Close two gaps deliberately

**2a. Notify on a failed canary, not just a failed sync.** Tier 5.1
subscribed `waved-demo` to `on-sync-failed`/`on-health-degraded`.
`podinfo`'s canary (3.4) can abort mid-rollout without either of
those firing, since an aborted analysis isn't the same as a sync
failure. Subscribe `podinfo` to `on-health-degraded` too (edit
`apps/root/podinfo-app.yaml`, same annotation pattern as 5.1), then
force the canary to abort again (Tier 3.4's "trigger a bad rollout on
purpose" trick) and confirm the webhook actually fires this time.

**2b. Confirm `viewer` sees the whole project, not just what you
tested.** Tier 2.2 only verified `hello-world-dev`. Log in as
`viewer` and confirm `argocd app list` shows all four apps (they're
all in `lab-apps`) and `argocd app sync podinfo` is refused the same
way `hello-world-dev` was. If it isn't, that's a real finding — go
find out why before calling this done.

## Part 3 — Full-fleet failure drill

Tier 5.4's DR drill already covered the whole fleet by construction
(`argocd admin export` captures every Application in the namespace,
not just one) — rerun it now and confirm all four apps come back,
not just `waved-demo`:

```bash
argocd admin export --kubeconfig kubernetes/admin.conf > /tmp/full-fleet-backup.yaml
kubectl delete namespace argocd
kubectl create namespace argocd
helm upgrade --install argocd argo/argo-cd --version 10.1.4 --namespace argocd -f kubernetes/manifests/argocd/values.yaml
# regenerate argocd-tls + Gateway/HTTPRoute (06_argocd.sh steps 3-4)
argocd admin import --kubeconfig kubernetes/admin.conf < /tmp/full-fleet-backup.yaml
kubectl get applications -n argocd
```
All four apps, all `Synced`/`Healthy`, zero manual re-creation.

## Part 4 — Explain it

Write this up as if a client asked, in a first architecture review:
"walk me through how this is put together." Cover, in your own words:
- Why `root` is the only Application ever applied by hand, and what
  actually happens when you add a new app from here.
- What `lab-apps` does and doesn't allow, and why the boundary is
  where it is.
- What happens, concretely, if `podinfo`'s next deploy is bad.
- What you'd lose if the cluster disappeared right now versus what
  you'd lose if only the `argocd` namespace did.
- One thing in this fleet you'd change before actually using it for a
  client — because something genuinely would need to change (RAM
  aside), and knowing what separates a lab from production is as
  important as building the lab.

If you can answer all five without hedging, you're not studying
ArgoCD anymore. You're running it.
