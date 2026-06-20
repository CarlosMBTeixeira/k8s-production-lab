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

**References:**
- Microsoft Learn — Advanced settings configuration in WSL
  (`.wslconfig`, including `nestedVirtualization` for L2 hypervisors):
  https://learn.microsoft.com/en-us/windows/wsl/wsl-config
- WSL repository — `wsl-config.md` (source of truth for the
  configuration file format):
  https://github.com/MicrosoftDocs/wsl/blob/main/WSL/wsl-config.md
- Microsoft DevBlogs — Systemd support announcement for WSL2
  (rationale and minimum WSL version required):
  https://devblogs.microsoft.com/commandline/systemd-support-is-now-available-in-wsl/
- linux-kvm.org — Networking model that Multipass's QEMU/KVM backend
  follows on Linux:
  https://www.linux-kvm.org/page/Networking

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

**References:**
- No canonical external reference. This is an internal project
  convention based on the rationale documented above.

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

**References:**
- No canonical external reference. This is an internal project
  convention based on the rationale documented above.

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

**References:**
- Microsoft Learn — `wsl.conf` `[boot]` section (`systemd=true` is
  the supported way to enable systemd on a WSL2 distro):
  https://learn.microsoft.com/en-us/windows/wsl/wsl-config
- WSL repository — `wsl-config.md` (canonical schema for `wsl.conf`):
  https://github.com/MicrosoftDocs/wsl/blob/main/WSL/wsl-config.md
- Microsoft DevBlogs — "Systemd support is now available in WSL"
  (original announcement; requires WSL 0.67.6+ on Windows 11):
  https://devblogs.microsoft.com/commandline/systemd-support-is-now-available-in-wsl/

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

**References:**
- sudoers(5) man page — official syntax for `NOPASSWD` and
  `Cmnd_Spec_List` (Linux manpages canonical source):
  https://www.sudo.ws/docs/man/sudoers.man/
- Ansible — privilege escalation documentation (canonical
  guidance on `become` and password prompts):
  https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_privilege_escalation.html

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

**References:**
- No canonical external reference. This is an internal project
  convention based on the rationale documented above.

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

**References:**
- No canonical external reference. This is an internal project
  convention based on the rationale documented above.

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

**References:**
- No canonical external reference for this decision. It is a local
  project convention. The closest related context is cloud-init's
  user-data schema, which defines what content the rendered files
  must contain:
  https://docs.cloud-init.io/en/latest/reference/yaml_examples/index.html
- Multipass — Launch with cloud-init (where the rendered file is
  ultimately passed):
  https://canonical.com/multipass/docs/launch-cloud-init

---

## ADR-009: Persist iptables FORWARD rules on `mpqemubr0` via boot hook

**Date:** 2026-06-08
**Status:** Accepted

**Context:**
Multipass creates the `mpqemubr0` bridge for its VMs, but doesn't
configure iptables `FORWARD` rules to allow traffic across that bridge
on every Linux backend. On WSL2 specifically, the default `FORWARD`
policy is `DROP`, so VMs created by Multipass have no internet access
until rules are added explicitly:

  iptables -I FORWARD -i mpqemubr0 -j ACCEPT
  iptables -I FORWARD -o mpqemubr0 -j ACCEPT

Running these manually after every `wsl --shutdown` is not acceptable
for a reproducible lab.

**Decision:**
Persist the rules via a boot-time hook. The script
`/usr/local/sbin/multipass-net.sh` re-applies the two `FORWARD` rules
on every WSL2 start, invoked from `/etc/wsl.conf`'s `[boot] command`
directive.

**Why a boot hook rather than iptables-persistent:**
- WSL2's networking and bridge state are torn down on `wsl --shutdown`
  and rebuilt on next start. Saved iptables rules survive a normal
  Linux reboot but not a WSL2 shutdown cycle.
- The boot hook is idempotent (uses `-I` to insert at position 1;
  duplicates are harmless because Multipass tears down `mpqemubr0`
  itself between runs).
- Single source of truth: the script lives in the repo (committed),
  and is installed once. No manual `sudo iptables ...` needed.

**Why not `iptables -P FORWARD ACCEPT`:**
A common shortcut is to set the default policy of the FORWARD chain
to ACCEPT. We rejected this because it removes all default
filtering: any future docker container, container runtime, or other
tool that expects FORWARD = DROP by default would behave unexpectedly.
We add targeted ACCEPT rules and leave the default policy intact.

**References:**
- Multipass / Ubuntu Discourse — Port forwarding with iptables
  (official guidance from Canonical's community hub on inserting
  rules into the FORWARD chain for Multipass VMs):
  https://discourse.ubuntu.com/t/multipass-port-forwarding-with-iptables/18741
- ArchWiki — QEMU advanced networking (bridge + iptables FORWARD
  patterns used by libvirt and Multipass on KVM/QEMU):
  https://wiki.archlinux.org/title/QEMU/Advanced_networking
- linux-kvm.org — Networking (canonical KVM bridge/routing model;
  Multipass's QEMU backend follows this approach):
  https://www.linux-kvm.org/page/Networking

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

**References:**
- sudoers(5) man page — official syntax for `NOPASSWD` directives
  in `/etc/sudoers.d/` drop-in files (this ADR's exact pattern):
  https://www.sudo.ws/docs/man/sudoers.man/
- iptables(8) man page — canonical reference for the `iptables`
  command this rule exempts from password prompts:
  https://man7.org/linux/man-pages/man8/iptables.8.html
- No canonical external reference for "scoped NOPASSWD for a
  specific binary on a development host" as a documented pattern;
  it follows standard Linux administrative conventions.

---

## ADR-011: Provision the `ansible` user via cloud-init, not via playbook

**Date:** 2026-06-10
**Status:** Accepted

**Context:**
Originally, the `ansible-user` playbook (later refactored into a role)
created the `ansible` user, configured passwordless sudo, and authorized
the lab SSH key on each node. This works, but creates a chicken-and-egg
problem: Ansible needs to SSH into the node to create the user that
Ansible should then use.

For the first run, we fall back to the cloud-init default user
(`ubuntu`), which is awkward and requires conditional logic in the
inventory.

**Decision:**
Move user provisioning into the cloud-init configuration that runs at
first boot. The `ansible` user, its SSH authorized_keys, and its
passwordless sudo entry are all written by cloud-init's `users` and
`write_files` modules before the VM is reachable by Ansible.

The Ansible role (`ansible-user`) becomes a validation/idempotence
layer: it confirms the user exists, the SSH key is present, and the
sudoers entry is in place. On a freshly cloud-init'd node, the role
reports `changed=0`. If the state has drifted (e.g. someone removed
the key manually), the role re-establishes it.

**Why cloud-init:**
- Cloud-init's `users` module is the canonical way to provision users
  on cloud / VM images on first boot — it's the same module used by
  every major public-cloud Ubuntu image.
- Removes the chicken-and-egg: the `ansible` user exists before
  Ansible ever needs to connect.
- VM destruction + recreation reproduces the user exactly, with no
  manual step. Reproducibility is preserved.
- Cleaner inventory: `ansible_user: ansible` everywhere, no fallback
  to `ubuntu`.

**Trade-off:**
There is now a known cosmetic non-idempotency: cloud-init writes its
sudoers entry to `/etc/sudoers.d/90-cloud-init-users`, while the role
writes its own to `/etc/sudoers.d/ansible-nopasswd`. The two files
coexist with equivalent content. The role reports `changed` on the
sudoers task during the first ansible run because the second file is
new; subsequent runs report `ok`. We accepted this rather than
removing the cloud-init file (which is owned by cloud-init and could
be re-created on reboot).

**References:**
- cloud-init — Configure users and groups (canonical examples and
  schema):
  https://docs.cloud-init.io/en/latest/reference/yaml_examples/user_groups.html
- cloud-init — Module reference (full module list including
  `cc_users_groups` and `cc_write_files`):
  https://docs.cloud-init.io/en/latest/reference/modules.html

---

## ADR-012: `cache_valid_time` is per-node, not per-orchestration-run

**Date:** 2026-06-15
**Status:** Accepted

**Context:**
Running `site.yml` twice consecutively produced inconsistent results
on the `apt-base : Update apt cache` task:

  - First run:  3 nodes `changed`, 1 node `ok` (w-2)
  - Second run: 3 nodes `ok`, 1 node `changed` (w-2)

Initial suspicion was clock skew or a network glitch. Investigation
revealed neither: it's an artefact of how `cache_valid_time` works.

**Mechanism:**
The Ansible `apt` module uses the mtime of `/var/cache/apt/pkgcache.bin`
to decide whether to refresh the cache. If `(now - mtime) < cache_valid_time`, the task reports `ok`. Otherwise it runs `apt-get
update`, which updates the mtime, and reports `changed`.

In a 4-VM lab, the cloud-init `apt update` runs sequentially across
nodes — VMs are created one at a time. The mtime on each node reflects
when its specific cloud-init finished, which can vary by minutes.

In our setup, the 4 cloud-inits left mtimes spread across ~4 minutes
(05:23 to 05:27). When `site.yml` ran at ~05:23, cp-1/cp-2/w-1 caches
were already over an hour old (refreshed by an even earlier run), so
they were refreshed. w-2's cloud-init finished later (05:27), so its
cache was still within the 3600s window — it skipped refresh.

Two minutes later, on the second `site.yml` run, the three caches just
refreshed were now well inside the window (~2 minutes old), so they
skipped. w-2's cache hadn't been refreshed by the previous run (because
the play decided it was current), so it now showed as ~1h 02m old —
just over the 3600s threshold — and got refreshed.

**Decision:**
Accept this as expected behavior. `cache_valid_time` operates per-node,
not per-orchestration. Achieving lockstep idempotency across nodes
would require either:

  - Synchronizing mtimes externally (fragile, anti-pattern).
  - Increasing `cache_valid_time` to a value much larger than the
    expected interval between runs (e.g., 21600 = 6h).
  - Removing `cache_valid_time` entirely and accepting that `apt
    update` always reports changed (wasteful).

None of these is worth doing for a lab. We document the behavior and
move on.

**Lesson:**
Idempotency in distributed systems is not just about correct module
choice. State that depends on time (timestamps, certificates, caches)
can produce visible drift between nodes that nominally have identical
configuration. This is a feature, not a bug — it accurately reflects
that the nodes are independent systems with their own clocks and
their own cloud-init runs.

This kind of artefact will reappear in K8s: certificate rotation, etcd
leases, kubelet renewals. Understanding "per-node, not per-cluster" is
foundational.

**References:**
- Ansible — `ansible.builtin.apt` module documentation
  (canonical reference for `cache_valid_time` semantics; the
  module checks `/var/cache/apt/pkgcache.bin` mtime locally on
  each host):
  https://docs.ansible.com/ansible/latest/collections/ansible/builtin/apt_module.html
- Ansible issue #79206 — confirms `cache_valid_time` is evaluated
  per-host based on local cache mtime, not orchestration-wide:
  https://github.com/ansible/ansible/issues/79206

---

## ADR-013: Use `SystemdCgroup = true` for containerd

**Date:** 2026-06-20
**Status:** Accepted

**Context:**
Linux has two cgroup drivers used by container runtimes:
  - `cgroupfs` — direct manipulation of /sys/fs/cgroup files.
  - `systemd` — cgroup operations delegated to systemd's slice manager.

Container runtimes (containerd, CRI-O, Docker) historically defaulted
to `cgroupfs`. systemd is also a process supervisor on modern Linux
distributions, and manages cgroups for system services.

If two cgroup managers operate on the same hierarchy simultaneously,
they can fight: one moves a process into a cgroup, the other moves it
out, resources get accounted incorrectly, OOM kills fire unexpectedly.
This violates the "single-writer" rule of cgroups.

In Kubernetes, the kubelet ALSO manages cgroups for pods. If the
kubelet uses one driver and the container runtime uses another, the
two compete for the same hierarchy. This is the single most common
cause of mysterious pod crashes in production K8s clusters.

**Decision:**
Configure containerd to use `SystemdCgroup = true` in
`/etc/containerd/config.toml`. This aligns with the kubelet's default
cgroup driver (also systemd since Kubernetes 1.22).

**Why systemd over cgroupfs:**
- Single source of truth for cgroup operations on Ubuntu 24.04.
- systemd is already PID 1; using it removes one moving part.
- Recommended explicitly by both upstream K8s docs and containerd docs.
- Mandatory for nodes running both systemd and a CRI runtime.

**Implementation:**
Set in the containerd-configure role:
  `containerd_use_systemd_cgroup: true` (defaults/main.yml)

Rendered into `/etc/containerd/config.toml` via the
templates/config.toml.j2 file, with Jinja2 filter chain
`| string | lower` to produce the TOML boolean `true` (lowercase).

**Mitigation if mismatched:**
None easy. Mismatched cgroup drivers manifest as:
  - Pods stuck in "ContainerCreating" indefinitely.
  - Random OOM kills with no apparent memory pressure.
  - "OCI runtime create failed" errors at pod startup.
  - Diagnostic command: `sudo crictl info | grep cgroupDriver`.

The kubelet's setting must match. Both default to systemd today;
if either changes, the other must follow.

**References:**
- Kubernetes — Container Runtimes (official guidance on cgroup drivers):
  https://kubernetes.io/docs/setup/production-environment/container-runtimes/
- Containerd CRI plugin configuration (SystemdCgroup option):
  https://github.com/containerd/containerd/blob/main/docs/cri/config.md
- Kubernetes — Configuring a cgroup driver for kubeadm clusters:
  https://v1-34.docs.kubernetes.io/docs/tasks/administer-cluster/kubeadm/configure-cgroup-driver/
- kubeadm issue #2376 — rationale for defaulting kubelet's cgroupDriver
  to "systemd" since Kubernetes 1.22:
  https://github.com/kubernetes/kubeadm/issues/2376

---

## ADR-014: Containerd socket remains root-only; use sudo for crictl

**Date:** 2026-06-23
**Status:** Accepted

**Context:**
By default, `/run/containerd/containerd.sock` is owned by root:root with
mode 0660 — only root can connect to it. Running `crictl` as a regular
user fails with:

  `dial unix /run/containerd/containerd.sock: connect: permission denied`

There are two ways to allow non-root access:
1. Always invoke `crictl` via `sudo` (the standard approach).
2. Add the user to a group that owns the socket, and configure containerd
   to set group ownership accordingly.

Option 2 looks convenient but has a significant security implication:
any user with access to the containerd socket can create privileged
containers, mount host paths, and effectively gain root on the host.
The socket is a root-equivalent control channel — this is why Kyverno
publishes a "Disallow CRI socket mounts" cluster policy as a best
practice, treating socket exposure as privilege escalation.

**Decision:**
Keep the containerd socket root-only. All `crictl` operations require
`sudo`. Document this convention so future debug sessions don't waste
time on "permission denied" errors.

The Ansible role validates `crictl` with `become: true` (already running
as root via sudo), so the role's post-condition still passes correctly.

**Why this matches production:**
- Kubernetes nodes in production are operated via the kubelet, which
  runs as root and connects to the socket directly.
- Human operators using `crictl` are typically site reliability
  engineers or platform engineers who already have sudo on the node.
- Containerd documentation explicitly recommends against widening
  socket access in shared or multi-tenant environments.

**Consequence:**
Examples of correct usage:

    ssh cp-1 "sudo crictl version"
    ssh cp-1 "sudo crictl pull registry.k8s.io/pause:3.10"
    ssh cp-1 "sudo crictl images"

Running `crictl` without sudo will fail with a "permission denied"
error on the socket. This is expected and not a misconfiguration.

**Related technical debt (not blocking):**
The `unarchive` task in the runtime-tools role uses `creates:` for
idempotency. This means upgrading `crictl` to a newer version requires
explicitly removing `/usr/local/bin/crictl` first, or the upgrade is
silently skipped. To be addressed when the first version upgrade is
needed.

**References:**
- Kubernetes — Container Runtimes (canonical socket paths,
  including `/run/containerd/containerd.sock` for containerd):
  https://kubernetes.io/docs/setup/production-environment/container-runtimes/
- Kubernetes — Container Runtime Interface (CRI) overview:
  https://kubernetes.io/docs/concepts/containers/cri/
- Kyverno — "Disallow CRI socket mounts" best-practice policy
  (rationale for socket-as-privilege-escalation):
  https://kyverno.io/policies/best-practices/disallow-cri-sock-mount/
- Containerd CVE-2024-25621 — historical incident showing why
  socket/directory permissions matter for runtime security:
  https://zeropath.com/blog/containerd-cve-2024-25621-summary

---

## ADR-015: Pin Kubernetes packages with `apt-mark hold`

**Date:** 2026-06-24
**Status:** Accepted

**Context:**
The official Kubernetes apt repository releases new patch versions
frequently (often weekly) and minor versions quarterly. Running `apt
upgrade` on a node would silently bump `kubeadm`, `kubelet`, and
`kubectl` to the latest available version.

In Kubernetes, version skew between nodes — particularly between the
kubelet on a node and the control plane it talks to — is tightly
constrained. The supported skew is +/- 2 minor versions for kubelet
relative to the API server, and even smaller for some components.
A silent upgrade can break:

- API compatibility (kubelet talks to API server with new RPC fields
  the server doesn't understand, or vice versa).
- Certificate handling (cert rotation behavior changes between versions).
- Pod scheduling (feature gates flip default values).
- etcd format (rare, but happens at major boundaries).

Production K8s upgrade flows are deliberately staged: drain a node,
upgrade its binaries, rejoin, validate, move to the next. Allowing
`apt upgrade` to do this implicitly is a recipe for partial cluster
failure during routine OS maintenance.

**Decision:**
Pin `kubeadm`, `kubelet`, and `kubectl` to an exact version via the
Kubernetes apt repository, then mark all three as `hold` in dpkg so
they are not modified by `apt upgrade` or `unattended-upgrades`.

Implementation:
- Install with explicit version: `kubeadm=1.31.4-1.1` (and similar
  for the other two packages).
- Apply hold via Ansible's `dpkg_selections` module with
  `selection: hold`. Equivalent to `apt-mark hold <package>`.

The upgrade path is then explicit and intentional: when ready to
upgrade,

  1. `apt-mark unhold kubeadm kubelet kubectl`
  2. Update the Kubernetes apt repository URL to the new minor version
     (e.g., `v1.31` → `v1.32`).
  3. `apt install kubeadm=1.32.x-1.1 kubelet=1.32.x-1.1 kubectl=1.32.x-1.1`
  4. Run `kubeadm upgrade plan` and `kubeadm upgrade apply`.
  5. Drain, upgrade, uncordon worker nodes one by one.
  6. `apt-mark hold` the three packages again at the new version.

**Why hold over alternatives:**
- `apt-mark hold` is the official upstream guidance in the K8s install
  documentation. Not a workaround.
- It's enforced at the dpkg layer, so any future tool relying on apt
  (Ansible's `apt` module, unattended-upgrades, manual `apt upgrade`)
  respects it transparently.
- Other approaches (apt pinning via `/etc/apt/preferences.d/`)
  produce the same effect but are less idiomatic and harder to inspect
  (`apt-mark showhold` is one command).

**Trade-off:**
- Upgrades become deliberate, not automatic. This is a feature in
  the K8s context but means a forgotten cluster may stay on an old
  version. Acceptable for this lab; in production, a separate
  scheduled upgrade process must exist.

**References:**
- Kubernetes — Installing kubeadm, kubelet, kubectl (official
  guidance recommending `apt-mark hold`):
  https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/
- Kubernetes — Version skew policy (canonical reference for what
  versions can talk to each other safely):
  https://kubernetes.io/releases/version-skew-policy/
- Debian apt-mark(8) man page — official `hold` semantics:
  https://manpages.debian.org/bookworm/apt/apt-mark.8.en.html
- Ansible `dpkg_selections` module — canonical way to set hold from
  Ansible (equivalent to `apt-mark hold`):
  https://docs.ansible.com/ansible/latest/collections/ansible/builtin/dpkg_selections_module.html
