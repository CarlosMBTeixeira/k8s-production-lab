# Tier 1.1 walkthrough — App-of-Apps, step by step

This is the hands-on half of the change already scaffolded on
`feature/argocd`. The scaffolding (file moves, new manifests, README
updates) is committed in both repos. Everything below — pushing,
applying, watching it sync, verifying nothing broke — is yours to
drive. That's deliberate: reading a diff doesn't teach you how ArgoCD
behaves, watching it react does.

Budget about 30-40 minutes, most of it watching things happen rather
than typing.

## What you're about to change, in one picture

**Before (Tier 0):**
```
kubectl apply -f hello-world-app.yaml   (you, by hand)
        │
        ▼
Application "hello-world"  ──manages──▶  Deployment/Service/Namespace
(created directly, owned by nothing)
```

**After (Tier 1.1):**
```
kubectl apply -f root-app.yaml          (you, by hand — only ever this one)
        │
        ▼
Application "root"  ──manages──▶  Application "hello-world"  ──manages──▶  Deployment/Service/Namespace
(defined in k8s-production-lab)   (now defined in k8s-gitops/apps/root/,
                                    not applied by hand anymore)
```

From this point on, adding a second app means committing a new file to
`k8s-gitops/apps/root/` — never a new `kubectl apply` in this repo.

## The one concept that trips people up here

**ArgoCD only ever looks at what's on GitHub, never at your local
disk or local git branches.** Every `Application` object has a
`spec.source.repoURL` + `spec.source.targetRevision` — that's a URL
and a branch/tag name, fetched over the network. Your laptop's
`git checkout feature/argocd` means nothing to ArgoCD.

`kubectl apply -f root-app.yaml`, on the other hand, reads straight
off your local disk, right now, regardless of what branch that file
is committed to or whether it's committed at all.

So the two repos behave differently in this walkthrough:
- **`k8s-gitops` must be pushed to GitHub** before ArgoCD can see the
  new `apps/root/` folder — ArgoCD fetches this repo remotely.
- **`k8s-production-lab` does not need to be pushed anywhere yet** —
  you're just running `kubectl apply` on a file sitting on your disk.

---

## Step 0 — Confirm you're where you think you are

```bash
cd ~/k8slab && git status        # expect: On branch feature/argocd, clean
cd ~/k8s-gitops && git status    # expect: On branch feature/argocd, clean
```

Look at what's actually different before you touch anything:

```bash
cd ~/k8slab && git show HEAD --stat
cd ~/k8s-gitops && git show HEAD --stat
```

You should see: the lab repo renamed `hello-world-app.yaml` →
`root-app.yaml` and changed its `metadata.name`/`spec.source.path`;
the gitops repo added `apps/root/hello-world-app.yaml` and updated its
README.

## Step 1 — Make sure the lab is actually up

This lab is destroyed and rebuilt every session (see the README) —
there may be nothing running right now.

```bash
cd ~/k8slab
export KUBECONFIG=~/k8slab/kubernetes/admin.conf
kubectl get nodes
```

- **If that fails** (no route, connection refused): the VMs aren't
  up. Run `./scripts/lab-management.sh rebuild --force`, then
  `bash scripts/pipeline/main.sh` and choose **ArgoCD** at the prompt
  (remember: only one of Rancher/ArgoCD/Observability fits the RAM
  budget at once — ADR-031).
- **If nodes come back but you're not sure ArgoCD itself is healthy**:
  `bash scripts/morning-check.sh`, and `kubectl get pods -n argocd`
  (everything should be `Running`).

Also open the UI now so you can watch things happen visually as you
go, not just via `kubectl`:

```bash
./scripts/tunnels/argocd-tunnel.sh
```

Leave that running in its own terminal, then browse to
`https://localhost:8444/` (accept the self-signed cert warning),
log in as `admin` with the password you set at install time.

## Step 2 — Push the gitops repo's branch to GitHub

```bash
cd ~/k8s-gitops
git push -u origin feature/argocd
```

Confirm it actually landed: open
`https://github.com/CarlosMBTeixeira/k8s-gitops/tree/feature/argocd/apps/root`
in a browser and check `hello-world-app.yaml` is there. If you don't
see it, ArgoCD won't either — stop here and fix the push before
continuing.

## Step 3 — Point the root Application at your branch, not `main`, for now

`root-app.yaml` currently has `targetRevision: main` — but `main` on
`k8s-gitops` doesn't have `apps/root/` yet (only your branch does).
Point it at the branch instead, so you can verify the whole thing
safely before either repo's `main` is touched:

```bash
cd ~/k8slab
```

Open `kubernetes/manifests/argocd/apps/root-app.yaml` and change:

```yaml
spec:
  source:
    targetRevision: main
```

to:

```yaml
spec:
  source:
    targetRevision: feature/argocd
```

Commit that as its own small commit — you'll want a clean record of
"this was a temporary testing pointer" to revert later:

```bash
git add kubernetes/manifests/argocd/apps/root-app.yaml
git commit -m "test: point root Application at feature/argocd for local verification"
```

This is a real pattern, not a lab-only trick: testing an unmerged
GitOps change by pointing `targetRevision` at your branch, then
flipping it back to `main` right before merging, is how you'd safely
validate this kind of restructuring against a real client cluster too.

## Step 4 — Remove the old, unmanaged `hello-world` Application

Right now `hello-world` exists as an Application nobody manages —
you `kubectl apply`'d it directly back in Tier 0. `root` is about to
try to create an Application with the exact same name. Clear the old
one out of the way first.

**Read this carefully before running anything** — the way you delete
an ArgoCD Application controls whether your running nginx pods
survive:

```bash
kubectl delete application hello-world -n argocd
```

Plain `kubectl delete` on the Application object does **not** cascade
to the resources it manages (the Deployment/Service/Namespace) unless
a finalizer was configured — and yours wasn't. So this removes only
the Application *record*; the nginx Deployment keeps running,
untouched, in the `hello-world` namespace. Confirm that:

```bash
kubectl get all -n hello-world
# still shows the nginx deployment/service, still Running
```

If you'd used `argocd app delete hello-world` (the CLI, not
`kubectl`) instead, note for future reference: that command cascades
and deletes the running resources **by default**. Worth knowing before
you reach for it against a real client app.

## Step 5 — Apply the root Application

```bash
kubectl apply -f kubernetes/manifests/argocd/apps/root-app.yaml
```

This is the only manual `kubectl apply` in this whole workflow from
now on.

## Step 6 — Watch it sync

```bash
kubectl get applications -n argocd -w
```

Expected sequence over the next ~30-60 seconds:
1. `root` appears, `Unknown`/`Progressing` → `Synced`/`Healthy`.
2. `hello-world` reappears on its own (root created it — you never
   applied it) → `Synced`/`Healthy`.

Ctrl+C once both are `Synced`/`Healthy`. Then double-check the
running app was never actually disrupted:

```bash
kubectl get all -n hello-world
```

Compare against what you saw in Step 4 — same objects, and check
`AGE` on the pod: if it's old (not seconds-old), it was never
recreated, which is the point — you changed *who manages* the app,
not the app itself.

In the ArgoCD UI, click into **root**: you should see its own
resource tree contains the `hello-world` **Application**, and
clicking into that shows the familiar Deployment/Service/Namespace.
That nested tree — an Application managing an Application — is the
App-of-Apps pattern made visible.

### If something's stuck

- **`root` stuck `Unknown` with a comparison/repository error**: almost
  always means the push in Step 2 didn't actually happen, or
  `targetRevision` doesn't exactly match the branch name. Check
  `kubectl describe application root -n argocd` for the exact error.
- **Cert warnings in the UI**: this lab has a known issue where VM
  clocks drift under host CPU pressure and break TLS validation. Try
  `bash scripts/fix-vm-clocks.sh` if a cert suddenly looks
  "not yet valid."
- **You cascade-deleted `hello-world` by accident**: nothing is
  actually lost — the manifests are still in Git. Just re-apply
  `root-app.yaml`; ArgoCD will recreate everything from source. This
  is the entire point of GitOps: the cluster is disposable, Git isn't.

## Step 7 — When you're satisfied, decide what "done" means for you

You don't have to merge to `main` right now — the whole point of
working on `feature/argocd` was to let you keep building (Tier 1.2's
Kustomize overlays are a natural next step on this same branch)
before merging anything. Two honest options:

- **Keep iterating on the branch.** Leave `targetRevision:
  feature/argocd` as-is and move on to the next module. Nothing more
  to do right now.
- **Merge this piece to `main` now.** If you'd rather close out 1.1
  cleanly before starting 1.2:
  1. Flip `root-app.yaml`'s `targetRevision` back to `main` and
     commit that.
  2. Merge `feature/argocd` → `main` in **both** repos and push.
  3. `kubectl apply -f kubernetes/manifests/argocd/apps/root-app.yaml`
     once more, and re-run the Step 6 checks against `main` this time.

Either way, nothing here was destructive — the running app was never
taken down, and every step so far is easy to re-run if you want to
redo it slower or re-verify something.

---

**Next up:** Tier 1.2 (Kustomize overlays for dev/staging/prod) —
ask when you're ready and I'll scaffold it the same way: files
committed to `feature/argocd`, the actual `kubectl`/`argocd` work left
for you to run and watch.
