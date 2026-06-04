# Kubernetes Production-Grade Lab

End-to-end Kubernetes lab built from scratch on local hardware, as preparation
for the CKA certification and as a demonstrable portfolio project for DevOps work.

## Stack
- **Host:** HP OMEN 16-ap0xxx (Ryzen 9 8940HX, 24 GB RAM, Windows 11 Home)
- **Virtualization:** WSL2 (Ubuntu 24.04) with nested KVM → Multipass VMs
- **Cluster:** 4 nodes (2 control plane + 2 workers), kubeadm-based HA
- **Tooling:** Ansible (provisioning), ArgoCD (GitOps), Rancher (management),
  Prometheus + Grafana + Loki (observability), Cert-Manager + Network Policies
  + External Secrets + Pod Security (security layer)

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

## Roadmap (8 months)

| Month | Focus |
|---|---|
| June 2026 | Provisioning automation (Multipass + Ansible) |
| July 2026 | kubeadm HA cluster + **CKA exam** |
| August 2026 | Vacation |
| September 2026 | Rancher + ArgoCD + Observability stack |
| October 2026 | Security layer + portfolio close |
| November 2026 | Terraform AI agent (separate project) |

## Status
- [x] Day 1: WSL2 + Multipass + KVM foundation validated
- [ ] Week 1: 4 VMs provisioned with Ansible-ready setup
- [ ] Week 2: Ansible essentials and node prerequisites
- [ ] Week 3: containerd installed and configured
- [ ] Week 4: kubeadm/kubelet/kubectl ready for cluster bootstrap