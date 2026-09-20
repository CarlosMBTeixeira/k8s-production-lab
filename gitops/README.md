# gitops/ — desired state

What ArgoCD reconciles. Everything here is applied by a controller; **do
not `kubectl apply` anything in this tree by hand.** The one exception is
`../kubernetes/manifests/argocd/apps/root-app.yaml`, the App-of-Apps
root, which is the single object ever applied manually.

```
gitops/
├── apps/root/              Application manifests — adopted by the root App-of-Apps
├── observability/          dashboards, alert rules, chart values  (sessions 2–4)
└── environments/overlays/  simulated dev/staging/prod             (session 5)
```

Source of truth for ArgoCD is this repo on
`feature/argo-and-observability-study`. A change here is live once ArgoCD
polls the repo — default `timeout.reconciliation` is 180s, so allow up to
three minutes, or force it with `argocd app sync <name>`.

Sits beside the infra-as-code rather than in a separate repo. That is a
deliberate simplification for this study block — see `observability_workbook/README.md`.
