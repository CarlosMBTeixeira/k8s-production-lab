# The brief

The original request, kept verbatim because the sessions are answers to
it and drift is easy once the exercises start.

> Also, consider this KodeKloud course:
> https://learn.kodekloud.com/learn/courses/istio-service-mesh
>
> I want you to create me practical exercises that I can work on based on
> this course. I will use this tool on my new job, in production, so I
> need to get familiarized with it, and to understand deeply how I can use
> it on a daily basis and to use it's full potential.
>
> a section of troubleshooting could also be good

## Decisions taken on the proposal (2026-10-23)

| Question | Decision |
|---|---|
| The study block's ground rule forbids video courses | **Course as a map only.** Its syllabus sets the minimum coverage; every exercise cites istio.io or Red Hat docs. |
| Distributed tracing (the course uses Jaeger) | **Optional** unit in session 4, because of the worker's CPU budget. |
| `istioctl` on the host | Install it, pinned to the control-plane version (`scripts/install-istioctl.sh`). |
| OpenShift Service Mesh 3 session on CRC | **Included** as session 7. |
| Folder name | `istio_svc_mesh_workbook/`, later moved with the observability workbook under `workbooks/` |

## Context that shapes every session

- Starting at Claranet Portugal as a Kubernetes Platform Administrator on
  a critical **OpenShift** platform. OpenShift Service Mesh 3 is upstream
  Istio managed by the **Sail Operator**, with Kiali — so everything
  learned here on upstream Istio transfers, and session 7 covers the
  operator-managed differences.
- Already strong in Kubernetes, Prometheus/Grafana, ArgoCD and GitOps —
  assume competence; no explanations of what a Pod or PromQL is.
- The lab mesh: Istio 1.30.7 sidecar mode + istio-cni, Kiali 2.33.0,
  Bookinfo with a traffic generator, metrics in kube-prometheus-stack,
  Envoy access logs in Loki (ADR-038).
