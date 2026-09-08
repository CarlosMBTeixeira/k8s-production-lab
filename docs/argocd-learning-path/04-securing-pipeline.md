# Tier 4 — Securing the pipeline

`k8s-gitops` is public and has no secrets in it — fine for a
hello-world demo, disqualifying for a client repo. This tier makes
the pipeline itself defensible: secrets, repo access, and closing the
loop from a CI build to a Git commit.

---

## 4.1 — Secrets in Git, safely

**Goal:** a Secret that's genuinely committed to `k8s-gitops`, in
encrypted form, and decrypted only inside the cluster — the plaintext
never touches Git.

Sealed Secrets, not the External Secrets Operator you've deliberately
deferred to CKS study — this is the lighter-weight option and doesn't
overlap with that decision.

### Step 1 — Install the controller

```bash
export KUBECONFIG=~/k8slab/kubernetes/admin.conf
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm repo update
helm upgrade --install sealed-secrets-controller sealed-secrets/sealed-secrets \
  --namespace kube-system
kubectl wait --for=condition=Available --timeout=120s -n kube-system deployment/sealed-secrets-controller
```

Install the `kubeseal` CLI (matches the controller's `sealed-secrets`
GitHub releases — grab the binary for your platform).

### Step 2 — Seal a real value, commit only the sealed form

```bash
kubectl create secret generic waved-demo-apikey -n waved-demo \
  --from-literal=API_KEY='this-is-not-a-real-secret-but-pretend-it-is' \
  --dry-run=client -o yaml > /tmp/plain-secret.yaml

kubeseal --format=yaml \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system \
  < /tmp/plain-secret.yaml > apps/waved-demo/sealed-apikey.yaml

rm /tmp/plain-secret.yaml   # the plaintext never gets committed
```

`apps/waved-demo/sealed-apikey.yaml` now contains a `SealedSecret`
resource — safe to commit. Only the controller's private key (which
never leaves the cluster) can decrypt it back into a real `Secret`.

Wire it into the Deployment to prove it's actually usable — edit
`apps/waved-demo/deployment.yaml`, add to the container spec:
```yaml
          envFrom:
            - configMapRef:
                name: waved-config
            - secretRef:
                name: waved-demo-apikey
```

### Commands

```bash
cd ~/k8s-gitops
git add apps/waved-demo/sealed-apikey.yaml apps/waved-demo/deployment.yaml
git commit -m "Add a real secret to waved-demo via Sealed Secrets"
git push
```

### Verify

```bash
kubectl get sealedsecret waved-demo-apikey -n waved-demo   # the encrypted form you committed
kubectl get secret waved-demo-apikey -n waved-demo -o jsonpath='{.data.API_KEY}' | base64 -d
# the real plaintext value — decrypted in-cluster, never in git
```

Check the committed YAML in GitHub itself and confirm the value there
is ciphertext, not the string you typed.

### Why this matters in client work

"Where do secrets live" is the first question in any GitOps security
review. Having a working answer — even a lightweight one like this —
is non-negotiable before a client repo gets touched.

---

## 4.2 — Private repo auth via SSH deploy key

**Goal:** `k8s-gitops` becomes private, and ArgoCD authenticates to
it with an SSH deploy key scoped **read-only** to that one repo —
never a personal access token scoped to your whole GitHub account.

### Step 1 — Make the repo private

GitHub → `k8s-gitops` → Settings → General → Danger Zone → Change
repository visibility → Private.

Everything will immediately go `Unknown`/repo-error in ArgoCD — that's
expected, you're about to fix it.

### Step 2 — Generate a dedicated, read-only keypair

```bash
ssh-keygen -t ed25519 -f ~/k8s-gitops-deploy-key -C "argocd-readonly" -N ""
```

GitHub → `k8s-gitops` → Settings → Deploy keys → Add deploy key →
paste `~/k8s-gitops-deploy-key.pub`, leave "Allow write access"
**unchecked**.

### Step 3 — Register the private key as an ArgoCD repo credential

```bash
cat > /tmp/k8s-gitops-repo-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: k8s-gitops-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: git@github.com:CarlosMBTeixeira/k8s-gitops.git
  sshPrivateKey: |
$(sed 's/^/    /' ~/k8s-gitops-deploy-key)
EOF

kubectl apply -f /tmp/k8s-gitops-repo-secret.yaml
rm /tmp/k8s-gitops-repo-secret.yaml   # never leave a private key on disk longer than needed
```

### Step 4 — Point every Application at the SSH URL, not HTTPS

ArgoCD matches credentials to Applications by exact `repoURL` string
— `https://github.com/...` and `git@github.com:...` are different
strings to it, even though they're the same repo. Update
`repoURL: https://github.com/CarlosMBTeixeira/k8s-gitops.git` to
`repoURL: git@github.com:CarlosMBTeixeira/k8s-gitops.git` in every
file that references it:

- `k8s-production-lab`: `kubernetes/manifests/argocd/apps/root-app.yaml`
- `k8s-gitops`: `apps/root/hello-world-appset.yaml`,
  `apps/root/podinfo-app.yaml`, `apps/root/waved-demo-app.yaml`,
  and `apps/root/lab-apps-project.yaml`'s `sourceRepos` entry

```bash
grep -rl 'https://github.com/CarlosMBTeixeira/k8s-gitops' ~/k8s-gitops ~/k8slab
# edit each file the grep finds
```

### Commands

```bash
cd ~/k8s-gitops
git add -A && git commit -m "Switch repoURL references to SSH" && git push

cd ~/k8slab
kubectl apply -f kubernetes/manifests/argocd/apps/root-app.yaml
```

### Verify

```bash
kubectl get applications -n argocd
```
Everything back to `Synced`/`Healthy` — now authenticating over SSH
with a key that can only read this one repo.

### Why this matters in client work

A leaked personal access token scoped to your entire GitHub account
is a very different incident than a leaked deploy key scoped to one
repo, read-only. Clients will ask which one you used, and "read-only
deploy key, one repo" is the answer that ends the conversation.

---

## 4.3 — Closing the loop: image automation

**Goal:** a CI pipeline that builds an image and, on success, commits
the new tag into `k8s-gitops` itself — completing the actual GitOps
loop instead of you hand-editing an image tag.

This module is a bigger lift than the others: you're creating a third
repository (a tiny app + Dockerfile + workflow), separate from both
`k8s-production-lab` and `k8s-gitops` — on purpose, matching the same
infra-vs-desired-state separation `k8s-gitops`'s own README already
argues for.

### Step 1 — Create a new repo with a trivial app

A new GitHub repo, e.g. `ci-demo-app`, containing:

**`Dockerfile`**
```dockerfile
FROM busybox:1.36
COPY message.txt /message.txt
CMD ["sh", "-c", "cat /message.txt; sleep 3600"]
```

**`message.txt`**
```
Hello from a CI-built image.
```

### Step 2 — A second deploy key, this time with write access

This key needs to push to `k8s-gitops` — a different privilege level
than 4.2's read-only key, so it's a **different key**, not a reused
one:
```bash
ssh-keygen -t ed25519 -f ~/ci-demo-app-deploy-key -C "ci-demo-app-write" -N ""
```
`k8s-gitops` → Settings → Deploy keys → Add deploy key → paste the
`.pub` file, this time **check** "Allow write access."

`ci-demo-app` → Settings → Secrets and variables → Actions → New
repository secret → name it `GITOPS_DEPLOY_KEY`, paste the *private*
key contents.

### Step 3 — The workflow

**`.github/workflows/build-and-bump.yml`** (in `ci-demo-app`)
```yaml
name: build-and-bump
on:
  push:
    branches: [main]
jobs:
  build-push-bump:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: Build and push
        run: |
          IMAGE="ghcr.io/carlosmbteixeira/ci-demo-app:${{ github.sha }}"
          docker build -t "$IMAGE" .
          docker push "$IMAGE"
          echo "IMAGE=$IMAGE" >> "$GITHUB_ENV"
      - name: Bump image tag in k8s-gitops
        run: |
          mkdir -p ~/.ssh
          echo "${{ secrets.GITOPS_DEPLOY_KEY }}" > ~/.ssh/id_ed25519
          chmod 600 ~/.ssh/id_ed25519
          ssh-keyscan github.com >> ~/.ssh/known_hosts
          git clone --branch feature/argocd git@github.com:CarlosMBTeixeira/k8s-gitops.git gitops
          cd gitops
          sed -i "s|image: ghcr.io/carlosmbteixeira/ci-demo-app:.*|image: ${IMAGE}|" apps/ci-demo-app/deployment.yaml
          git config user.email "ci-bot@ci-demo-app"
          git config user.name "ci-bot"
          git commit -am "Bump ci-demo-app to ${{ github.sha }}" || echo "nothing to commit"
          git push
```

### Step 4 — Wire it into ArgoCD

In `k8s-gitops`, create `apps/ci-demo-app/namespace.yaml` and
`apps/ci-demo-app/deployment.yaml` (same shape as `waved-demo`'s
Deployment, image `ghcr.io/carlosmbteixeira/ci-demo-app:<any-tag-that-exists-yet>`
to start), and `apps/root/ci-demo-app-app.yaml` pointing at
`apps/ci-demo-app` — same pattern as every Application so far. Add
`ci-demo-app` to `lab-apps`'s AppProject destinations, same as 3.1.

### Verify

Push any change to `ci-demo-app`'s `main` branch and watch the whole
chain: Action builds and pushes the image → Action commits the new
tag to `k8s-gitops` → ArgoCD picks up the commit and syncs the new
image, with zero manual steps after the initial `git push`.

```bash
kubectl get application ci-demo-app -n argocd -w
kubectl get deploy ci-demo-app -n ci-demo-app -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

**Worth comparing once this works:** this is the *push* model — CI
commits on your behalf. **Argo CD Image Updater** is the *pull*
model — it polls the registry and commits itself, no CI pipeline
required. Worth reading the Image Updater docs and knowing which
model a given client's setup already assumes, since both are common.

### Why this matters in client work

This is "day one" for most engagements: CI builds and pushes an
image, and something has to turn that into a Git commit before
ArgoCD ever sees it. Understanding both the push (CI-commits) and
pull (Image Updater) models — and why a team picked one — comes up
constantly in real GitOps adoptions.

---

**Tier 4 done.** State at this point: a real secret flowing through
Git safely, `k8s-gitops` private and reachable only via a scoped
deploy key, and a full build→commit→sync loop running end to end.
Next: [Tier 5 — operating ArgoCD itself](05-operating-argocd.md).
