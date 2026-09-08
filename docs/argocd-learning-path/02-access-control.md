# Tier 2 — Access control & multi-tenancy

Everything from Tier 1 lives in the `default` AppProject (which
allows everything, everywhere) and you access it all as the shared
`admin` account you set a password for back in `06_argocd.sh`. No
client accepts either of those in production. This tier closes both
gaps.

---

## 2.1 — AppProjects: cap the blast radius

**Goal:** a real `AppProject` that only allows the repos, namespaces,
and resource kinds Tier 1's apps actually need — not "everything,"
which is what `default` grants.

### Files to create

**`apps/root/lab-apps-project.yaml`** (in `k8s-gitops`)
```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: lab-apps
  namespace: argocd
spec:
  description: Apps from the ArgoCD learning path — deliberately restricted blast radius
  sourceRepos:
    - https://github.com/CarlosMBTeixeira/k8s-gitops.git
    - https://stefanprodan.github.io/podinfo
  destinations:
    - server: https://kubernetes.default.svc
      namespace: 'hello-world-*'
    - server: https://kubernetes.default.svc
      namespace: podinfo
  # Deliberately empty except Namespace: no ClusterRoles, no CRDs, no
  # cluster-scoped anything from this project. Namespace is the one
  # exception — the hello-world overlays each create their own.
  clusterResourceWhitelist:
    - group: ''
      kind: Namespace
  namespaceResourceWhitelist:
    - group: '*'
      kind: '*'
```

Move Tier 1's apps into it — edit `apps/root/podinfo-app.yaml` and
`apps/root/hello-world-appset.yaml`, changing `spec.project: default`
to `spec.project: lab-apps` (in the ApplicationSet, that's
`spec.template.spec.project`). `root` itself stays in `default` — it's
the bootstrap Application, not something you want to also restrict.

### Commands

```bash
cd ~/k8s-gitops
git add -A
git commit -m "Add lab-apps AppProject, move Tier 1 apps into it"
git push
```

### Verify

```bash
kubectl get appproject lab-apps -n argocd
kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,PROJECT:.spec.project
```
Everything except `root` should show `lab-apps`, and all Applications
should still be `Synced`/`Healthy` — moving projects doesn't change
what's deployed, only what's *allowed*.

**Prove the restriction is real:** temporarily edit
`hello-world-dev`'s effective destination to something outside the
allow-list — easiest is editing the ApplicationSet's
`destination.namespace` template to `kube-system` — push, and watch
ArgoCD refuse to sync with a permission error instead of quietly
deploying to `kube-system`. Then revert it and push again. Seeing the
rejection once is the point; leaving it broken isn't.

### Why this matters in client work

Multi-tenancy in ArgoCD starts here — team A's Applications literally
cannot touch team B's namespace even if someone fat-fingers a
manifest, and this is usually the first thing a client security
review asks to see.

---

## 2.2 — RBAC: stop sharing `admin`

**Goal:** a read-only account, distinct from `admin`, that can view
`lab-apps` Applications but is denied `sync`.

### Files to change

Edit `kubernetes/manifests/argocd/values.yaml` (in `k8s-production-lab`):

```yaml
configs:
  params:
    server.insecure: "true"
  cm:
    accounts.viewer: apiKey,login
  rbac:
    policy.csv: |
      p, role:lab-viewer, applications, get, lab-apps/*, allow
      p, role:lab-viewer, applications, sync, lab-apps/*, deny
      g, viewer, role:lab-viewer
    policy.default: ''
```

`policy.default: ''` matters: leaving it unset means anyone without
an explicit `g,` mapping gets **no** access, not silent full access.

### Commands

```bash
cd ~/k8slab
export KUBECONFIG=~/k8slab/kubernetes/admin.conf
helm upgrade argocd argo/argo-cd \
  --version 10.1.4 \
  --namespace argocd \
  -f kubernetes/manifests/argocd/values.yaml

kubectl rollout status -n argocd deployment/argocd-server

# Set a password for the new local account (you're logged in as admin,
# which is allowed to set other local accounts' passwords):
argocd login localhost:8444 --insecure --grpc-web   # admin login, if not already
argocd account update-password --account viewer --new-password '<pick one, min 8 chars>'
```

### Verify

```bash
argocd logout localhost:8444
argocd login localhost:8444 --insecure --grpc-web --username viewer
argocd app list                 # should work — lab-apps visible
argocd app sync hello-world-dev # should be REFUSED — permission denied
```

### Why this matters in client work

A shared static admin password is one of the most common findings in
a client GitOps audit. Distinct accounts with least-privilege roles —
even just two, read-only vs. deploy — is the minimum bar, and the
`policy.csv` model here is exactly what scales to real teams: one
line per role, one `g,` mapping per person or group.

---

## 2.3 — SSO via OIDC

**Goal:** log in with a GitHub account instead of a locally-managed
password — matching how you'll integrate with whatever SSO a client
already runs (Okta/Azure AD/Google Workspace all plug into the same
Dex/OIDC mechanism).

This module involves an external step (registering an OAuth App on
GitHub) that can't be scripted, and Dex logs are genuinely where
you'll debug it — budget more iteration time here than the earlier
modules.

### Step 1 — Register a GitHub OAuth App

GitHub → Settings → Developer settings → OAuth Apps → New OAuth App:
- Homepage URL: `https://localhost:8444`
- Authorization callback URL: `https://localhost:8444/api/dex/callback`

Save the **Client ID**, and generate + save a **Client Secret**.

### Step 2 — Wire Dex up, keeping the secret out of Git

Same principle as the admin password in `06_argocd.sh`: the client
secret goes into a Kubernetes Secret directly, never into
`values.yaml`.

```bash
kubectl patch secret argocd-secret -n argocd --type merge \
  -p '{"stringData": {"dex.github.clientSecret": "<the client secret from step 1>"}}'
```

Add to `kubernetes/manifests/argocd/values.yaml`:
```yaml
configs:
  cm:
    url: https://localhost:8444
    dex.config: |
      connectors:
        - type: github
          id: github
          name: GitHub
          config:
            clientID: <the client ID from step 1 — this one's fine in git, it's not secret>
            clientSecret: $dex.github.clientSecret
```

```bash
helm upgrade argocd argo/argo-cd --version 10.1.4 --namespace argocd -f kubernetes/manifests/argocd/values.yaml
kubectl rollout restart deployment argocd-dex-server -n argocd
```

### Step 3 — Log in via GitHub, then map yourself to a role

Browse to `https://localhost:8444`, choose "Log in via GitHub." If it
fails, `kubectl logs deploy/argocd-dex-server -n argocd` almost always
shows exactly why (callback URL mismatch is the most common one).

Once it works, check what subject ArgoCD actually sees —
`kubectl logs deploy/argocd-server -n argocd | grep -i claims` while
logging in, or check the user info in the UI's account settings — and
add a `g,` line in `policy.csv` mapping that identity (usually your
GitHub email) to `role:lab-viewer`, the same role from 2.2:

```yaml
    policy.csv: |
      p, role:lab-viewer, applications, get, lab-apps/*, allow
      p, role:lab-viewer, applications, sync, lab-apps/*, deny
      g, viewer, role:lab-viewer
      g, <your-github-email>, role:lab-viewer
```

### Step 4 — Only once SSO login is confirmed working

Disable local password login entirely:
```yaml
configs:
  cm:
    admin.enabled: "false"
```

**Verify SSO login works before this step, not after** — if you
disable local admin first and SSO is misconfigured, you're locked
out. Recovery if that happens: `helm upgrade` again with
`admin.enabled: "true"` removed/reverted from a previous commit —
this is exactly why the change is small and isolated in its own
commit.

### Why this matters in client work

A shared static admin password is the finding; SSO is the fix a
client actually expects. Every real engagement wires ArgoCD into
whatever identity provider already exists — this module is the same
mechanics (Dex + OIDC connector + RBAC group mapping) you'd repeat
with Okta or Azure AD instead of GitHub.

---

**Tier 2 done.** State at this point: a `lab-apps` AppProject with a
real allow-list, a `viewer` role that can look but not touch, and
(optionally) GitHub SSO replacing the shared admin login. Next:
[Tier 3 — deployment orchestration](03-deployment-orchestration.md).
