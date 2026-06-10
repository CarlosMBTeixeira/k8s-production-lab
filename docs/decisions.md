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
- VMs live on the WSL2 internal NAT segment (`10.x.y.0/24`), not the
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
**Status:** ⚠️ SUPERSEDED by ADR-009 (2026-06-06)

**Context:**
After installing Multipass inside WSL2 and launching a test VM, the VM
received an IP address from Multipass's `mpqemubr0` bridge but had no
internet connectivity. `ping 8.8.8.8` from inside the VM returned 100%
packet loss. The WSL2 host had `ip_forward=1` and the Multipass bridge
was correctly configured.

**Original (incorrect) root cause analysis:**
Multipass writes its MASQUERADE and FORWARD rules to the `iptables-legacy`
backend, and we assumed the WSL2 kernel was only consulting `iptables-nft`,
making the legacy rules invisible.

**Original decision:**
A boot script `/usr/local/sbin/multipass-net.sh` writes both MASQUERADE
and FORWARD rules directly to `iptables-nft` on every WSL2 start, with a
hardcoded subnet `10.163.24.0/24`. Registered via `/etc/wsl.conf` boot
command.

**Why superseded:**
Experimental investigation on 2026-06-06 showed the analysis was partially
wrong: MASQUERADE in nft was redundant (Multipass's legacy rules were in
fact being consulted), and the subnet was not stable across Multipass
daemon restarts. The real missing piece was the FORWARD ACCEPT rules.
See ADR-009 for the refined understanding.

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

---

## ADR-006: Template rendering with envsubst (not yq/jq/sed)

**Date:** 2026-06-06
**Status:** Accepted

**Context:**
The cloud-init template needs per-VM customization (hostname today,
potentially more variables later). Three candidate approaches were
considered: sed with custom placeholder strings, envsubst with shell
variable conventions, or yq for native YAML manipulation.

**Decision:**
Use `envsubst` with shell-convention `${VARIABLE}` placeholders. The
launch script restricts envsubst to substitute only the variables it
explicitly cares about, leaving all other content untouched.

**Rejected alternatives:**
- **sed:** Works but uses a custom placeholder convention
  (`CHANGE_PER_NODE`) that requires explanation. Does not scale cleanly
  to multiple variables — each new variable means a new sed expression
  in the script.
- **yq:** The tool of choice for editing YAML structure, but it
  re-serializes the document on write — loses comments, may reorder
  keys, alters quote style. Inappropriate for versioned templates that
  must stay byte-stable.
- **jq:** JSON-only. Would require yaml→json→yaml round-trips, losing
  formatting and adding accidental complexity for no gain.

**Why envsubst:**
- Standard Unix utility (`gettext-base`), already in Ubuntu by default.
- `${VARIABLE}` is universal shell convention; self-explanatory to any
  engineer reading the template, no project-specific glossary required.
- Pure text substitution preserves formatting, comments, and structure
  exactly as written.
- Scales naturally to multiple variables without changing approach.

---

## ADR-007: Visual log style for scripts

**Date:** 2026-06-06
**Status:** Accepted

**Context:**
Scripts in `scripts/` produce log output during execution. Plain `echo`
lines mixed with tool output (Multipass, Ansible, etc.) become hard to
scan visually, especially when running multiple operations in sequence
or scrolling back through long sessions.

**Decision:**
All informational `echo` messages in lab scripts use the following
pattern:

```bash
echo "|---------------------------------------------------------------------------"
echo "| <message>"
echo "|---------------------------------------------------------------------------"
```

Section dividers make script phases visually distinct from tool output
and make scrollback navigation faster.

**Scope:**
- Applies to: contents of `scripts/`, future Ansible debug messages,
  validation scripts.
- Does not apply to: in-code comments, error messages from variable
  expansion (`${var:?msg}`), or strings inside configuration files.

---

## ADR-008: Render cloud-init to project-local path, not /tmp

**Date:** 2026-06-06
**Status:** Accepted

**Context:**
The first version of `launch-node.sh` used `mktemp` to render the
cloud-init template into `/tmp` before passing it to Multipass. Multipass
rejected every attempt with:

```
Could not load cloud-init configuration: bad file: /tmp/tmp.X.yaml.
Please ensure that Multipass can read it.
```

**Root cause:**
Multipass is installed as a snap on Ubuntu. Snaps run under strict
confinement with limited filesystem access. The user's `/tmp` is not in
the default access profile for the multipass snap. The files exist on
disk with correct permissions, but the multipassd process cannot reach
them.

**Decision:**
Render the cloud-init template to `cloud-init/.rendered/<hostname>.yaml`
inside the project directory. The `.rendered/` folder is gitignored.
Snap confinement allows access to `$HOME` paths, so files here are
readable by multipassd.

The script uses a trap-based cleanup to remove the rendered file when
the script exits (success or error), preventing accumulation of stale
files in the project tree.

**Trade-offs:**
- Rendered files briefly live in the project tree instead of `/tmp`.
  The trap-based cleanup mitigates this.
- The `.rendered/` directory must exist before rendering; `mkdir -p`
  in the script handles this on every run.

**Reference:** Snap confinement rules for the multipass snap, which
only expose specific filesystem paths to the multipassd daemon.

---

## ADR-009: Multipass networking in WSL2 — refined understanding

**Date:** 2026-06-06
**Status:** Accepted
**Supersedes:** ADR-003

**Context:**
ADR-003 introduced a boot hook to write MASQUERADE rules into
`iptables-nft`, on the assumption that the absence of those rules was
the reason VMs lost internet. While provisioning `controlplane-1`, the
actual rule state in both backends was inspected and the diagnosis was
refined through experimental confirmation.

**Findings:**
- Multipass 1.16.3 writes its own MASQUERADE rules into
  `iptables-legacy` on daemon startup. Active packet counters confirm
  these rules are processing real traffic; they are not stale.
- Removing the MASQUERADE rules from `iptables-nft` has no effect on VM
  connectivity. The nft MASQUERADE was redundant from day one.
- Removing the `FORWARD ACCEPT` rules for `mpqemubr0` (in/out)
  immediately breaks VM internet within seconds.
- The Multipass-assigned subnet on `mpqemubr0` is not stable across
  daemon restarts. The original boot hook had a hardcoded subnet
  (`10.163.24.0/24`), which silently became wrong after the daemon
  reassigned the bridge to `10.215.138.0/24` between sessions.

**Real root cause:**
WSL2's nft `FORWARD` chain does not accept traffic through the
`mpqemubr0` bridge by default. Without explicit accept rules for that
interface, packets are dropped between the bridge and the WSL2 outbound
interface, regardless of MASQUERADE state. NAT is handled by Multipass
via the legacy backend and works correctly without our help.

**Decision:**
The boot hook (`/usr/local/sbin/multipass-net.sh`) is retained but
simplified:

- Writes only the two `FORWARD ACCEPT` rules in nft (`-i mpqemubr0`
  and `-o mpqemubr0`).
- No MASQUERADE rule — left to Multipass in the legacy backend.
- No hardcoded subnet — `FORWARD` rules are per-interface, so they work
  regardless of which subnet Multipass picks.
- Waits up to 10 seconds for `mpqemubr0` to exist before applying rules,
  to handle the case where the boot hook runs before multipassd has
  finished initializing.
- Idempotent (`iptables -C` checks before each `-A`).

The hook is registered via `/etc/wsl.conf`:

```ini
[boot]
systemd = true
command = "/usr/local/sbin/multipass-net.sh"

[user]
default = cmbt1
```

A copy of the hook is versioned in `scripts/system/multipass-net.sh`
so it can be reinstalled on a fresh setup.

**Confirmed experimentally:**
- `wsl --shutdown` → reopen → boot hook reapplies `FORWARD` rules
  automatically; VMs persist (Multipass state survives WSL2 restart)
  and keep internet without manual intervention.

**Lesson learned:**
On Day 1, two infrastructure changes were applied simultaneously to fix
the no-internet symptom: enabling `net.ipv4.ip_forward` and adding both
MASQUERADE+FORWARD rules in nft. The credit was assigned globally to
"the iptables fix", but the actual contribution per change was never
isolated. MASQUERADE in nft was always redundant. Diagnostic counters
(`pkts=N`) on the legacy MASQUERADE rule were visible from Day 1 and
should have prompted the investigation done in this session.

**Discipline going forward:**
When applying multiple infrastructure changes to fix a problem, isolate
which one actually fixed it before declaring the workaround correct.
Otherwise you carry unnecessary complexity for the life of the project.

---

## ADR-010: Passwordless sudo for iptables on the WSL2 host

**Date:** 2026-06-07
**Status:** Accepted

**Context:**
The `morning-check.sh` script needs to verify iptables FORWARD rules on
`mpqemubr0` at the start of each session. Without passwordless sudo for
`iptables`, the script either prompts for a password mid-execution
(which breaks non-interactive use) or has its sudo prompt swallowed by
output redirection (causing false negatives).

The same problem will recur with any future automation that needs to
inspect or modify iptables rules — Ansible playbooks, validation
scripts, the lab-management.sh wrapper, etc.

**Decision:**
Configure passwordless sudo specifically for the `iptables` binary via
`/etc/sudoers.d/iptables-nopass`:

```
$USER ALL=(ALL) NOPASSWD: /usr/sbin/iptables
```

Applied with:

```bash
echo "$USER ALL=(ALL) NOPASSWD: /usr/sbin/iptables" | sudo tee /etc/sudoers.d/iptables-nopass
sudo chmod 0440 /etc/sudoers.d/iptables-nopass
```

**Why scoped to iptables only:**
Unlike the `NOPASSWD:ALL` rule in cloud-init (ADR-005, scoped to lab
VMs), this rule is on the WSL2 host. Granting passwordless sudo for
all commands on the host would be excessive. Scoping to iptables only
allows automation without widening the privilege footprint beyond what
is needed.

**Mitigations:**
- Rule lives in `/etc/sudoers.d/` (not the main sudoers), making it
  trivial to remove with `sudo rm /etc/sudoers.d/iptables-nopass`.
- Only the iptables binary is exempted; all other sudo commands still
  require a password.
- This is the WSL2 host, not directly exposed to the internet.

**Production note:**
In production, network rules are typically managed by configuration
management (Ansible, Salt, Puppet) under their own privilege model,
not via direct sudo. This trade-off is specific to interactive lab
work where speed of iteration matters more than strict privilege
separation.

---

## ADR-011: Provision automation user via cloud-init, not Ansible playbook

**Date:** 2026-06-12
**Status:** Accepted
**Supersedes:** Behavior implied by playbook 02-ansible-user.yml

**Context:**
The initial setup in Week 2 used playbook `02-ansible-user.yml` to create
a dedicated 'ansible' user on each lab node, with sudo and the lab SSH
key. The inventory was then updated to use `ansible_user=ansible`.

This worked, but introduced a circular dependency: when VMs are destroyed
and recreated (via `lab-management.sh rebuild`), the cloud-init only
creates the 'ubuntu' user. Ansible then tries to connect as 'ansible',
fails with `Permission denied (publickey)`, and `02-ansible-user.yml`
cannot run because Ansible cannot reach the hosts.

The workaround required manual intervention:

    ansible-playbook 02-ansible-user.yml -e ansible_user=ubuntu

This breaks the "destroy and rebuild with one command" property that
the lab aims for.

**Decision:**
Move the creation of the 'ansible' user to the cloud-init template
(`cloud-init/node.yaml`). The user is now provisioned on first boot,
alongside 'ubuntu', with the same SSH key and sudo configuration.

The playbook `02-ansible-user.yml` is retained as a state-verification
mechanism: running it on a freshly built VM reports `changed=0` for all
tasks (idempotent), confirming that cloud-init applied the configuration
correctly.

**Why this is better:**
- Reproducibility: `lab-management.sh build` produces nodes already
  reachable by Ansible, with no manual bootstrap step.
- Mirrors production patterns: in cloud environments (AWS, Azure, GCP),
  the automation user is typically created at instance launch via
  cloud-init or a baked image, not via a post-boot configuration tool.
- Defense in depth: cloud-init provisions the user; the playbook
  validates the state. Two layers, both idempotent.

**Lesson:**
Bootstrap dependencies are easy to miss when first building a system.
The initial test worked because the user 'ubuntu' was still available
as a fallback in the inventory. The dependency only became visible when
the inventory was switched to the new user, and the test was only
exposed when VMs were recreated from scratch.

When designing automation that depends on state, ask: "What does this
need that doesn't exist yet?" The answer often reveals a hidden
bootstrap step that should be moved earlier in the chain.
