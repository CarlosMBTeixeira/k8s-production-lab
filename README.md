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
- [x] June Week 1: 4 VMs provisioned with Ansible-ready setup
- [x] June Week 2: Ansible essentials and node prerequisites
- [x] June Week 3: containerd installed and configured
- [x] June Week 4: kubeadm/kubelet/kubectl ready for cluster bootstrap
- [x] July Week 1: kubeadm HA control plane bootstrapped and validated (kube-vip VIP, 2 control planes + 2 workers, Calico CNI)
- [x] July Week 1 (extra): Gateway API + MetalLB smoke test, replacing nginx+NodePort (ingress-nginx EOL 2026-03-31)
- [x] July Weeks 2-4: CKA exam preparation completed, exam passed
