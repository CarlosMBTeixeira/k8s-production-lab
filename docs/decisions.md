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
[boot]
systemd = true
command = "/usr/local/sbin/multipass-net.sh"
```

The script is idempotent: it uses `iptables -C` to check rule existence
before adding, so repeated executions do not duplicate rules.

**Trade-offs accepted:**
- Lab-local fix. The script hardcodes the subnet `10.163.24.0/24`, which
  is what Multipass assigned on this machine. Not portable to a different
  host without adjustment.
- Acceptable since this lab runs on a single host. Documented here so
  future-me knows where to look if the network silently breaks.

---

## ADR-004: systemd required in WSL2

**Date:** 2026-06-04
**Status:** Accepted

**Context:**
After applying the boot hook from ADR-003 and rebooting WSL2 to test
persistence, Multipass became completely unusable. The error was:

```
internal error: cannot find installed snap "multipass" at revision 17270:
missing file /snap/multipass/17270/meta/snap.yaml
```

`snap list` hung indefinitely. The login banner showed
`* Starting Docker: docker [OK]` — the SysV init format — instead of the
systemd format expected.

**Root cause:**
WSL2 does not run systemd by default; it must be opted into via
`/etc/wsl.conf` with `[boot] systemd = true`. The first version of the
`wsl.conf` written for ADR-003 did not include this line. Without
systemd, the snap layer cannot mount snap squashfs files at boot, so
`/snap/multipass/17270/` exists in metadata but contains no actual files.

**Decision:**
`/etc/wsl.conf` must always include `systemd = true` in the `[boot]`
section. This is a hard requirement for the lab, not a preference.

```ini
[boot]
systemd = true
command = "/usr/local/sbin/multipass-net.sh"

[user]
default = cmbt1
```

**Trade-offs accepted:**
- Slightly higher resource use at WSL2 boot (systemd starts more
  services than SysV). Negligible on this hardware.
- Some legacy WSL2 behaviors change. Not relevant for this lab.

**Recovery procedure** if this is ever broken again:
1. Fix `/etc/wsl.conf` to include `systemd = true`.
2. Run `wsl --shutdown` from PowerShell.
3. Reopen Ubuntu; verify with `ps -p 1 -o comm=` (should return `systemd`).
4. Reinstall Multipass: `sudo snap remove multipass --purge && sudo snap install multipass`.

---

## ADR-005: NOPASSWD sudo for lab nodes

**Date:** 2026-06-04
**Status:** Accepted

**Context:**
The cloud-init template (`cloud-init/node.yaml`) configures the default
`ubuntu` user on every lab VM with `sudo: ALL=(ALL) NOPASSWD:ALL`, meaning
the user can execute any command as root without being prompted for a
password.

In production, `NOPASSWD` is generally avoided: if an attacker compromises
a user session (key leak, hijacked terminal), they gain instant root with
no additional barrier. The conventional production approach requires a
password and stores it in a vault for automation tooling to retrieve when
needed.

**Decision:**
Accept `NOPASSWD:ALL` for all lab nodes.

**Rationale:**
- Ansible drives all provisioning in this lab. Non-interactive `sudo` is
  required for Ansible playbooks to be idempotent and unattended.
- Without `NOPASSWD`, every playbook run would either prompt for a
  password (defeating automation) or require a vault setup whose
  complexity is disproportionate to a personal lab.

**Mitigations in place:**
- `lock_passwd: true` in cloud-init disables password-based SSH login
  entirely. The only way into a VM is the lab-dedicated SSH key
  (`~/.ssh/k8slab`).
- The SSH key is dedicated to this lab and not reused for any other
  account or system. If leaked, the blast radius is the lab itself.
- VMs live on the WSL2 internal NAT segment, not directly exposed to
  the home LAN or the internet.

**Production note:**
A production deployment would require sudo password and store the
automation credential in a vault (HashiCorp Vault, Ansible Vault,
External Secrets Operator, etc.). The lab does not adopt this pattern
because the iteration speed cost outweighs the marginal security gain
in an isolated lab environment.