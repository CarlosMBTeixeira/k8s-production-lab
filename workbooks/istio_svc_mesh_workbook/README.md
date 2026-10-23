# Workbook — Istio Service Mesh for daily production use

From "I have done the intro course" to "I can run, change and debug the
mesh on the Claranet OpenShift platform." Eight sessions on the lab's own
Istio + Kiali + Bookinfo (ADR-038), the last one on CRC for the OpenShift
Service Mesh 3 differences. Every session ends in a runbook.

The brief this answers is kept verbatim in [`00-brief.md`](00-brief.md).

---

## Coverage map — KodeKloud *Istio Service Mesh* → this workbook

The course defines the minimum coverage, so nothing it teaches is missed.
**It is a map only** (this study block's ground rule: no video courses): no exercise cites a lesson, and
every "Read first" points at istio.io or the Red Hat OpenShift Service
Mesh documentation. Whether to watch the videos is your call.

| Course module | Lessons | Covered in | Beyond the course |
|---|---|---|---|
| Istio Introduction | install, first app, Kiali | [00](00-toolbox-and-one-request.md) | already installed by `09`; the session starts at *reading* the mesh with `istioctl proxy-config` |
| Pre-requisites | Services, sidecars, Envoy | [00](00-toolbox-and-one-request.md) | one request followed through listener → route → cluster → endpoint |
| Traffic Management | Gateways, VirtualServices, DestinationRules, A/B | [01](01-traffic-routing.md) | Istio API **and** Gateway API side by side; canary delivered as git commits through ArgoCD |
| Traffic Management | fault injection, timeouts, retries, circuit breaking | [02](02-resilience.md) | Envoy response flags in Loki; retry amplification; outlier detection |
| Security | authentication, authorization, certificates | [03](03-security.md) | PERMISSIVE → STRICT migration without an outage; default-deny; finding plaintext callers |
| Observability | Prometheus/Grafana, Jaeger, Kiali in detail | [04](04-observability.md) | RED metrics, Telemetry API, an alert on mesh metrics; tracing as an **optional** unit |
| *(not in course)* | — | [05](05-operating-the-mesh.md) | egress control, `Sidecar` scoping, `discoverySelectors`, canary istiod upgrade with revisions |
| *(not in course)* | — | [06](06-troubleshooting-lab.md) | ten break-and-fix scenarios with `scripts/mesh-break.sh` |
| *(not in course)* | — | [07](07-openshift-service-mesh-3.md) | Sail Operator, `Istio`/`IstioCNI` CRs, Kiali operator, user-workload monitoring — on CRC |

The course's final lesson on Service Mesh Interface is deliberately not
covered: SMI was archived by the CNCF in 2023, and its role is now filled
by the Gateway API's mesh support (GAMMA), which session 01 uses.

---

## The sessions

| # | Session | Cluster | Blocked on |
|---|---|---|---|
| 0 | [Toolbox, and following one request](00-toolbox-and-one-request.md) | k8slab | nothing |
| 1 | [Traffic routing](01-traffic-routing.md) | k8slab | 0 |
| 2 | [Resilience](02-resilience.md) | k8slab | 1 |
| 3 | [Security](03-security.md) | k8slab | 0 |
| 4 | [Observability for daily operations](04-observability.md) | k8slab | 2 (for the alert) |
| 5 | [Operating the mesh](05-operating-the-mesh.md) | k8slab | 1, 3 |
| 6 | [Troubleshooting lab](06-troubleshooting-lab.md) | k8slab | 0–3 |
| 7 | [OpenShift Service Mesh 3](07-openshift-service-mesh-3.md) | CRC | Multipass stopped |

No calendar. Each session is a self-contained block.

**Cluster for sessions 0–6:** `LAB_WORKERS=1 bash scripts/pipeline/main.sh`,
then **6) ArgoCD + Observability + Istio + Kiali** (session 1's GitOps unit
needs ArgoCD; everything else works with **5**). Then once per host:

```bash
./scripts/install-istioctl.sh        # pinned to the control-plane version
export KUBECONFIG=~/k8slab/kubernetes/admin.conf
istioctl version                     # client, control plane and data plane must agree
```

Access: Kiali `./scripts/tunnels/kiali-tunnel.sh` → `https://localhost:8446/`
(token: `kubectl -n istio-system create token kiali-login --duration 8h`),
Grafana `:8445`, Bookinfo `./scripts/tunnels/bookinfo-tunnel.sh` →
`http://localhost:8447/productpage`.

**Resource budget.** The full stack measured 4322Mi requests (55%) and
1300m CPU requests (65%) on the 8G / 2 vCPU worker (ADR-038). CPU is the
tighter budget: load generators in sessions 2 and 4 are sized small on
purpose, and the optional tracing unit adds roughly another 250m.

---

## The method

Same four beats as `workbooks/observability_workbook/`:

> **Hypothesis** — what you believe is true, stated before you look.
> **Tool** — the single command or view that tests it.
> **Expected if right** — what you should see. Written *before* running it.
> **What would have caught this sooner** — the signal that existed before
> the symptom did. This column is the actual product.

Several "expected" blocks below tell you up front that the hypothesis is
wrong. That is deliberate: those are the places where the obvious mental
model of the mesh breaks, and they were observed on this lab, not
assumed.

## Done-criteria

Every session ends with something checkable — a split within a tolerance,
a response flag counted in Loki, a matrix of allowed and denied calls.
Not "read and understood."

## Runbooks

One per session, into [`runbooks/`](runbooks/), from
[`runbooks/_template.md`](runbooks/_template.md). The bring-up of this
mesh already has one: `workbooks/observability_workbook/runbooks/mesh-istio-kiali-install.md`.

## Daily-use reference

After session 0 you should be able to answer, without notes, which tool
discriminates which problem. The short version, built up across the
sessions:

| Question | First tool |
|---|---|
| Is this pod in the mesh, and what applies to it? | `istioctl x describe pod <pod> -n <ns>` |
| Is my config valid? | `istioctl analyze -n <ns>` (catches references, **not** behaviour — see 06) |
| Did istiod push it? | `istioctl proxy-status` |
| What does Envoy actually have? | `istioctl proxy-config listener\|route\|cluster\|endpoint\|secret <pod> -n <ns>` |
| Why did *this* request fail? | the sidecar's access log — **response flag** (`NR`, `NC`, `UC`, `UF`, `UO`, `UH`, `URX`, `DC`) |
| Which calls fail, mesh-wide? | `istio_requests_total` by `response_code`, `response_flags` |
| Is the control plane healthy? | `kubectl -n istio-system get pods` + istiod's `pilot_xds_*` metrics |
