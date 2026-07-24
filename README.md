# Kubernetes Production-Grade Lab

End-to-end Kubernetes lab built from scratch on local hardware, as preparation
for the CKA certification and as a demonstrable portfolio project for DevOps work.

## Stack
- **Host:** HP OMEN 16-ap0xxx (Ryzen 9 8940HX, 24 GB RAM, Windows 11 Home)
- **Virtualization:** WSL2 (Ubuntu 24.04) with nested KVM → Multipass VMs
- **Cluster:** 4 nodes (2 control plane + 2 workers), kubeadm-based HA, Kubernetes 1.35
- **Networking:** Calico (CNI), Gateway API via Envoy Gateway + MetalLB (LoadBalancer/ingress,
  replacing ingress-nginx after its 2026-03-31 EOL), Kubernetes NetworkPolicy
  for default-deny network segmentation (ADR-034)
- **Applications:** installed via Helm charts sourced from Artifact Hub (ADR-030) —
  ArgoCD (GitOps), Rancher (cluster management), kube-prometheus-stack
  (Prometheus + Grafana + Alertmanager, ADR-031), Loki + Grafana Alloy
  (log aggregation, ADR-032), cert-manager (real TLS via Let's Encrypt +
  Cloudflare DNS-01, ADR-033)
- **Tooling:** Ansible (provisioning), Helm, ArgoCD, Rancher, Prometheus/Grafana/Loki, cert-manager
- **RAM constraint:** the host only comfortably runs one application
  (Rancher, ArgoCD, or the observability stack) at a time until more RAM
  is added later this year (ADR-031) — `main.sh` prompts for which one
  to install each run
- **Deferred to CKS study:** External Secrets Operator, Pod Security
  Standards, and RBAC -- deliberately out of scope for this v1 (see Roadmap)

## Architecture

```
Windows 11 Home
└── WSL2 Ubuntu 24.04 (20 GB RAM, nested virt)
    └── Multipass (KVM backend)
        ├── cp1   (4 GB, 2 vCPU) — control plane
        ├── cp2   (4 GB, 2 vCPU) — control plane
        ├── w1    (4 GB, 2 vCPU) — worker
        └── w2    (4 GB, 2 vCPU) — worker
```

## Running the lab

The lab is destroyed and rebuilt from scratch every session — nothing is
left running between uses.

```bash
# 1. Build/rebuild the 4 VMs, fix WSL2/Docker networking, sync SSH config,
#    run a health check. Safe to run repeatedly.
./scripts/lab-management.sh rebuild --force

# 2. Provision Kubernetes + Gateway API/MetalLB, then pick ONE application
#    to install (Rancher / ArgoCD / Observability) — the RAM budget
#    doesn't comfortably fit more than one at once (ADR-031).
bash scripts/pipeline/main.sh
```

### Accessing lab UIs from Windows

Two options, both documented in ADR-029:

- **SSH tunnel (always works, no setup):**
  `./scripts/tunnels/rancher-tunnel.sh` / `argocd-tunnel.sh` / `grafana-tunnel.sh`,
  then browse to `https://localhost:<port>/`.
- **Direct IP access (faster, needs one setup step per Windows session):**
  run `scripts/windows/setup-route.ps1` once from an elevated PowerShell
  after each Windows/PC restart (it self-elevates and figures out the
  current WSL2 IP automatically), then browse straight to the Gateway's
  IP (`kubectl get gateway -A` to find it).

Both the Windows route and the WSL2-side firewall rules that direct
access depends on are non-persistent — `setup-route.ps1` and
`scripts/fix-network-access.sh` (run automatically by
`lab-management.sh`) need to (re)run every session, which is why the
tunnel remains the default fallback.

### Health check

```bash
bash scripts/morning-check.sh
```

Run automatically at the end of `lab-management.sh build`/`rebuild`, or
standalone any time to check current state.

## GitOps repo

Kubernetes manifests deployed through ArgoCD live in a separate repo,
[k8s-gitops](https://github.com/CarlosMBTeixeira/k8s-gitops) — kept apart
from this repo on purpose (infra-as-code vs. desired state), matching the
author's day-job GitOps setup.

## Roadmap

| Month | Focus |
|---|---|
| June 2026 | Provisioning automation (Multipass + Ansible) |
| July 2026 | kubeadm HA cluster + **CKA exam** + Rancher + ArgoCD + observability stack + Loki + cert-manager + Network Policies |

Originally scoped as an 8-month build (June-October 2026, with a security
layer closing it out in October). Closed instead in July -- cert-manager,
Network Policies, and the full observability stack (Prometheus, Grafana,
Alertmanager, Loki, Alloy) all landed the same month as Rancher and
ArgoCD, months ahead of schedule. External Secrets, Pod Security
Standards, and RBAC were deliberately left out of this v1 -- better
suited to dedicated CKS study than added here just to fill a checklist.

## Status
- [x] WSL2 + Multipass + KVM foundation validated
- [x] 4 VMs provisioned with Ansible-ready setup
- [x] Ansible essentials and node prerequisites
- [x] containerd installed and configured
- [x] kubeadm/kubelet/kubectl ready for cluster bootstrap
- [x] kubeadm HA control plane bootstrapped and validated (kube-vip VIP, 2 control planes + 2 workers, Calico CNI)
- [x] Gateway API + MetalLB smoke test, replacing nginx+NodePort (ingress-nginx EOL 2026-03-31)
- [x] CKA exam preparation completed, exam passed
- [x] Cluster rebuilt from scratch on Kubernetes 1.35 (ADR-025)
- [x] Rancher installed via Helm (rancher-stable), exposed through a dedicated Gateway API resource (ADR-026–028)
- [x] Windows access to lab UIs — SSH tunnel (default) and direct IP access (ADR-029)
- [x] Helm charts from Artifact Hub established as the standard for all application installs (ADR-030); ArgoCD is the first application under this policy
- [x] WSL2/Multipass networking fully automated — Docker DOCKER-USER chain, Multipass inbound-connection rule, and the Windows-side route are all scripted and idempotent (ADR-029 resolved)
- [x] ArgoCD GitOps mechanics learned end-to-end — separate manifests repo, first Application, manual sync, auto-sync + self-heal (verified via live drift test), rollback via `git revert`
- [x] kube-prometheus-stack (Prometheus + Grafana + Alertmanager) installed via Helm, sized to the lab's RAM budget (ADR-031); `main.sh` prompts for exactly one application per install run, since Rancher + ArgoCD + observability don't comfortably coexist yet
- [x] Loki + Grafana Alloy installed for log aggregation, wired into the existing Grafana via `additionalDataSources` (ADR-032); replaces Promtail, which reached EOL 2026-03-02
- [x] cert-manager installed as unconditional cluster infra, with a `letsencrypt-k8slab` ClusterIssuer for Let's Encrypt via Cloudflare DNS-01 (ADR-033); validated end-to-end with a real issued certificate
- [x] Network Policies applied to the monitoring namespace (default-deny + 12 explicit allows, ADR-034); validated against Prometheus's own /targets page, not just pod status

## Known issues
- VM guest clocks can silently drift under host CPU pressure even while
  `timedatectl` reports synchronized. Automated: `scripts/fix-vm-clocks.sh`
  runs on every `lab-management.sh build`/`rebuild`, and `morning-check.sh`
  checks drift on every VM (< 30s threshold) each session.
