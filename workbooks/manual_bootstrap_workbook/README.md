# Runbook — Build the cluster by hand

Builds the lab's Kubernetes cluster from nothing, typing every command
yourself: no lab scripts, no Ansible, no cloud-init templates.

**End state:** 4 VMs, 2 control planes and 2 workers, all `Ready`, with
an HA API endpoint (kube-vip) and Calico networking.

```
                    VIP 10.215.138.200:6443 (kube-vip)
                     /                         \
          controlplane-1                  controlplane-2
          (etcd, API server, ...)         (etcd, API server, ...)
                     \                         /
                worker-1                 worker-2
```

The versions and settings match what the automated pipeline installs,
so a manual build and a `main.sh` build produce the same cluster. If the
two ever disagree, the automation (`ansible/`) is the reference.

---

## Starting point

- WSL2 Ubuntu with Multipass installed and working (`multipass list`
  runs without error).
- No lab VMs exist. If old ones are around: `multipass delete --purge
  controlplane-1 controlplane-2 worker-1 worker-2`.
- About 16 GB of free RAM for the VMs (4 × 4 GB).

## Stages

Do them in order. Each one ends with a **Check** — don't move on until
it passes.

| # | Stage | Runs on | Result |
|---|---|---|---|
| 1 | [Create the VMs](01-create-vms.md) | WSL host | 4 VMs running |
| 2 | [Prepare every node](02-prepare-nodes.md) | all 4 VMs | containerd + kubeadm/kubelet/kubectl installed |
| 3 | [Floating API address (kube-vip)](03-kube-vip.md) | both control planes | kube-vip manifest in place |
| 4 | [Start the cluster on controlplane-1](04-init-controlplane-1.md) | controlplane-1 | 1 node, `NotReady` |
| 5 | [Pod network (Calico)](05-calico.md) | controlplane-1 | 1 node, `Ready` |
| 6 | [Join controlplane-2](06-join-controlplane-2.md) | both control planes | 2 control planes `Ready` |
| 7 | [Join the workers and final check](07-join-workers.md) | all | 4 nodes `Ready`, test pod runs |

## Versions

| Component | Version | Defined in |
|---|---|---|
| Ubuntu (VMs) | 24.04 | `scripts/launch-node.sh` |
| Kubernetes (kubeadm, kubelet, kubectl) | 1.35.6 (`1.35.6-1.1`) | `ansible/roles/kubernetes-repo/defaults/main.yml` |
| containerd | latest `containerd.io` from Docker's repo | `ansible/roles/containerd-install/defaults/main.yml` |
| pause (sandbox) image | 3.10 | `ansible/roles/containerd-configure/defaults/main.yml` |
| crictl | v1.35.0 | `ansible/roles/runtime-tools/defaults/main.yml` |
| kube-vip | v1.3.1 | `ansible/roles/kube-vip/defaults/main.yml` |
| Calico | v3.33.0 | `ansible/roles/cni-calico/defaults/main.yml` |

When a version changes in `ansible/`, change it here in the same commit.

## Conventions

- **Where to run.** Every code block starts with a comment saying where
  it runs: `# WSL host`, or a VM name. To get a shell on a VM:
  `multipass shell controlplane-1`.
- **"On every node"** means repeat the block on all 4 VMs. Opening four
  terminals, one `multipass shell` each, is the easiest way.
- **Addresses.** The examples use the lab's bridge subnet
  `10.215.138.0/24` and the VIP `10.215.138.200`. If `multipass list`
  shows a different subnet on your host, use yours.
- **Node names.** VMs are `controlplane-1`, `controlplane-2`,
  `worker-1`, `worker-2`. Multipass sets each hostname from the VM name.

## Starting over

```bash
# WSL host
multipass delete --purge controlplane-1 controlplane-2 worker-1 worker-2
```

Then begin again at stage 1.
