# Tier 1 — Repo structure at scale

`k8s-gitops` today is one app, one environment, three flat YAML
files. By the end of this tier it's App-of-Apps-managed, split into
dev/staging/prod via Kustomize, includes a Helm-sourced app, and the
per-environment Applications are generated automatically instead of
hand-written. This is the tier that turns the repo from a demo into
something that looks like a real platform's GitOps repo.

Work through 1.1 → 1.4 in order — each one builds on the file layout
the previous one left behind.

---

## 1.1 — App-of-Apps

**Goal:** exactly one Application (`root`) is ever applied by hand.
Every other Application is a file in Git.

### Already done for you

This part is already scaffolded on `feature/argocd` in both repos —
you don't need to create these files, just apply them:

- `k8s-production-lab`: `kubernetes/manifests/argocd/apps/root-app.yaml`
  — the one Application you apply by hand, pointed at
  `k8s-gitops`'s `apps/root/`.
- `k8s-gitops`: `apps/root/hello-world-app.yaml` — hello-world's
  Application, now living here instead of being applied directly.

### The one concept that matters here

**ArgoCD only ever looks at what's on GitHub, never at your local
disk or local git branches.** `spec.source.repoURL` +
`targetRevision` is a URL and a branch name, fetched over the
network. `kubectl apply -f root-app.yaml`, by contrast, reads
straight off your local disk, right now, regardless of git state.
So: `k8s-gitops` must be pushed before ArgoCD can see `apps/root/`;
`k8s-production-lab` doesn't need to be pushed anywhere — you're just
running `kubectl apply` on a local file.

### Commands

```bash
# 1. Push the gitops repo's branch — ArgoCD fetches this over the network
cd ~/k8s-gitops
git push -u origin feature/argocd

# 2. Confirm it actually landed (open in a browser):
#    https://github.com/CarlosMBTeixeira/k8s-gitops/tree/feature/argocd/apps/root

# 3. Clear out the old, unmanaged hello-world Application.
#    Plain `kubectl delete` on an Application does NOT cascade to the
#    resources it manages unless a finalizer is set — yours isn't. So
#    this removes only the Application record; the nginx Deployment
#    keeps running untouched. (If you ever reach for `argocd app delete`
#    instead of kubectl, note it CASCADES by default — different tool,
#    different default, worth remembering before you point it at a
#    real client app.)
cd ~/k8slab
export KUBECONFIG=~/k8slab/kubernetes/admin.conf
kubectl delete application hello-world -n argocd
kubectl get all -n hello-world   # still there, still Running — confirm this before moving on

# 4. Apply the root Application — the only manual apply from here on
kubectl apply -f kubernetes/manifests/argocd/apps/root-app.yaml
```

### Verify

```bash
kubectl get applications -n argocd -w
```
Expect: `root` goes `Synced`/`Healthy`, then `hello-world` reappears
on its own — you never applied it, `root` created it.

```bash
kubectl get all -n hello-world
```
Same objects as before Step 3, and check the pod's `AGE` — if it's
not seconds-old, it was never recreated. You changed *who manages*
the app, not the app itself.

In the ArgoCD UI, click into **root**: its resource tree should
contain the **hello-world Application**, and clicking into that shows
the familiar Deployment/Service/Namespace. An Application managing an
Application, visible as a nested tree, is App-of-Apps made concrete.

**If `root` is stuck `Unknown` with a repository/comparison error:**
almost always the push in step 1 didn't happen, or a typo in
`targetRevision`. `kubectl describe application root -n argocd` shows
the exact error.

### Why this matters in client work

This is the standard bootstrap for any real fleet: one Application
applied by hand, ever. Everything else is Git history — which also
means "how do I add an app" has one correct answer for every
engineer on the team, not "however the last person happened to do it."

---

## 1.2 — Kustomize overlays for dev/staging/prod

**Goal:** `hello-world` runs in three environments from one shared
manifest tree, with one real difference per environment (replica
count, and prod gets resource limits dev/staging don't) — not just a
label.

### Files to create

Restructure `k8s-gitops/apps/hello-world/`:

```
apps/hello-world/
├── base/
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   └── service.yaml
└── overlays/
    ├── dev/
    │   ├── kustomization.yaml
    │   ├── namespace.yaml
    │   └── deployment-patch.yaml
    ├── staging/
    │   ├── kustomization.yaml
    │   ├── namespace.yaml
    │   └── deployment-patch.yaml
    └── prod/
        ├── kustomization.yaml
        ├── namespace.yaml
        └── deployment-patch.yaml
```

`git mv` the existing files into `base/` first, then strip the
`namespace:` field out of each — the base shouldn't know which
environment it'll land in, that's the overlay's job:

```bash
cd ~/k8s-gitops
mkdir -p apps/hello-world/base
git mv apps/hello-world/deployment.yaml apps/hello-world/base/deployment.yaml
git mv apps/hello-world/service.yaml apps/hello-world/base/service.yaml
git rm apps/hello-world/namespace.yaml   # replaced by a per-overlay namespace.yaml below
```

Edit `base/deployment.yaml` and `base/service.yaml` to remove their
`metadata.namespace: hello-world` line (everything else stays the
same as what's already there).

**`apps/hello-world/base/kustomization.yaml`**
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
```

**`apps/hello-world/overlays/dev/namespace.yaml`**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: hello-world-dev
```

**`apps/hello-world/overlays/dev/deployment-patch.yaml`**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-world
spec:
  replicas: 1
```

**`apps/hello-world/overlays/dev/kustomization.yaml`**
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: hello-world-dev
resources:
  - ../../base
  - namespace.yaml
patches:
  - path: deployment-patch.yaml
```

Repeat for `staging/` (same shape, `namespace: hello-world-staging`,
`replicas: 2`) and `prod/` (`namespace: hello-world-prod`,
`replicas: 3`, plus this time a real second difference —
`prod/deployment-patch.yaml` also sets resources, since prod is the
one environment you actually want protected from a runaway container):

**`apps/hello-world/overlays/prod/deployment-patch.yaml`**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-world
spec:
  replicas: 3
  template:
    spec:
      containers:
        - name: hello-world
          resources:
            requests:
              cpu: 25m
              memory: 32Mi
            limits:
              cpu: 100m
              memory: 64Mi
```

Now replace the single `apps/root/hello-world-app.yaml` from 1.1 with
three environment-specific Applications:

**`apps/root/hello-world-dev-app.yaml`**
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: hello-world-dev
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/CarlosMBTeixeira/k8s-gitops.git
    targetRevision: feature/argocd
    path: apps/hello-world/overlays/dev
  destination:
    server: https://kubernetes.default.svc
    namespace: hello-world-dev
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```
Same shape for `hello-world-staging-app.yaml` and
`hello-world-prod-app.yaml` — swap `dev` for `staging`/`prod`
throughout (name, path, destination namespace).

```bash
git rm apps/root/hello-world-app.yaml
```

### Commands

```bash
cd ~/k8s-gitops
git add -A
git commit -m "Split hello-world into base + dev/staging/prod overlays"
git push

cd ~/k8slab
export KUBECONFIG=~/k8slab/kubernetes/admin.conf
kubectl get applications -n argocd -w
```

### Verify

Expect `root` to sync, delete the single old `hello-world`
Application (it's no longer in `apps/root/`), and create
`hello-world-dev`, `hello-world-staging`, `hello-world-prod` —
all `Synced`/`Healthy`.

```bash
kubectl get deploy -n hello-world-dev -o jsonpath='{.items[0].spec.replicas}'      # 1
kubectl get deploy -n hello-world-staging -o jsonpath='{.items[0].spec.replicas}'  # 2
kubectl get deploy -n hello-world-prod -o jsonpath='{.items[0].spec.replicas}'     # 3
kubectl get deploy -n hello-world-prod -o jsonpath='{.items[0].spec.template.spec.containers[0].resources}'
# {"limits":{"cpu":"100m","memory":"64Mi"},"requests":{"cpu":"25m","memory":"32Mi"}}
```

The old `hello-world` namespace from 1.1 is now orphaned — nothing
manages it anymore, and ArgoCD doesn't prune namespaces it never
created directly. Clean it up once the three new ones are confirmed
healthy:

```bash
kubectl delete namespace hello-world
```

### Why this matters in client work

This is the actual promotion model most platforms use: same manifest
tree, environment-specific patches, a diff in a pull request you can
review before it reaches prod — not three copy-pasted YAML trees that
quietly drift apart over six months.

---

## 1.3 — Helm as a source type

**Goal:** a second app, `podinfo`, deployed straight from a public
Helm chart — the other half of how real platforms source apps
(raw/Kustomize for internal services, Helm for anything vendored),
matching the install policy this lab already runs for infrastructure
(ADR-030).

`podinfo` is the de facto demo app for exactly this kind of exercise
— small, well-documented, and you'll reuse it again in Tier 3 for
canary rollouts, so this isn't a throwaway.

### Files to create

**`apps/root/podinfo-app.yaml`** (in `k8s-gitops`)
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: podinfo
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://stefanprodan.github.io/podinfo
    chart: podinfo
    targetRevision: "6.7.*"
    helm:
      values: |
        replicaCount: 2
        resources:
          requests:
            cpu: 25m
            memory: 32Mi
          limits:
            cpu: 100m
            memory: 64Mi
  destination:
    server: https://kubernetes.default.svc
    namespace: podinfo
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true   # the podinfo chart doesn't ship its own Namespace
```

Note what's different from every Application so far:
`source.repoURL` here is a **Helm chart repository**, not a Git repo
— so there's a `chart:` field instead of `path:`, and
`helm.values` carries the override inline instead of a values file
living in Git. `CreateNamespace=true` exists because, unlike
`hello-world`, this chart doesn't ship its own `Namespace` manifest —
a small but common gap between "raw manifests you write" and "a
vendor's chart," worth hitting once deliberately.

### Commands

```bash
cd ~/k8s-gitops
git add apps/root/podinfo-app.yaml
git commit -m "Add podinfo via Helm chart source"
git push
```

### Verify

```bash
kubectl get application podinfo -n argocd    # Synced, Healthy
kubectl get pods -n podinfo                  # 2 podinfo pods running
```

### Why this matters in client work

Most client platforms mix both source types — Kustomize/raw for
internal apps the team owns, Helm for anything sourced from a vendor
or Artifact Hub. Being fluent in both, in the same repo, is the norm,
not a choice you make once.

---

## 1.4 — ApplicationSets: the git generator

**Goal:** the three hand-written `hello-world-{dev,staging,prod}`
Applications from 1.2 are replaced by one `ApplicationSet` that
generates them from the overlay directories automatically. Add a
fourth environment later and no ArgoCD manifest changes at all — just
a new folder.

### Files to create

**`apps/root/hello-world-appset.yaml`** (in `k8s-gitops`)
```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: hello-world
  namespace: argocd
spec:
  generators:
    - git:
        repoURL: https://github.com/CarlosMBTeixeira/k8s-gitops.git
        revision: feature/argocd
        directories:
          - path: apps/hello-world/overlays/*
  template:
    metadata:
      name: 'hello-world-{{path.basename}}'
      namespace: argocd
    spec:
      project: default
      source:
        repoURL: https://github.com/CarlosMBTeixeira/k8s-gitops.git
        targetRevision: feature/argocd
        path: '{{path}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: 'hello-world-{{path.basename}}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
```

`{{path.basename}}` is the generator's template variable for "the
last segment of the matched directory path" — `dev`, `staging`, or
`prod` — which is exactly how the Application names and destination
namespaces already work, so nothing downstream changes.

Remove the three Applications this replaces:
```bash
git rm apps/root/hello-world-dev-app.yaml apps/root/hello-world-staging-app.yaml apps/root/hello-world-prod-app.yaml
```

### Commands

```bash
cd ~/k8s-gitops
git add -A
git commit -m "Replace per-env hello-world Applications with an ApplicationSet"
git push
```

### Verify

```bash
kubectl get applicationset hello-world -n argocd
kubectl get applications -n argocd -l argocd.argoproj.io/application-set-name=hello-world
```
Expect the same three `hello-world-dev/staging/prod` Applications as
before, `Synced`/`Healthy` — now owned by the ApplicationSet instead
of hand-written files. Confirm nothing actually changed in the
cluster (same deployments, same replica counts) — this step changes
*how the Applications are generated*, not what they deploy.

**Try it for real:** add a fourth overlay directory (copy `prod/` to
`overlays/canary/`, tweak the namespace name and replica count),
push, and watch a fourth Application appear with zero ArgoCD-side
changes.

### Why this matters in client work

This is how a platform team supports dozens of services without
maintaining one Application YAML per service per environment by
hand — the directory structure *is* the source of truth for what
exists. It's also usually the first thing that breaks people's mental
model coming from Tier 0/1.1-1.3's one-Application-per-thing approach
— worth sitting with until the `{{path.basename}}` templating feels
obvious rather than magic.

---

**Tier 1 done.** State at this point: `root` App-of-Apps manages an
ApplicationSet (`hello-world`, 3 generated env Applications) and one
Helm-sourced Application (`podinfo`). Next: [Tier 2 — access
control](02-access-control.md).
