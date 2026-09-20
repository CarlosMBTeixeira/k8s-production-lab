# The brief

The original statement of what this workbook is for, kept because the
sessions are answers to it and drift is easy once the exercises start.

## Situation

Cloud/DevOps engineer, ~4 years. Leaving a job; starting **19 October
2026** at Claranet Portugal as a **Kubernetes Platform Administrator** on
a critical **OpenShift** platform — GitOps via ArgoCD, Helm/Operators,
observability (Prometheus, Grafana, Elasticsearch/Loki).

CKS study runs on a **separate** plan, with separate material
(KillerKoda, killer.sh). This workbook is about being productive on the
new platform, not about an exam syllabus.

## Already strong — apply, don't teach

Kubernetes in production for years (CKA; RKE2 on-prem, AKS). Prometheus +
Grafana in production, including dashboards and alerts **as code** —
JSON files pushed into clusters by a GitLab CI pipeline. Installing the
stack with the `kube-prometheus-stack` Helm chart. PromQL, written
fluently. Terraform, Azure, Azure DevOps, GitLab CI.

## The actual gaps

1. **Loki as a datasource + LogQL.** The difficulty is specifically
   Grafana with a datasource that is not Prometheus. Loki has never been
   configured properly, and LogQL has never been written.
2. **The *pull* model for dashboards and alerts.** The push version
   (GitLab CI applying JSON) is familiar. ArgoCD reconciling — auto-sync,
   `selfHeal`, drift detection — has never been done. "I would adapt
   easily" is the claim; this is where it gets proved rather than
   asserted.
3. **OpenShift, never touched directly.** Platform-managed monitoring is
   a different model from installing your own `kube-prometheus-stack`,
   and native logging (LokiStack) is a different model from self-hosted
   Loki.
4. **ArgoCD beyond the basics.** Installation, Application CRD, sync
   policies, Helm/Kustomize sources, health checks and App-of-Apps are
   done. Missing: ApplicationSets + sync waves in a multi-environment
   scenario, and secrets in GitOps end-to-end with External Secrets
   Operator.

## Constraints

- **No video courses.** Not for the new topics, not as reinforcement.
  The base is already there; what is needed is specific official
  documentation plus hands on the cluster. Sources: Grafana Labs for
  LogQL, the ArgoCD *Operator Manual* / *User Guide*, Red Hat product
  documentation for OpenShift. Never a video link.
- **No repeating basic ArgoCD.**
- **No mixing with the CKS syllabus.** Noting where this work also
  reinforces it (Network Policies, Pod Security) is fine; teaching it
  here is not.
- **Exercises, not theory.** Every unit: *hypothesis → tool → what I
  expect to see if I'm right → what would have caught this sooner*, with
  a verifiable done-criterion.
- **Every session ends in a runbook**: `symptom → tool → cause → fix`,
  plus a column for *what would have told me this first*. These are meant
  to be used at Claranet, not to record progress.
- **No fixed calendar.** Scheduling is handled elsewhere. What was needed
  here is the structure of the exercises, ready to execute when a block
  of time exists.
