# Architecture Decision Records

This document tracks significant architectural decisions made during the lab.
Each ADR captures the context, the decision, alternatives considered, and the
trade-offs accepted.

---

## ADR-001: Virtualization path

**Date:** 2026-05-30
**Status:** Accepted

**Context:**
Need to run 4 Linux VMs on a Windows 11 Home laptop (HP OMEN, Ryzen 9 8940HX,
24 GB RAM) to build a Kubernetes lab. Windows 11 Home does not include the
Hyper-V role, which is the standard path for VM workloads on Windows.

**Decision:**
Run Multipass inside WSL2 with KVM nested virtualization. WSL2 is configured
with `nestedVirtualization=true` in `.wslconfig`, which exposes `/dev/kvm`
inside the WSL2 kernel. Multipass uses its QEMU backend (`local.driver=qemu`)
to launch VMs through KVM.

**Rejected alternatives:**
- **Windows 11 Pro + Hyper-V backend.** Cleanest path technically, but
  the ~145€ upgrade cost was not justified for a personal lab.
- **Multipass on Windows with VirtualBox backend.** Free, but bridged
  networking requires `psexec` workarounds, and VirtualBox runs in a
  degraded mode alongside the Windows Hypervisor Platform that WSL2
  already requires. Higher friction than the chosen path.

**Trade-offs accepted:**
- VMs live on the WSL2 internal NAT segment (`10.163.24.0/24`), not the
  home LAN. Acceptable for June (Ansible-only work), but requires
  revisiting before July Week 1, when kube-vip needs LAN-level reachability.
- Performance is slightly below native Hyper-V due to the additional
  nesting layer. Not a concern at this lab's scale.

---

## ADR-002: Bridged-to-LAN for kube-vip — DEFERRED

**Date:** 2026-05-30
**Status:** Open (deferred decision)

**Context:**
The lab targets a kubeadm HA cluster with kube-vip providing a virtual IP
for the control plane. kube-vip in ARP mode (the default and simplest)
requires all control plane nodes to share a broadcast domain with a free
LAN IP. The WSL2 internal NAT network used today does not provide this:
VMs are isolated from the home LAN, behind WSL2's NAT.

**Decision:**
Deferred until before July Week 1. Three options to evaluate when the time
comes:

1. **kube-vip in BGP mode.** Avoids the ARP requirement entirely. More
   complex to set up but works without LAN-level VM exposure.
2. **Expose VMs to LAN via Windows Hypervisor Platform bridge.** Configure
   a bridge on the Windows host that the WSL2 VMs can use, giving each VM
   a real LAN IP. Closer to production semantics.
3. **Single control plane node for July.** Skip HA entirely until
   September, when the bridged networking question can be answered with
   more lead time.

**Why deferred:**
The decision does not block June work (Ansible provisioning, container
runtime setup, kubeadm binaries). Forcing the decision now would require
weeks of preparation work that has nothing to do with June's goals.

---

## ADR-003: Multipass NAT in WSL2 — boot hook required

**Date:** 2026-06-04
**Status:** Accepted (workaround in place)

**Context:**
After installing Multipass inside WSL2 and launching a test VM, the VM
received an IP address from Multipass's `mpqemubr0` bridge but had no
internet connectivity. `ping 8.8.8.8` from inside the VM returned 100%
packet loss. The WSL2 host had `ip_forward=1` and the Multipass bridge
was correctly configured.

**Root cause:**
Multipass writes its MASQUERADE and FORWARD rules to the `iptables-legacy`
backend, but the WSL2 kernel uses `iptables-nft`. The rules exist but are
in the wrong table, so the kernel never consults them for actual packet
forwarding. This is a known incompatibility between Multipass's assumptions
and modern WSL2 kernels.

**Decision:**
A boot script `/usr/local/sbin/multipass-net.sh` writes the required rules
directly to `iptables-nft` on every WSL2 start. The script is registered
via `/etc/wsl.conf`:

```ini