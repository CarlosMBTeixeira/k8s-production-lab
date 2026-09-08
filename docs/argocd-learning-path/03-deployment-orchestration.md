# Tier 3 — Deployment orchestration & safety

Tier 0 already proved self-heal reverts drift. This tier is about
controlling *how* a sync actually rolls out — ordering, verification,
and the difference between "applied" and "safe."

---

## 3.1 — Sync waves

**Goal:** a resource that must exist before another one is even
attempted, enforced by ArgoCD's sync ordering — not by luck or
Kubernetes' eventual consistency quietly papering over the gap.

### Files to create

**`apps/waved-demo/configmap.yaml`** (in `k8s-gitops`)
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: waved-config
  namespace: waved-demo
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
data:
  GREETING: "hello from a resource that synced first"
```

**`apps/waved-demo/namespace.yaml`**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: waved-demo
```

**`apps/waved-demo/deployment.yaml`** (default wave, `"0"` — no
annotation needed, that's the default)
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: waved-demo
  namespace: waved-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: waved-demo
  template:
    metadata:
      labels:
        app: waved-demo
    spec:
      containers:
        - name: waved-demo
          image: busybox:1.36
          command: ["sh", "-c", "echo \"config says: $GREETING\"; sleep 3600"]
          envFrom:
            - configMapRef:
                name: waved-config
```

**`apps/root/waved-demo-app.yaml`**
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: waved-demo
  namespace: argocd
spec:
  project: lab-apps
  source:
    repoURL: https://github.com/CarlosMBTeixeira/k8s-gitops.git
    targetRevision: feature/argocd
    path: apps/waved-demo
  destination:
    server: https://kubernetes.default.svc
    namespace: waved-demo
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

This app lands in the `lab-apps` AppProject from Tier 2, so add
`waved-demo` to its destinations first:

Edit `apps/root/lab-apps-project.yaml`, add under `destinations:`:
```yaml
    - server: https://kubernetes.default.svc
      namespace: waved-demo
```

### Commands

```bash
cd ~/k8s-gitops
git add -A
git commit -m "Add waved-demo app to demonstrate sync waves"
git push
```

### Verify

```bash
export KUBECONFIG=~/k8slab/kubernetes/admin.conf
kubectl get events -n waved-demo --sort-by=.metadata.creationTimestamp \
  -o custom-columns=TIME:.firstTimestamp,OBJECT:.involvedObject.name,REASON:.reason
```
The ConfigMap's creation event should have a strictly earlier
timestamp than the Deployment's — that ordering is the sync wave, not
coincidence. You can see the same grouping visually in the ArgoCD
UI's sync graph for this app (two visually separate "waves").

```bash
kubectl logs deploy/waved-demo -n waved-demo
# "config says: hello from a resource that synced first"
```

### Why this matters in client work

Every non-trivial app has an implicit dependency graph (CRDs before
CRs, a migration before the pods that need the migrated schema). Sync
waves make that graph explicit instead of hoping it works out.

---

## 3.2 — Resource hooks

**Goal:** a `PreSync` Job that must succeed before the rest of a sync
proceeds — the real answer to "how do you run a migration safely in
GitOps."

### Files to create

**`apps/waved-demo/presync-job.yaml`**
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: waved-demo-premigration
  namespace: waved-demo
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: HookSucceeded
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: premigration
          image: busybox:1.36
          command: ["sh", "-c", "echo 'pretend DB migration running...'; sleep 5; echo done"]
```

`hook-delete-policy: HookSucceeded` means the Job cleans itself up
only on success — if it fails, the Job (and its Pod, and its logs)
stay around for you to inspect, which is exactly what you want mid
incident.

### Commands

```bash
cd ~/k8s-gitops
git add apps/waved-demo/presync-job.yaml
git commit -m "Add PreSync hook to waved-demo"
git push
```

### Verify

```bash
kubectl get jobs -n waved-demo   # ran, succeeded, and (per the delete policy) is now gone
```

**Now break it on purpose.** Change the command to
`["sh", "-c", "echo 'failing on purpose'; exit 1"]`, commit, push, and
watch:
```bash
kubectl get application waved-demo -n argocd   # stuck, sync failed — not Synced
kubectl get jobs -n waved-demo                 # the failed Job is STILL there — no delete policy fired
kubectl logs job/waved-demo-premigration -n waved-demo
```
Confirm the Deployment was never touched by this failed sync (its
`AGE`/image are unchanged from 3.1). Then revert the command back and
push again to get back to healthy.

### Why this matters in client work

This is the concrete answer when a client asks "how do you run
migrations safely in GitOps" — a question that comes up in nearly
every ArgoCD adoption conversation.

---

## 3.3 — Custom health checks

**Goal:** ArgoCD reporting real, meaningful health for a CRD it
doesn't understand out of the box — a cert-manager `Certificate` is
the perfect example, and you already have cert-manager running
(ADR-033).

### Files to create

Find the domain you already validated cert-manager against, so you
reuse a real, working `ClusterIssuer`:
```bash
kubectl get certificate -A
kubectl get clusterissuer
```

**`apps/waved-demo/certificate.yaml`** (swap `<your-domain>` for a
subdomain under the zone your `letsencrypt-k8slab` ClusterIssuer is
already validated against)
```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: argocd-learning-demo
  namespace: waved-demo
spec:
  secretName: argocd-learning-demo-tls
  issuerRef:
    name: letsencrypt-k8slab
    kind: ClusterIssuer
  dnsNames:
    - argocd-learning-demo.<your-domain>
```

### Files to change

Add a Lua health check to `kubernetes/manifests/argocd/values.yaml`
(in `k8s-production-lab`) — ArgoCD's default health checks don't know
what "healthy" means for a `Certificate`, so without this it just
shows "Synced" (the object exists) forever, never "Healthy":

```yaml
configs:
  cm:
    resource.customizations.health.cert-manager.io_Certificate: |
      hs = {}
      if obj.status ~= nil and obj.status.conditions ~= nil then
        for i, condition in ipairs(obj.status.conditions) do
          if condition.type == "Ready" then
            if condition.status == "True" then
              hs.status = "Healthy"
              hs.message = condition.message
              return hs
            end
            if condition.status == "False" then
              hs.status = "Degraded"
              hs.message = condition.message
              return hs
            end
          end
        end
      end
      hs.status = "Progressing"
      hs.message = "Waiting for certificate"
      return hs
```

### Commands

```bash
cd ~/k8s-gitops
git add apps/waved-demo/certificate.yaml && git commit -m "Add Certificate to waved-demo" && git push

cd ~/k8slab
helm upgrade argocd argo/argo-cd --version 10.1.4 --namespace argocd -f kubernetes/manifests/argocd/values.yaml
```

### Verify

```bash
kubectl get application waved-demo -n argocd -o jsonpath='{.status.health.status}{"\n"}'
```
Watch it go `Progressing` → `Healthy` as Let's Encrypt actually
issues the cert (can take up to a minute or two for DNS-01). Compare
against `kubectl get certificate argocd-learning-demo -n waved-demo`
— ArgoCD's health status should track the `Ready` condition exactly.

### Why this matters in client work

"Synced" and "healthy" are different things, and for any CRD-heavy
platform — which is most production clusters — the default health
checks cover a fraction of what's actually deployed. Not writing
these means half your fleet shows green in ArgoCD while something
underneath is actually broken.

---

## 3.4 — Progressive delivery: Argo Rollouts

**Goal:** `podinfo` deploys via a canary rollout with automated
analysis against real Prometheus metrics — a bad deploy aborts itself
before it reaches 100% of traffic.

> **RAM budget note:** this needs ArgoCD *and* the observability
> stack (`monitoring` namespace, ADR-031) running together, which
> your 4-VM budget doesn't comfortably fit yet. Either accept
> degraded margins for this session, or stand up a throwaway
> `k3d`/`kind` cluster inside WSL2 just for this module — it doesn't
> touch the Multipass fleet and costs far less RAM than a fifth VM.

### Step 1 — Install the Argo Rollouts controller

Same Helm/Artifact Hub pattern as everything else (ADR-030):
```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm upgrade --install argo-rollouts argo/argo-rollouts \
  --namespace argo-rollouts --create-namespace
kubectl wait --for=condition=Available --timeout=180s -n argo-rollouts deployment/argo-rollouts
```

### Step 2 — Replace podinfo's Helm-chart Deployment with a Rollout

The upstream podinfo chart manages a plain `Deployment`, not a
`Rollout` — so this module moves podinfo off that chart and onto
manifests you own directly (a natural, common evolution: start with a
vendor chart, take ownership once you need something the chart
doesn't support).

**`apps/podinfo/rollout.yaml`** (new file, in `k8s-gitops`)
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: podinfo
  namespace: podinfo
spec:
  replicas: 4
  selector:
    matchLabels:
      app: podinfo
  template:
    metadata:
      labels:
        app: podinfo
    spec:
      containers:
        - name: podinfo
          image: ghcr.io/stefanprodan/podinfo:6.7.0
          ports:
            - containerPort: 9898
              name: http
          resources:
            requests:
              cpu: 25m
              memory: 32Mi
  strategy:
    canary:
      steps:
        - setWeight: 25
        - pause: { duration: 30 }
        - analysis:
            templates:
              - templateName: podinfo-success-rate
        - setWeight: 50
        - pause: { duration: 30 }
        - setWeight: 100
```

**`apps/podinfo/service.yaml`**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: podinfo
  namespace: podinfo
spec:
  selector:
    app: podinfo
  ports:
    - port: 9898
      targetPort: http
```

**`apps/podinfo/analysistemplate.yaml`**
```yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: podinfo-success-rate
  namespace: podinfo
spec:
  metrics:
    - name: success-rate
      interval: 30s
      successCondition: result[0] >= 0.95
      failureLimit: 2
      provider:
        prometheus:
          address: http://kube-prometheus-stack-prometheus.monitoring.svc:9090
          query: |
            sum(rate(http_requests_total{namespace="podinfo",code=~"2.."}[1m]))
            /
            sum(rate(http_requests_total{namespace="podinfo"}[1m]))
```
(`kube-prometheus-stack-prometheus.monitoring` is the exact release
name/namespace `07_observability.sh` installs — confirm with
`kubectl get svc -n monitoring | grep prometheus` if you've renamed
anything.) `podinfo` ships this `http_requests_total` metric itself,
no extra instrumentation needed.

This is a **basic canary** (no `trafficRouting` block) — weight is
approximated by the ratio of canary-to-stable replica counts behind
one Service, not real traffic splitting via the Gateway API. That's
the right amount of complexity for learning the analysis/promotion
mechanics; wiring `trafficRouting` to Envoy Gateway for true
weighted traffic is a good follow-up once this feels routine, not a
prerequisite for it.

Point the Application at the new path instead of the Helm chart —
edit `apps/root/podinfo-app.yaml`:
```yaml
spec:
  project: lab-apps
  source:
    repoURL: https://github.com/CarlosMBTeixeira/k8s-gitops.git
    targetRevision: feature/argocd
    path: apps/podinfo
  destination:
    server: https://kubernetes.default.svc
    namespace: podinfo
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### Commands

```bash
cd ~/k8s-gitops
git add -A
git commit -m "Move podinfo from Helm chart to an Argo Rollout with canary analysis"
git push
```

### Verify

```bash
kubectl argo rollouts get rollout podinfo -n podinfo --watch
```
(needs the `kubectl argo rollouts` plugin — `brew install
argoproj/tap/kubectl-argo-rollouts` or download the binary from the
Argo Rollouts releases page). Watch it step through 25% → pause →
analysis → 50% → pause → 100%.

**Trigger a real rollout:** bump the image tag in `rollout.yaml` to
any other podinfo tag, push, and watch the same sequence run again
for the new version — this is the actual deploy path from now on,
not a one-time demo.

**Trigger a bad rollout on purpose:** set the AnalysisTemplate's
`successCondition` to something that can't pass (`result[0] >= 2`),
push, bump the image tag again, and watch the rollout abort itself
partway through instead of reaching 100%. Then revert the condition.

### Why this matters in client work

This is the module that turns "GitOps deploys the app" into "GitOps
deploys the app safely" — the single biggest gap between a demo
ArgoCD setup and one a client trusts with production traffic.

---

**Tier 3 done.** State at this point: sync waves and a PreSync hook
proven on `waved-demo`, a custom health check making `Certificate`
status meaningful, and `podinfo` running progressive canary
deployments gated on real metrics. Next: [Tier 4 — securing the
pipeline](04-securing-pipeline.md).
