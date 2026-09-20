# Session 5 — ApplicationSets, sync waves, External Secrets

**Objective:** generate many Applications from one object across
simulated environments, order their resources deterministically, and
close the secret gap that session 3 opened.

**Overlap warning.** `../docs/argocd-learning-path/` already covers
ApplicationSets (1.4), the git generator, and sync waves (3.1), and 4.1
does secrets via **Sealed Secrets**. Do not redo those. This session
covers only what those tiers leave out: the **matrix generator** across
environments, sync waves applied to a dependency that actually fails
without them, and **External Secrets Operator** against a real secret
store — which tier 4 explicitly declined to do.

**Prerequisites:** sessions 2–3. `~/k8slab/gitops/` on `feature/argocd`.

**Read first:** ArgoCD *Operator Manual* → "ApplicationSet" → Generators
(list, git, matrix). External Secrets Operator docs → "HashiCorp Vault"
provider.

---

## Part A — Generators across environments

Three "environments" in one cluster: namespaces `env-dev`, `env-staging`,
`env-prod`. Not real isolation, and pretending otherwise is the trap —
they share a control plane, a CNI and a node.

```bash
for e in dev staging prod; do kubectl create namespace env-$e; done
```

Layout in the `gitops/` tree:

```
environments/
├── base/                       kustomize base: Deployment, Service, ConfigMap
└── overlays/
    ├── dev/kustomization.yaml       replicas 1
    ├── staging/kustomization.yaml   replicas 1
    └── prod/kustomization.yaml      replicas 2
```

### A.1 — The git directory generator

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: demo-envs
  namespace: argocd
spec:
  generators:
    - git:
        repoURL: https://github.com/CarlosMBTeixeira/k8s-production-lab.git
        revision: feature/argo-and-observability-study
        directories:
          - path: gitops/environments/overlays/*
  template:
    metadata:
      name: 'demo-{{path.basename}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/CarlosMBTeixeira/k8s-production-lab.git
        targetRevision: feature/argo-and-observability-study
        path: '{{path}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: 'env-{{path.basename}}'
      syncPolicy:
        automated: { prune: true, selfHeal: true }
```

> **Hypothesis.** Adding a fourth directory creates a fourth Application
> with no change to any ArgoCD object, and deleting the directory removes
> it — including its workloads.
>
> **Tool.** `mkdir environments/overlays/qa`, add a kustomization, commit,
> push, `kubectl -n argocd get applications -w`. Then delete it.
>
> **Expected if right.** The Application appears and disappears on its
> own. The second half is the dangerous half: by default an
> ApplicationSet **deletes** generated Applications whose generator entry
> is gone, and with `prune: true` that cascades to the workloads. A
> renamed directory is a deleted environment.
>
> **What would have caught this sooner.** Asking what happens to the
> generated Application when the generator output shrinks — before
> pointing a generator at a directory glob someone else can rename.
> `preserveResourcesOnDeletion` is the guard; look it up and decide
> whether you would set it on a platform.

### A.2 — The matrix generator

Matrix multiplies two generators — the case that stops being expressible
as a list once it is *N* environments × *M* applications.

> **Hypothesis.** A matrix of `{dev, staging, prod}` × `{app-a, app-b}`
> produces exactly six Applications, and one entry of the cross product
> can be excluded without abandoning the generator.
>
> **Tool.** Build it with two nested list generators, then read up on
> `selector` / `goTemplate` for the exclusion.
>
> **Expected if right.** Six Applications named predictably. The
> exclusion is where matrix generators get ugly — the honest answer is
> often "use two ApplicationSets", and knowing when to stop is worth more
> than making one clever object do everything.
>
> **What would have caught this sooner.** Counting the cross product
> before writing it. Six is fine; fifty needs a different design.

---

## Part B — Sync waves that actually matter

Tier 3.1 demonstrates waves with a demo app. Do the version that fails
without them.

Dependency chain: a namespace, a `SecretStore` that needs Vault
reachable, an `ExternalSecret` that needs the `SecretStore`, and a
Deployment that mounts the resulting Secret.

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-2"   # namespace, RBAC
    # "-1" SecretStore
    # "0"  ExternalSecret
    # "1"  Deployment
```

> **Hypothesis.** Without waves the sync does not fail — it goes
> `Progressing` and eventually converges anyway, because the Deployment
> retries until the Secret exists.
>
> **Tool.** Apply with no annotations first. Watch:
> ```bash
> kubectl -n env-dev get pods -w
> kubectl -n env-dev describe pod <name> | tail -20
> ```
>
> **Expected if right.** `CreateContainerConfigError` on the Deployment
> for a while, then Running once the Secret lands. **Waves did not make
> this possible — they made it deterministic.** The value is a clean sync
> with no transient failures, not a sync that would otherwise never
> complete. Anything that genuinely cannot retry (a Job that runs once
> and exits non-zero) is where waves become load-bearing rather than
> cosmetic.
>
> **What would have caught this sooner.** Asking "does this resource
> retry?" Retrying resources need waves for tidiness; non-retrying ones
> need them for correctness.

---

## Part C — External Secrets, end to end

The gap session 3 opened: the Grafana admin password has no home. Sealed
Secrets (tier 4.1) puts an encrypted blob **in** git. ESO puts a
*reference* in git and keeps the value in an external store. That
difference — encrypted value versus pointer — is the whole architectural
distinction, and it decides what happens when the value must be rotated.

### C.1 — A real store

Vault in dev mode is the smallest honest option. **Dev mode is in-memory
and unsealed — everything below is lost on pod restart, which is fine
here and must never be mistaken for a Vault deployment.**

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm upgrade --install vault hashicorp/vault -n vault --create-namespace \
  --set "server.dev.enabled=true" \
  --set "injector.enabled=false" \
  --set "server.resources.requests.memory=64Mi" \
  --set "server.resources.limits.memory=128Mi"

kubectl -n vault exec -it vault-0 -- sh -c '
  vault secrets enable -path=secret -version=2 kv 2>/dev/null;
  vault kv put secret/grafana admin-password="pick-something"'
```

Budget check before installing anything: `worker-1` has 8 Gi and the
existing stack sits near 3.5 Gi (ADR-035). Vault dev is small, but run
`kubectl describe node worker-1 | grep -A6 'Allocated resources'` first
and record the number.

### C.2 — Operator, store, secret

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm upgrade --install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace
```

Then a `SecretStore` (Vault provider, Kubernetes auth) and an
`ExternalSecret` in `monitoring` that materialises
`kube-prometheus-stack-grafana`'s `admin-password` key. Getting Vault's
Kubernetes auth role bound to the right ServiceAccount is the fiddly part
and is the part worth doing slowly — the ESO docs' Vault page has the
exact policy and role commands.

> **Hypothesis.** The `ExternalSecret` creates a normal `Secret` that
> Grafana cannot distinguish from a hand-made one, and changing the value
> in Vault propagates without any git commit.
>
> **Tool.**
> ```bash
> kubectl -n monitoring get externalsecret,secret | grep grafana
> kubectl -n monitoring get externalsecret grafana-admin \
>   -o jsonpath='{.status.conditions[*].reason}{"\n"}'
> # then rotate in Vault and watch:
> kubectl -n vault exec vault-0 -- vault kv put secret/grafana admin-password="rotated"
> kubectl -n monitoring get secret kube-prometheus-stack-grafana \
>   -o jsonpath='{.data.admin-password}' | base64 -d; echo
> ```
>
> **Expected if right.** `SecretSynced`, an ordinary Secret, and the new
> value appearing after `refreshInterval` with **nothing committed**.
> Then the sting: Grafana does not re-read its admin password on secret
> change, so the running pod keeps the old one until restarted. **ESO
> solved delivery, not consumption** — a distinction that catches people
> who assume rotation is end-to-end.
>
> **What would have caught this sooner.** Asking how the *consumer*
> reads the value: env var (needs a restart), mounted file (may be
> re-read), or fetched per-request (live). Rotation is only as good as
> the consumer's reload behaviour, and that question is answerable before
> choosing a secret manager.

### C.3 — The comparison that matters

Write the answer down; it is the deliverable of Part C.

| | Sealed Secrets (tier 4.1) | ESO (here) |
|---|---|---|
| What is in git | encrypted value | a reference |
| Rotation | re-seal, commit, sync | change in the store; git untouched |
| Disaster recovery | needs the controller's private key | needs the external store |
| Works offline | yes | no — store must be reachable |
| Who can read the plaintext | anyone who can decrypt in-cluster | governed by the store's own policy and audit log |

The Claranet-relevant question is not which is better. It is: *which one
is already in place, and what is the blast radius when it is unavailable?*

---

## Done-criteria

- [ ] One ApplicationSet generating ≥3 Applications; a directory added and removed, with the deletion behaviour observed deliberately.
- [ ] Sync waves demonstrated on a real dependency, plus a written answer to "when are waves cosmetic vs. load-bearing?"
- [ ] A secret consumed by a real workload, sourced from Vault, with no value in git.
- [ ] A rotation performed in the store, observed in the Secret, and the consumer-reload limitation identified.
- [ ] `runbooks/05-applicationsets-and-eso.md` written.

## Cleanup

```bash
helm -n vault uninstall vault; kubectl delete ns vault
helm -n external-secrets uninstall external-secrets; kubectl delete ns external-secrets
for e in dev staging prod qa; do kubectl delete ns env-$e --ignore-not-found; done
```

## Runbook seeds

| Symptom | Tool | Cause | Fix | What would have told me this first |
|---|---|---|---|---|
| Renaming a git directory deleted a live environment | ApplicationSet spec | Generator output shrank; prune cascaded | `preserveResourcesOnDeletion`, or don't glob | Asking what shrinking the generator does |
| `ExternalSecret` stuck, no Secret created | `.status.conditions` | Vault auth role/policy mismatch | Fix the Kubernetes auth binding | The condition reason, not the pod logs |
| Secret rotated, app still using the old value | pod env vs. mounted file | Consumer reads env at startup | Restart, or mount as a file | How the consumer reads it |
| Vault empty after a restart | pod age | Dev mode is in-memory | Expected; never dev mode for real | `server.dev.enabled=true` |
| Pods `CreateContainerConfigError` during sync | `describe pod` | Secret not yet created | Sync waves, for determinism | Whether the resource retries |
