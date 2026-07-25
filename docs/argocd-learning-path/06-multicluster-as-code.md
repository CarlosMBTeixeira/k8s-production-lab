# Tier 6 — Multi-cluster & ArgoCD-as-code

Most real ArgoCD installs are a hub managing several spoke clusters,
and the installation itself — RBAC, AppProjects, repo credentials —
is deployed from Git wherever that's actually possible. This tier
closes both gaps, and is honest about the one piece that can't be
closed (and why that's fine).

---

## 6.1 — Register a second cluster

**Goal:** a second, independent cluster registered as an ArgoCD
destination alongside your kubeadm cluster.

> **Why this isn't a k3d/kind sandbox in WSL2**, unlike the
> throwaway clusters suggested for Tiers 3.4/5.2: those were
> self-contained (everything they needed ran *inside* that one
> cluster). This exercise needs the **same ArgoCD control plane**,
> which lives inside your Multipass fleet, to reach a second live
> cluster over the network. A k3d cluster on WSL2's Docker network is
> a different L3 network than the Multipass bridge — exactly the
> class of NAT/routing wall ADR-029 already fought once. A second
> lightweight Multipass VM, on the same bridge as your existing 4
> nodes, sidesteps that entirely by reusing networking you've already
> proven works.
>
> This does cost real RAM on top of whatever's already running —
> treat this as a short, deliberate exercise, and tear the VM down
> (last step below) once you're done with 6.1-6.3, not something left
> running indefinitely.

### Commands

```bash
# A single-node k3s VM — much lighter than another kubeadm HA cluster,
# same bridge network as cp-1/cp-2/w-1/w-2.
multipass launch --name spoke1 --cpus 2 --memory 2G --disk 10G 22.04
multipass exec spoke1 -- bash -c "curl -sfL https://get.k3s.io | sh -"

SPOKE_IP=$(multipass info spoke1 | awk '/IPv4/{print $2}')
multipass exec spoke1 -- sudo cat /etc/rancher/k3s/k3s.yaml | \
  sed "s/127.0.0.1/${SPOKE_IP}/" > /tmp/spoke1-kubeconfig

# Merge it with the lab's kubeconfig so both contexts are visible to one CLI
KUBECONFIG=~/k8slab/kubernetes/admin.conf:/tmp/spoke1-kubeconfig kubectl config view --flatten > /tmp/merged-kubeconfig
export KUBECONFIG=/tmp/merged-kubeconfig
kubectl config get-contexts
# rename if k3s's default context name collides with anything: kubectl config rename-context default spoke1

argocd login localhost:8444 --insecure --grpc-web   # if not already logged in
argocd cluster add spoke1   # or whatever the context is named after the rename above
```

### Verify

```bash
argocd cluster list
```
`spoke1` should appear alongside `https://kubernetes.default.svc`
(your existing lab cluster, referenced from inside itself). Note the
`server` URL `argocd cluster add` prints for `spoke1` — you'll need
it in 6.2.

### Why this matters in client work

Hub-and-spoke is the default multi-cluster topology in practice — one
ArgoCD control plane, several managed clusters. It's the shape you'll
meet at most clients running more than a single environment cluster.

---

## 6.2 — ApplicationSet cluster generator

**Goal:** the same `hello-world` dev overlay from Tier 1.2, deployed
to **both** clusters from one ApplicationSet — not a second
hand-copied Application.

### Files to change

First, let `lab-apps` allow deploying to the new cluster — edit
`apps/root/lab-apps-project.yaml`, add under `destinations:`
(use the exact `server` value `argocd cluster list` printed for
`spoke1`):
```yaml
    - server: https://<spoke1-server-from-argocd-cluster-list>
      namespace: hello-world-dev
```

**`apps/root/hello-world-fleet-appset.yaml`** (new file)
```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: hello-world-fleet
  namespace: argocd
spec:
  generators:
    - clusters: {}
  template:
    metadata:
      name: 'hello-world-dev-{{name}}'
      namespace: argocd
    spec:
      project: lab-apps
      source:
        repoURL: git@github.com:CarlosMBTeixeira/k8s-gitops.git
        targetRevision: feature/argocd
        path: apps/hello-world/overlays/dev
      destination:
        server: '{{server}}'
        namespace: hello-world-dev
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
```

`clusters: {}` with no filter generates one Application per cluster
ArgoCD knows about — right now that's the local lab cluster and
`spoke1`. `{{name}}`/`{{server}}` are the generator's built-in
template variables, filled in per cluster. Note this deploys the
exact same overlay from Tier 1.2, completely unmodified — the whole
point of this pattern is that the app doesn't need to know it's being
deployed twice.

### Commands

```bash
cd ~/k8s-gitops
git add -A && git commit -m "Add hello-world-fleet ApplicationSet across both clusters" && git push
```

### Verify

```bash
export KUBECONFIG=/tmp/merged-kubeconfig
kubectl get applications -n argocd -l argocd.argoproj.io/application-set-name=hello-world-fleet
```
Two Applications, one per cluster, both `Synced`/`Healthy`.
```bash
kubectl --context spoke1 get pods -n hello-world-dev
```
The nginx pod running on the *second* cluster, deployed without ever
`kubectl apply`-ing anything there directly.

### Why this matters in client work

This is the pattern that scales a platform team past "one engineer
babysitting one cluster" — a fleet-wide change (a new environment, a
new cluster) becomes one commit, not N manual Applications.

---

## 6.3 — ArgoCD-as-code: what can (and can't) manage itself

**Goal:** understand precisely which pieces of your ArgoCD setup are
already self-healing from Git — more than you might think — and
which ones structurally can't be, so you can reason about this
correctly instead of assuming "put it in Git" fixes everything.

### Part 1 — prove what already self-heals (it's more than you'd guess)

`root` has had `selfHeal: true` since Tier 1.1, and it manages
*everything* under `apps/root/` — including the `lab-apps`
AppProject, not just Applications:

```bash
export KUBECONFIG=~/k8slab/kubernetes/admin.conf
kubectl delete appproject lab-apps -n argocd
kubectl get appproject lab-apps -n argocd -w
```
Watch it reappear within `root`'s next reconcile (~15-30s) — you
already built self-healing AppProjects back in Tier 2.1, it just
wasn't obvious that's what `root` managing `apps/root/*.yaml` also
covered.

### Part 2 — the boundary that genuinely can't self-heal, and why

Try to reason about `argocd-rbac-cm` (Tier 2.2) the same way before
reading on: it's committed to `values.yaml` in Git, so is it
self-healing too?

**No** — and the reason is structural, not a gap you can close by
trying harder. `argocd-rbac-cm` is rendered and applied by the
**Helm chart's own `helm upgrade`**, a command you run from outside
ArgoCD. ArgoCD only self-heals resources *it* is managing as part of
an Application's sync — and the Helm release that installs ArgoCD
itself isn't an Application ArgoCD is watching (nothing is managing
ArgoCD's own installation from inside ArgoCD, by default). Same logic
applies to the repo-credential Secret from 4.2, and to `root-app.yaml`
itself: each of these has to be bootstrapped from outside the loop,
because each one is a prerequisite for the loop existing at all — you
can't fetch the credential that unlocks a Git repo *from* that same
Git repo.

So the honest inventory, at the end of this path:
- **Self-healing today:** every Application, ApplicationSet, and
  AppProject under `apps/root/` — the actual application fleet.
- **Git-tracked but not self-healing:** `argocd-rbac-cm`,
  `notifications` config, ArgoCD's own metrics/serviceMonitor
  settings — all in `values.yaml`, applied by `helm upgrade` when you
  choose to run it.
- **Bootstrap-only, outside Git entirely:** the repo-credential
  Secret (4.2), the `spoke1` cluster-registration secret (6.1), and
  `root-app.yaml`'s own one-time `kubectl apply`.

**Worth knowing exists, not required here:** the `argo/argocd-apps`
Helm chart, and ArgoCD's own Terraform provider, are the tools teams
reach for when they want the *first* category (Applications/Projects)
managed via Helm/Terraform instead of raw manifests under
`apps/root/` — useful if a client's platform is Terraform-first, but
functionally the same self-heal guarantee you already have. There's
also a genuinely advanced pattern — ArgoCD managing its *own* Helm
release via a self-referential Application — that would shrink the
second category above, but it has real chicken-and-egg failure modes
during upgrades and is beyond what this path needs to cover.

### Cleanup

You're done with the spoke cluster now — reclaim the RAM:
```bash
multipass delete spoke1
multipass purge
```
(`hello-world-fleet-appset.yaml` will start failing to reach
`spoke1` once it's gone — that's expected. Either delete the
ApplicationSet too, or leave it as a known, understood failure if
you want to re-add `spoke1` again later.)

### Why this matters in client work

Knowing precisely where GitOps's self-healing guarantee starts and
stops — and being able to explain *why* — is a more valuable answer
in a client architecture review than either extreme ("everything is
self-healing" or "nothing really is"). Both are wrong; the boundary
above is the real answer.

---

**Tier 6 done.** Everything from Tiers 1-6 is now demonstrated:
App-of-Apps, environment promotion, RBAC/SSO, safe rollout
orchestration, secrets, and multi-cluster — plus a precise
understanding of what's actually GitOps-managed versus bootstrap.
Next: [the capstone](07-capstone.md).
