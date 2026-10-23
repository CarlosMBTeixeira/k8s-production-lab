# Session 7 — OpenShift Service Mesh 3 (on CRC)

**Objective:** find out exactly what changes when the mesh is installed
and run by the platform's operator instead of by Helm — which objects
you write, which ones the operator owns, and where Kiali gets its
metrics — so that sessions 0–6 transfer to the Claranet cluster without
surprises.

**Status: written from the Red Hat documentation, not yet run on CRC.**
Unlike sessions 0–6, nothing here has been executed. Every field name
below is to be checked with `oc explain` against the operator version
you actually install (7.0 does exactly that), and every correction
recorded in the runbook.

**Prerequisites**
- Same CRC setup as `workbooks/observability_workbook/06-openshift-monitoring-logging.md`:
  Multipass stopped (`multipass stop --all`), CRC with monitoring
  enabled and ~14 GiB, `sg libvirt -c '…'` in front of `crc` commands.
- **User-workload monitoring enabled** (that session's 6.x unit). Kiali
  depends on it here.
- `istioctl` on the host works against OpenShift too — check its version
  against the mesh version the operator installs.

**Read first:** Red Hat → OpenShift Service Mesh 3 → *Installing*,
*Observability* ("Metrics and Service Mesh", "Kiali"), *Updating*.
Version must match the OSSM 3.x release the OperatorHub offers on your
CRC.

---

## 7.0 — What the operator gives you instead of three Helm charts

Install **Red Hat OpenShift Service Mesh 3** from OperatorHub (console →
Operators → OperatorHub), then:

```bash
oc api-resources --api-group=sailoperator.io
oc explain istio.spec --recursive | head -60
oc explain istiocni.spec
```

> **Hypothesis.** The operator's `Istio` resource is a wrapper around the
> same Helm values you used in `kubernetes/manifests/istio/istiod-values.yaml`.
>
> **Tool.** `oc explain istio.spec.values --recursive`, compared with
> `helm show values istio/istiod --version 1.30.7`.
>
> **Expected if right.** Largely yes — the Sail Operator renders the
> upstream charts, and `spec.values` mirrors their values (meshConfig,
> pilot resources, global.proxy…). What the operator adds is the
> lifecycle around them: `spec.version`, `spec.updateStrategy`
> (`InPlace` or `RevisionBased`), and separate kinds for CNI
> (`IstioCNI`) and revisions (`IstioRevision`, `IstioRevisionTag`).
> Translate this lab's `istiod-values.yaml` into an `Istio` CR as the
> first exercise.
>
> **What would have caught this sooner.** The CRD list itself — four
> kinds where you used three charts, because revisions became objects.

---

## 7.1 — Install the control plane and CNI as CRs

```bash
oc new-project istio-system
oc new-project istio-cni
```

Write two resources (check every field with `oc explain`):

- `IstioCNI` named `default`, `spec.namespace: istio-cni`,
  `spec.version` = the version the operator offers.
- `Istio` named `default`, `spec.namespace: istio-system`, same version,
  `spec.updateStrategy.type: InPlace`, and `spec.values` carrying this
  lab's choices: sidecar resources, istiod resources, access log to
  stdout.

> **Hypothesis.** CNI is optional on OpenShift, as it was a choice in
> this lab (ADR-038).
>
> **Tool.** Red Hat's install docs, then the pods:
> `oc get pods -n istio-cni`, and an injected pod's init containers.
>
> **Expected if right.** It is **mandatory**. OpenShift's restricted
> security context constraints do not let application pods run the
> `NET_ADMIN` init container that sidecar mode would otherwise need, so
> the CNI node agent does the redirection — which is why this lab chose
> it. An injected pod should show `istio-validation`, as in session 0.1.
>
> **What would have caught this sooner.** `oc get scc restricted-v2 -o yaml`
> — no `NET_ADMIN` in `allowedCapabilities`.

---

## 7.2 — Which namespaces are in the mesh

```bash
oc new-project bookinfo
oc label namespace bookinfo istio-injection=enabled
oc apply -n bookinfo -f https://raw.githubusercontent.com/istio/istio/<version>/samples/bookinfo/platform/kube/bookinfo.yaml
```

> **Hypothesis.** Labelling the namespace is enough, exactly as on the lab.
>
> **Tool.** `oc get pods -n bookinfo` (READY 2/2?), then
> `oc get istio default -o yaml | yq '.spec.values.meshConfig.discoverySelectors'`.
>
> **Expected if right.** Check, don't assume. OpenShift Service Mesh 3
> supports several meshes per cluster and leans on
> **`discoverySelectors`** (session 5.2) to scope them; if the `Istio`
> CR sets one, the namespace also needs the matching label before
> istiod sees it. Whether injection uses `istio-injection=enabled` or
> `istio.io/rev=<revision>` depends on the update strategy — with
> `RevisionBased`, revision names change on every upgrade, which is what
> `IstioRevisionTag` exists for (session 5.3, as an object).
>
> **What would have caught this sooner.** `oc get istiorevision` — the
> actual revision names in the cluster, which may not be `default`.

---

## 7.3 — Metrics: Kiali without your own Prometheus

This is the biggest difference from the lab. There is no
kube-prometheus-stack; metrics go to **user-workload monitoring**, and
Kiali reads them through the **Thanos Querier**.

1. A `ServiceMonitor` for istiod in `istio-system`, and a `PodMonitor`
   for the sidecars **in each mesh namespace** (Red Hat's docs give both).
2. Install the **Kiali Operator provided by Red Hat** and a `Kiali` CR
   pointing `external_services.prometheus` at
   `https://thanos-querier.openshift-monitoring.svc.cluster.local:9091`
   with bearer-token auth, and grant Kiali's ServiceAccount
   `cluster-monitoring-view`.
3. Optionally the **OSSM console plugin** (`OSSMConsole` CR) to get
   Kiali's views inside the OpenShift console.

> **Hypothesis.** One PodMonitor with `namespaceSelector: {any: true}` in
> `istio-system` works, as it does on the lab (`kubernetes/manifests/istio/monitors.yaml`).
>
> **Tool.** Create it that way first; then
> `oc -n openshift-user-workload-monitoring logs deploy/prometheus-operator | grep -i namespace`
> and the targets in the console (Observe → Targets).
>
> **Expected if right.** It is expected **not** to scrape other
> namespaces: user-workload monitoring is built for tenants, and does
> not let one project's monitor reach into another. Hence one PodMonitor
> per mesh namespace. Confirm and record what you actually observe — it
> is the single most likely "why is Kiali empty" on the platform.
>
> **What would have caught this sooner.** Red Hat's "Metrics and Service
> Mesh" page, which creates the PodMonitor per namespace for exactly
> this reason.

> **Hypothesis.** Kiali's login works like the lab's token strategy.
>
> **Tool.** Open Kiali's Route.
>
> **Expected if right.** It uses the **`openshift`** auth strategy: you
> log in with your OpenShift identity, and Kiali shows what *your* RBAC
> allows. The lab's `kiali-login` token (ADR-038) was a stand-in for
> exactly this model.
>
> **What would have caught this sooner.** `oc get kiali -A -o yaml | yq '.items[].spec.auth'`.

---

## 7.4 — Ingress: Routes, gateways, or both

> **Hypothesis.** On OpenShift you expose Bookinfo with a Route to
> productpage, as with any app.
>
> **Tool.** Create the Route both ways and compare in Kiali:
> (a) Route → productpage Service; (b) Gateway API `Gateway` (class
> `istio`) + HTTPRoute as on the lab, then a Route (or the gateway's
> LoadBalancer/NodePort) in front of the gateway Service.
>
> **Expected if right.** (a) works but **bypasses the mesh's ingress**:
> traffic enters productpage from the OpenShift router, which is not in
> the mesh — so with STRICT mTLS (session 3) it fails, and Kiali shows
> the source as unknown. (b) keeps the mesh's entry point and policy,
> with the router (or a load balancer) in front of the gateway.
>
> **What would have caught this sooner.** Session 3.3's finding: STRICT
> protects workloads, not entry points — so *what* the entry point is
> matters.

---

## 7.5 — Upgrades the operator's way

> **Hypothesis.** An upgrade is changing `spec.version` on the `Istio` CR.
>
> **Tool.** Red Hat → *Updating*; `oc explain istio.spec.updateStrategy`.
>
> **Expected if right.** With `InPlace`, yes — and it carries the risk
> session 5.3 described. With `RevisionBased`, the operator creates a new
> `IstioRevision`, keeps the old one until no proxies use it
> (`inactiveRevisionDeletionGracePeriodSeconds`), and you move namespaces
> by relabelling or by moving an `IstioRevisionTag`. That is session 5.3
> as a CR. Check what happens to auto-deployed gateways when the tag
> moves — the lab showed they follow the revision label without a
> restart.
>
> **What would have caught this sooner.** `oc get istio default -o jsonpath='{.status}'`
> — the operator reports revisions in use there.

---

**Done when**
- The lab's `istiod-values.yaml` is expressed as an `Istio` CR plus an
  `IstioCNI` CR that you applied, with every field confirmed by `oc explain`.
- Bookinfo runs meshed on CRC, and Kiali shows its graph from
  user-workload monitoring through the Thanos Querier.
- You have a written list of **every** difference you hit between the
  lab and CRC — that list is the runbook, and the most valuable artefact
  of the whole workbook for the first weeks on the platform.
- CRC stopped and Multipass started again before the next lab session.

**Runbook:** `runbooks/07-openshift-service-mesh-3.md`.
