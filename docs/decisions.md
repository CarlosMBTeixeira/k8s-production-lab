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

  ---

## ADR-016: Use Calico as the cluster CNI plugin

**Date:** 2026-06-25
**Status:** Accepted

**Context:**
A Kubernetes cluster needs a CNI (Container Network Interface) plugin
to provide pod-to-pod networking. Without a CNI, nodes report
`NotReady` and pods cannot be scheduled (no IP can be assigned).

The CNI plugin space has several mature options, each with different
trade-offs:

- **Flannel**: simplest, VXLAN overlay. Limited features. No
  NetworkPolicy enforcement out of the box. Often paired with another
  tool (e.g. Canal = Calico for policy + Flannel for routing).
- **Calico**: production-grade. Native NetworkPolicy support. BGP
  routing option for high-performance setups. Optional eBPF mode
  bypasses kube-proxy. Wider production adoption.
- **Cilium**: eBPF-native, highest performance, richest observability
  (Hubble). Steeper learning curve; more moving parts.
- **Weave Net**: simple, mesh network. Project less actively
  maintained as of 2024.

**Decision:**
Use Calico as the cluster CNI. Specifically version v3.28.2,
applied via the upstream manifest from the project's GitHub releases
(`projectcalico/calico` at the tag `v3.28.2`). The manifest is
applied with `kubectl apply -f <URL>` rather than via the Tigera
operator pattern, to keep the install path transparent and
inspectable in a lab context.

The pod network CIDR is fixed at 192.168.0.0/16 — the upstream
Calico default — and is passed to `kubeadm init` via the
KubeadmConfig file so both sides agree.

**Why Calico over Flannel:**
- Native NetworkPolicy enforcement is essential for cluster security
  work (a syllabus item later in the lab). Adding NetworkPolicy on
  top of Flannel later means swapping CNI mid-cluster — disruptive.
- Career relevance: Calico is the most widely deployed CNI in
  production Kubernetes installations as of 2025-2026.

**Why Calico over Cilium:**
- Cilium's value (eBPF, Hubble, performance) shines at scale and
  requires deeper understanding. For a 4-node learning lab, the
  added surface area (Hubble UI, eBPF debugging, multiple agents)
  obscures the core K8s concepts being studied. Calico is enough
  to learn pod networking and NetworkPolicy without distraction.
- Cilium can be revisited as a future migration if/when the lab
  grows beyond what Calico explains well.

**Why the manifest install over the Tigera operator:**
- The operator adds an extra control loop and CRD layer between the
  user and the Calico configuration. In a lab, the goal is to
  understand what's running — the operator hides that.
- Direct `kubectl apply` shows exactly which resources are created
  (DaemonSet, Deployment, ServiceAccounts, ClusterRoles, CRDs).
  Easier to inspect, debug, and uninstall.

**Why version pinning:**
- v3.28.2 was the latest stable in the v3.28.x line at the time of
  this decision and is documented as compatible with Kubernetes
  1.31. Pinning the version prevents unexpected upgrades when
  re-running the role months later.
- Calico patch versions occasionally introduce regressions; only
  upgrade after reviewing the release notes.

**Trade-off:**
- Calico without BGP and without eBPF runs in its simplest mode
  (VXLAN-equivalent IPIP encap). This is adequate for the lab but
  doesn't exercise Calico's most advanced features. The Ansible
  role's `cni_calico_version` variable can be bumped later, and a
  follow-up ADR can document the move to BGP or eBPF.
- The single-node phase of the lab leaves the `node-role.kubernetes.io
  /control-plane:NoSchedule` taint in place on cp-1. User workloads
  remain `Pending` until workers join the cluster. This is correct
  Kubernetes behavior, not a Calico limitation, but worth noting
  here for completeness.

**References:**
- Calico documentation — quickstart for Kubernetes:
  https://docs.tigera.io/calico/latest/getting-started/kubernetes/quickstart
- Calico v3.28 release notes:
  https://docs.tigera.io/calico/3.28/release-notes/
- Kubernetes — Cluster Networking concepts (CNI plugin model):
  https://kubernetes.io/docs/concepts/cluster-administration/networking/
- Kubernetes — Installing Addons (CNI plugin selection):
  https://kubernetes.io/docs/concepts/cluster-administration/addons/
- CNCF — CNI specification:
  https://github.com/containernetworking/cni/blob/main/SPEC.md

---

## ADR-017: Distribute admin kubeconfig to a configurable list of users

**Date:** 2026-06-25
**Status:** Accepted

**Context:**
After `kubeadm init` succeeds, the cluster's admin credentials live at
`/etc/kubernetes/admin.conf` on the primary control plane node, owned
by `root` with mode 0600. Using `kubectl` requires either:

  1. Running as root (e.g. `sudo kubectl ...`), which conflates cluster
     admin with system root and is poor security hygiene.
  2. Setting `KUBECONFIG=/etc/kubernetes/admin.conf` in every shell.
  3. Copying `admin.conf` to a user's `~/.kube/config` (the path
     `kubectl` searches by default).

Option 3 is the standard practice and is the one `kubeadm init`'s own
output instructs the operator to perform manually.

A small architectural friction appears in this lab: the SSH user
(`ubuntu`, set by Multipass cloud-init) and the Ansible automation
user (`ansible`, created later by the `ansible-user` role) are
distinct. A human operator typing `ssh cp-1 "kubectl get nodes"`
connects as `ubuntu`. An Ansible playbook connects as `ansible`.

Both need `kubectl` access — the operator for ad-hoc work, Ansible
for follow-on tasks like applying the Calico manifest. Hardcoding
one user in the `kubeadm-init` role would leave the other broken.

**Decision:**
The `kubeadm-init` role copies `admin.conf` to **both**:

  1. The Ansible user's home (`/home/{{ ansible_user }}/.kube/config`).
     This user is fixed by the role and always receives a kubeconfig
     because subsequent role tasks (and dependent roles like
     `cni-calico`) need it.

  2. Each user in the configurable list
     `kubeadm_init_extra_kubeconfig_users`. The list defaults to
     `[ubuntu]` — the Multipass-default SSH user, which is also the
     account a human reaches when typing `ssh cp-1` without further
     SSH config tweaks.

Both copies are owned by the respective user with mode 0600. The role
does NOT create the users in the extra list; they must already exist
on the node (typically created by cloud-init).

**Why a list rather than a single extra user:**
- Future flexibility: when a real operator account is added (e.g.
  `cmbt1`), it can be appended to the list without role changes.
- Single source of truth: bumping the kubeadm version or re-running
  the role keeps every listed user's kubeconfig in sync.
- The implementation cost is negligible (one extra loop in tasks).

**Why both `ansible` AND the extra list, not one or the other:**
- The Ansible user must have kubeconfig for the role's own
  validation tasks (`kubectl get nodes`) and for dependent roles
  like `cni-calico` that issue `kubectl apply`. Hardcoding this
  separately from the operator list keeps the role's own dependency
  explicit and unbreakable — accidentally clearing
  `kubeadm_init_extra_kubeconfig_users` cannot leave the role
  unable to validate itself.

**Trade-off:**
- The kubeconfig is admin-level credentials. Distributing copies
  increases the blast radius if any of those user accounts is
  compromised. Acceptable in a lab; production should issue
  scoped kubeconfigs via the API server's CSR flow, not duplicate
  admin.conf.
- The list approach assumes "extra users" all want full admin
  access. In a real environment, different operators would have
  different RBAC scopes. Out of scope for this lab.

**References:**
- Kubernetes — Configure Access to Multiple Clusters (kubeconfig
  format and search path):
  https://kubernetes.io/docs/tasks/access-application-cluster/configure-access-multiple-clusters/
- kubeadm init reference — kubeconfig generation:
  https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-init/
- Ansible builtin loop documentation:
  https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_loops.html

---

## ADR-018: Pin containerd config to schema v3 for containerd 2.x

**Date:** 2026-06-20
**Status:** Accepted

**Context:**
The first iteration of the `containerd-configure` role rendered a
config.toml file with `version = 2` and the v2 plugin path layout:

  [plugins."io.containerd.grpc.v1.cri"]
  [plugins."io.containerd.grpc.v1.cri".containerd]
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
    SystemdCgroup = true

This worked on first deployment when the Docker apt repo was shipping
containerd.io v1.7.x. The package's compiled-in defaults plus the v2
schema's CRI configuration loaded correctly and `crictl`, kubeadm,
and kubelet all spoke CRI v1 to containerd successfully.

Some time later — likely between sessions — the Docker apt repo
promoted containerd.io to v2.2.5. From that point, fresh deployments
of the same role produced subtly broken nodes:

  - `containerd --version` reports 2.2.5
  - `systemctl is-active containerd` returns active
  - `ctr plugin ls` shows io.containerd.cri.v1.images and
    io.containerd.cri.v1.runtime as 'ok'
  - BUT `crictl version` fails with:
      "validate CRI v1 runtime API for endpoint
       unix:///run/containerd/containerd.sock: rpc error:
       code = Unimplemented desc = unknown service
       runtime.v1.RuntimeService"

The failure is silent at the daemon level. The CRI plugin appears
loaded but the gRPC service that exposes runtime.v1.RuntimeService
is never started because containerd 2.x ignores plugin sections
under the v2 path names. The v3 schema renamed the runtime plugin
section from

  [plugins."io.containerd.grpc.v1.cri"]                  (v2)

to

  [plugins.'io.containerd.cri.v1.runtime']               (v3)

and split image/registry settings out into

  [plugins.'io.containerd.cri.v1.images']                (v3)

Containerd 2.x will accept a `version = 2` header and convert it to
v3 in memory, BUT this conversion only handles the version field and
selected fields. Plugin sections under the old v2 path names are
treated as unknown plugins and ignored — silently. SystemdCgroup,
sandbox_image, and other CRI settings written under the v2 path are
effectively no-ops; the plugin loads with compiled defaults that
don't expose the v1 runtime API.

Symptom timing: this bug was masked during the first lab session
because that session used a pre-2.x containerd. The "sandbox image
inconsistent" warning that appeared during kubeadm init was the
canary, but the cluster came up anyway and the warning was logged as
non-blocking tech debt rather than investigated.

**Decision:**
The `containerd-configure` template explicitly sets `version = 3`
and uses the v3 plugin path layout. All CRI runtime settings (cgroup
driver, runtime class, apparmor) go under
`[plugins.'io.containerd.cri.v1.runtime']`. All CRI image settings
(sandbox image, snapshotter) go under
`[plugins.'io.containerd.cri.v1.images']`.

This pins the role to containerd 2.x compatibility. If anyone tries
to run this role against containerd 1.x (now unlikely from Docker
repo, possible from Ubuntu's archive), the v3 schema will be
rejected with a parse error rather than loading silently broken.
Failing loud is the goal.

**Why not generate from `containerd config default`:**
- The output of `containerd config default` includes ~150 lines of
  defaults. Most aren't relevant to our needs.
- The format and contents of the default output change between
  patch versions of containerd, which would constantly produce
  diffs in our Ansible run output. The role would never report
  changed=0 even when nothing meaningful changed.
- A hand-written minimal template documents intent: we know exactly
  which settings the lab cares about and why. The defaults handle
  the rest.

**Why not preserve v2 compatibility via Jinja conditional:**
- The Docker apt repo for Ubuntu Noble (24.04) only ships
  containerd.io 2.x as of this writing. There's no realistic path
  back to v1.x in this lab.
- A conditional adds 30 lines of template, two test paths, and
  ambiguity ("which path was rendered, again?"). Cost-benefit
  doesn't justify it.
- If a v1.x compatibility need ever appears, that warrants its own
  ADR and a versioned template, not a runtime conditional.

**Trade-off:**
- The role is now tied to containerd 2.x. Older clusters (e.g.
  upstream long-running deployments on 1.7.x) need a different
  template. Acceptable for a lab project.
- The silent-failure debugging experience cost ~45 min of
  diagnostic time. Documented here so future-me (or anyone reading
  this repo) recognizes the symptom faster.

**Diagnostic recipe (for the next time something similar happens):**
1. `containerd --version` to confirm major version.
2. `systemctl is-active containerd` to rule out a hard failure.
3. `ctr plugin ls | grep cri` — if the plugin shows 'ok' but
   crictl still fails, it's a schema problem.
4. `sudo cat /etc/containerd/config.toml | head -1` — check the
   version header.
5. Cross-reference plugin paths with the containerd version's
   schema requirements.

**References:**
- containerd 2.x CRI plugin config (canonical reference, v3 schema):
  https://github.com/containerd/containerd/blob/main/docs/cri/config.md
- containerd configuration versions migration notes:
  https://containerd.io/docs/2.1/cri/config/
- Original SystemdCgroup decision (still valid, only path changed):
  See ADR-013 in this document.
- Kubernetes container runtimes docs (cgroup driver requirements):
  https://kubernetes.io/docs/setup/production-environment/container-runtimes/

---

## ADR-019: Flush handlers between roles when downstream tasks depend on the restart

**Date:** 2026-06-21
**Status:** Accepted

**Context:**
Ansible handlers are lazy by design. When a task notifies a handler,
the handler's execution is deferred to the end of the current play.
The rationale is sensible: if multiple tasks all need a service
restarted, you'd rather restart once at the end than once per
notification. The same lazy behavior is what makes notifications
idempotent across re-runs (no notification, no restart).

This default works perfectly when:
  - A play contains one role, OR
  - Multiple roles in the same play don't depend on each other's
    handler outcomes.

It breaks silently when:
  - A play runs several roles in sequence, AND
  - A later role depends on the *runtime state* (not just the
    *files on disk*) modified by an earlier role's handler.

The lab's `site.yml` is exactly this pattern. The role order is:

    apt-base -> ansible-user -> disable-swap -> kernel-prereqs
      -> containerd-install -> containerd-configure
      -> runtime-tools -> kubernetes-repo

`containerd-configure` writes a new `/etc/containerd/config.toml`
and notifies the `Restart containerd` handler. Default behavior:
the handler queues, the play continues, and `runtime-tools` runs
its `Validate crictl can reach containerd` task — which talks to
the still-running, still-using-old-config containerd. The
validation fails, the play aborts, the handler never runs.

The first iteration of this lab's roles was developed by running
each role's dedicated playbook independently
(`06-containerd-configure.yml`, `07-runtime-tools.yml`, etc.). In
that mode, every play contains exactly one role; handlers flush at
the end of the only role; downstream roles in other playbooks
already see the post-restart state. The bug is invisible.

Running `site.yml` for the first time, on fresh VMs, surfaced the
defect: handlers correctly notified but downstream tasks ran against
stale runtime state. The CRI v1 endpoint problem from ADR-018 was
already fixed (template was correct), but the fix never reached the
running daemon during the play.

**Decision:**
When a role notifies a handler whose effect (a service restart, a
config reload, a daemon refresh) must be observable before a
subsequent role runs in the same play, the notifying role MUST add

    - name: Flush handlers (apply <effect> immediately, before downstream roles)
      ansible.builtin.meta: flush_handlers

immediately after the notification task. The task name explains the
intent so anyone reading the role understands why the flush exists.

In addition, when the handler restarts a service that exposes a
unix socket, a `wait_for` task on the socket path is added after
the flush. Systemd's `restart` action returns once the unit is in
'active' state, which can be before the daemon has finished
re-creating its sockets. Downstream tools (kubectl, crictl, kubeadm)
get connection-refused errors if they race against the socket
recreation. The wait closes that race without busy-polling.

**Roles updated under this decision:**
  - containerd-configure (the role that triggered the discovery)

**Roles deliberately not updated:**
  - containerd-install: notifies the kubernetes-repo handler
    'Refresh apt cache' but already has its own explicit
    `meta: flush_handlers` at the right point. Pre-existing
    correct pattern, left in place.
  - kubeadm-init, cni-calico: no handlers cross role boundaries.

**Why not switch handlers to plain tasks with `when: changed`:**
- Loses the idempotency-by-default that handlers give. Plain tasks
  with `when: register.changed` need explicit registration and
  guards on every change-detection task. Handlers express intent
  more naturally: "when this thing changes, do that thing."
- The `flush_handlers` meta-task is the canonical Ansible idiom
  for this exact problem. Documented in the official Ansible docs
  for over a decade. No reason to reinvent.

**Why not split site.yml into per-role playbooks:**
- The per-role playbooks already exist (01- through 08-). The
  monolithic site.yml exists precisely so an operator can run one
  command and get a fully configured node base. Splitting it
  back would push the cross-role coordination problem onto the
  human ("run 06 first, then 07, then..."), which is exactly the
  fragility automation is supposed to eliminate.

**Trade-off:**
- The `flush_handlers` task adds output noise — it appears in
  every `site.yml` run even when no handler is queued (Ansible
  prints the task name then shows nothing executing). Acceptable
  cost for the correctness guarantee.
- A role's contract is now subtly stronger: it promises that any
  change to its declared state is observable when the role
  completes. Roles depending on this role's effects can assume
  the post-condition holds. This is good documentation discipline
  but means roles cannot silently rely on play-end flushing.

**Diagnostic recipe (for the next time something similar happens):**
1. A handler that should have restarted a service didn't, OR
2. A downstream task fails to observe the post-restart state.
3. Check whether the failing task is in the same play as the
   notifying task. If yes -> handler is queued but not yet run.
4. Add `meta: flush_handlers` between the notification and the
   dependent task. Add `wait_for` if the restart involves a
   socket the dependent task connects to.

**References:**
- Ansible builtin meta module — `flush_handlers` action:
  https://docs.ansible.com/ansible/latest/collections/ansible/builtin/meta_module.html
- Ansible handlers documentation (lazy execution semantics):
  https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_handlers.html
- Related ADRs:
  - ADR-013: containerd cgroupDriver=systemd (the setting being applied)
  - ADR-018: containerd v3 schema (what made the restart matter so much)

---

## ADR-020: Prefer inventory-resolved values over gather_facts in racy environments

**Date:** 2026-06-21
**Status:** Accepted

**Context:**
Ansible offers two distinct families of variables for referring to a
target node's network identity:

  1. Inventory-resolved values such as `ansible_host`,
     `inventory_hostname`. These are set when Ansible parses the
     inventory file and resolved through whatever discovery mechanism
     the inventory uses (DNS, ~/.ssh/config, hardcoded IPs). They are
     stable for the entire play; nothing the target node does at
     runtime can change them.

  2. Target-gathered facts such as `ansible_default_ipv4.address`,
     `ansible_all_ipv4_addresses`. These come from Ansible running
     `setup` on the target and inspecting `ip route`, `ip addr`, etc.
     They are a snapshot of what the target's network stack reports
     at the moment `gather_facts: true` runs.

Both kinds appear interchangeable in calm environments. They diverge
in environments where the target's network state changes during the
play:

  - DHCP-renew races during VM boot.
  - Multi-homed nodes where the "default" route changes after a
    service starts.
  - Networking plugins (CNI, VPN clients) that add or modify
    interfaces after boot.
  - Containerized targets where the perceived IP differs between
    the host network namespace and the container.

This lab hit the divergence concretely: the kubeadm-init role's
config template embedded `ansible_default_ipv4.address` into the
kubelet's `node-ip` argument. Multipass/QEMU's DHCP behavior leaked
a transient lease IP into gather_facts; the kubelet was started with
an IP that didn't exist on the host at startup time. See the commit
fix(ansible): use ansible_host instead of default_ipv4 for kubelet
node-ip for the full incident write-up.

**Decision:**
When a template or task in this project needs to refer to a target
node's network identity, prefer values resolved from the inventory
over values gathered from the target. Specifically:

  - For "the address Ansible is connecting through right now" use
    `ansible_host`. This is the single source of truth that's
    already in use by every SSH connection in the play.
  - For "the canonical name of the target in our inventory" use
    `inventory_hostname`. This is what we use in inventory groups
    and what scripts/sync-ssh-config.sh writes into ~/.ssh/config.
  - For "the target's view of its own hostname" use
    `ansible_facts['hostname']` only when it's actually the target's
    self-reported identity that matters (e.g. registering with an
    API that takes the target's word for it). Multipass auto-sets
    this to the VM name; kubeadm registers nodes by this value.

Reserve `ansible_default_ipv4.address` and related gather_facts
network values for diagnostic uses (debug messages, conditionals
based on a transient observation). Never embed them in a config
file that will outlive the play.

**Why not switch to static inventory IPs:**
- Multipass assigns IPs from a DHCP pool on the mpqemubr0 bridge.
  The same VM name gets a different IP after destroy/build. Hard-
  coding IPs in the inventory would break every rebuild and force
  manual edits.
- `scripts/sync-ssh-config.sh` already rewrites ~/.ssh/config after
  every build, so the inventory's SSH aliases (cp-1, cp-2, w-1, w-2)
  resolve to current IPs automatically. `ansible_host` follows the
  SSH config; the indirection works.

**Why not just refresh facts before the template render:**
- An explicit `ansible.builtin.setup` task right before the
  template would re-query the target, but it would still query
  the same racy source. The bug would be much less likely to
  recur in practice but the architectural smell would remain:
  the template's correctness would depend on whether the DHCP
  race happens to land in the right window. inventory-resolved
  values close the race entirely.

**Trade-off:**
- `ansible_host` is whatever the operator wrote (or whatever
  sync-ssh-config.sh wrote on their behalf). If those are wrong,
  Ansible itself can't connect — the failure is loud and
  immediate, not a half-broken cluster three days later. This is
  the right failure mode.
- A node whose actual current IP differs from `ansible_host`
  (e.g. the operator put the wrong entry in ~/.ssh/config) will
  produce a working kubelet that's published the wrong IP. The
  problem becomes operator-introduced rather than environment-
  introduced. Acceptable trade-off: operator errors are far
  easier to diagnose than DHCP races.

**Roles affected by this decision:**
  - kubeadm-init: templates/kubeadm-config.yaml.j2 now uses
    `ansible_host` for kubeletExtraArgs.node-ip.

**Roles deliberately left as-is:**
  - apt-base, ansible-user, disable-swap, kernel-prereqs,
    containerd-install, containerd-configure, runtime-tools,
    kubernetes-repo, cni-calico: none of these embed an IP into
    a persistent artifact. No fix needed.

**Diagnostic recipe (for the next time something similar happens):**
  1. Symptom: a persistent target-side config has a value that
     no longer matches what's on the target now.
  2. Find the source: grep the templates and tasks for the bad
     value's variable name.
  3. If the variable is from `ansible_facts.*` and the value is
     network-related, suspect a DHCP/runtime race. Switch to an
     inventory-resolved alternative.
  4. If no inventory-resolved alternative exists, document why
     and add a deliberate `setup` refresh immediately before the
     dependent task.

**References:**
- Ansible Special Variables (lists ansible_host, inventory_hostname):
  https://docs.ansible.com/ansible/latest/reference_appendices/special_variables.html
- Ansible setup module (gather_facts implementation):
  https://docs.ansible.com/ansible/latest/collections/ansible/builtin/setup_module.html
- Kubelet --node-ip flag (where this value ultimately lands):
  https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/
- Multipass networking (mpqemubr0, DHCP server behavior):
  https://multipass.run/docs/configure-multipass-network
- Related ADRs:
  - ADR-018: containerd v3 schema (same family of "looks right in
    the file, wrong on the wire" bugs).
  - ADR-019: cross-role handler flush (same family of "looks like
    it worked but the runtime state lags" bugs).

## ADR-021: kube-vip ARP mode works inside the existing Multipass NAT bridge — resolves ADR-002

**Date:** 2026-07-03
**Status:** Accepted

**Context:**
ADR-002 deferred a decision: whether kube-vip would need the lab's VMs
bridged onto the home LAN (instead of the WSL2/Multipass internal NAT
segment) to work. This was untested until Week 1 of July, when kube-vip
was actually implemented for HA (2 control planes, cp-1 + cp-2).

**Decision:**
No LAN bridging needed. kube-vip in ARP mode works correctly entirely
within the existing `mpqemubr0` NAT bridge inside WSL2. Verified
end-to-end: `kubeadm init`/`kubeadm join --control-plane` on both nodes
successfully reach the VIP, and `curl https://<VIP>:6443/livez` returns
200 from the WSL2 host itself, outside any cluster node.

**Rejected alternatives:**
- **Bridged-to-LAN networking (the ADR-002 plan).** Would have required
  reconfiguring the WSL2/Multipass network setup non-trivially. Turned
  out to be unnecessary — the host already participates in the same L2
  segment as the VMs via the bridge, so ARP-based failover works as-is.

**Trade-offs accepted:**
- The VIP (and the whole cluster) is still only reachable from the WSL2
  host and the VMs themselves, not from other devices on the home LAN.
  Acceptable — this lab is single-operator, not meant to serve traffic
  to other machines.

**References:**
- ADR-002: Bridged-to-LAN for kube-vip — DEFERRED (this ADR closes it)

---

## ADR-022: kube-vip must mount super-admin.conf, not admin.conf

**Date:** 2026-07-03
**Status:** Accepted

**Context:**
kube-vip's static pod needs a kubeconfig to run leader election
(`leases.coordination.k8s.io` in `kube-system`) before it can bring up
the VIP. The obvious choice, `/etc/kubernetes/admin.conf`, caused two
separate failures:

1. On `kubeadm init` (cp-1): kube-vip got `403 Forbidden` doing leader
   election as `kubernetes-admin`. Root cause: kubeadm >= 1.29 changed
   admin.conf's client cert group from `system:masters` to
   `kubeadm:cluster-admins`, which is only bound to the `cluster-admin`
   ClusterRole late in the `kubeadm init` sequence (the `addons` phase).
   Since kubeadm's own `wait-control-plane` health check also goes
   through the VIP (because `controlPlaneEndpoint` is set), this was a
   deadlock: kube-vip needed the binding to exist to get leader and
   raise the VIP, but kubeadm couldn't reach that phase without the VIP
   already up.

2. On `kubeadm join --control-plane` (cp-2): a second, different bug.
   `kubeadm join --control-plane` does NOT generate `super-admin.conf`
   (only `kubeadm init` does). Because kube-vip's manifest uses a
   `hostPath` volume with `type: FileOrCreate`, and the manifest is
   deployed to cp-2 BEFORE the join runs, kubelet created an EMPTY
   placeholder file the moment it started watching
   `/etc/kubernetes/manifests/` during the join — and kube-vip
   crash-looped trying to parse an empty file as a kubeconfig.

**Decision:**
- kube-vip's static pod mounts `/etc/kubernetes/super-admin.conf`
  (which keeps `system:masters`, exists specifically for this kind of
  bootstrap tooling) instead of `admin.conf`.
- The `controlplane-join` role now fetches `super-admin.conf` from the
  primary control plane (via `slurp` + `delegate_to`) and writes it to
  the joining node BEFORE running `kubeadm join --control-plane`, so
  the real file exists before kubelet ever starts scanning the static
  pod manifests directory.

**Rejected alternatives:**
- **Patch admin.conf's cert to restore `system:masters`.** Fights
  kubeadm's own hardening; fragile across kubeadm upgrades.
- **Delay kube-vip's static pod placement until after join.** Doesn't
  work — kube-vip has to be up BEFORE `kubeadm init`/`join` even starts
  its own health checks, since `controlPlaneEndpoint` makes every
  client (including kubeadm itself) target the VIP from the first
  request.

**Trade-offs accepted:**
- `super-admin.conf` is a superuser-bypass credential sitting on disk,
  mounted into a non-apiserver container. Accepted as a known, common
  trade-off for kubeadm HA bootstrapping with kube-vip — this is
  precisely why kubeadm >= 1.29 ships that file.

**References:**
- kubeadm docs: `kubeadm init phase kubeconfig` (admin.conf vs
  super-admin.conf groups)
- ADR-020: Prefer inventory-resolved values over gather_facts (same
  family of "don't trust convenient defaults in racy bootstrap code")

## ADR-023: Gateway API + MetalLB replaces nginx+NodePort for the bootstrap smoke test

**Date:** 2026-07-04
**Status:** Accepted

**Context:**
The original Phase F smoke test (docs/manual-bootstrap.md) used a plain
`kubectl run nginx-test` pod + NodePort Service. Separately,
`ingress-nginx` (the Kubernetes Ingress controller — not the `nginx`
container image, which is unrelated and still fine) reached EOL on
2026-03-31, with SIG-Network recommending Gateway API as the path
forward for all new Ingress-like traffic management.

**Decision:**
Validate the cluster with Gateway API instead: MetalLB (L2/ARP mode,
since bare-metal has no cloud LoadBalancer) provides a real external
IP for a `Service` of type `LoadBalancer`; Envoy Gateway is the Gateway
API reference implementation on top of it. The smoke test uses the
official `registry.k8s.io/gateway-api/echo-basic` app (Envoy Gateway's
own quickstart), not nginx.

This is deliberately kept OUT of the core Ansible HA bootstrap
(kube-vip, kubeadm-init, calico). It lives in
`scripts/pipeline/03_gateway_api_metallb.sh`, run manually/optionally, because:
1. CKA does not test Gateway API — no reason to add it to the mandatory
   rebuild path during Semanas 2-4 of July.
2. It's meaningfully more infrastructure (2 more controllers, more
   surface area) than the single-pod smoke test it replaces.

**Rejected alternatives:**
- **Calico's native Gateway API (Tigera Operator + Envoy Gateway).**
  Requires Calico to have been installed via the Tigera Operator; this
  lab installs Calico via the plain upstream manifest
  (`cni_calico_manifest_url`), so switching would mean reinstalling
  Calico differently. Not worth it for a smoke test.
- **Cilium Gateway API support.** Would mean replacing the CNI
  entirely. Out of scope.
- **Keep nginx+NodePort.** Still technically valid (Ingress API itself
  isn't deprecated, and this test never used Ingress anyway), but
  Gateway API is closer to where the ecosystem is actually heading.

**Trade-offs accepted:**
- MetalLB's controller assigns an IP to the Gateway/Service
  near-instantly, but the elected speaker still needs a moment to
  actually broadcast ARP for it — the two aren't synchronized. A
  single immediate `curl` right after `Gateway.status.addresses` is
  populated can hit a real "no route to host" on a freshly rebuilt
  cluster. `scripts/pipeline/03_gateway_api_metallb.sh` retries the HTTP check
  (up to 30s) instead of trusting the address alone.

**References:**
- Kubernetes blog: Ingress NGINX Retirement (2025-11-11)
- Envoy Gateway Quickstart (gateway.envoyproxy.io/docs/tasks/quickstart)
- MetalLB Configuration docs (metallb.universe.tf/configuration)

---

## ADR-024: Scripts needing local kubectl must fetch kubeconfig themselves

**Date:** 2026-07-04
**Status:** Accepted

**Context:**
`scripts/pipeline/03_gateway_api_metallb.sh` failed with a TLS verification
error (`x509: certificate signed by unknown authority`) after a full
cluster rebuild, even though it had worked minutes earlier against the
previous cluster incarnation. Root cause: every `kubeadm init`
generates a brand-new self-signed cluster CA. A kubeconfig copied from
a previous cluster still has the OLD CA embedded, so it fails to
validate the NEW apiserver's certificate — even though both clusters
happen to share the same VIP/IP.

**Decision:**
Any script that needs local `kubectl`/`helm` fetches a fresh kubeconfig
from `cp-1` as its own first step, into a repo-local, gitignored path
(`kubernetes/admin.conf`), and exports `KUBECONFIG` for its own
process — rather than assuming `~/.kube/config` is already valid, and
rather than overwriting the operator's global kubeconfig as a side
effect.

**Rejected alternatives:**
- **Document "remember to scp the kubeconfig first" as a manual step.**
  This is exactly the kind of implicit dependency that fails silently
  and was the whole point of automating the rest of the bootstrap.
  Given the stated workflow (destroy + rebuild every session), this
  would fail every single time without fail.
- **Overwrite `~/.kube/config` directly.** Simpler, but a script
  shouldn't silently mutate global user state as a side effect,
  especially one that might be managing other clusters/contexts later.

**Trade-offs accepted:**
- One extra `scp` (and one extra network round-trip to cp-1) at the
  start of every run of this script. Negligible.

**References:**
- ADR-020: Prefer inventory-resolved values over gather_facts (same
  family: don't trust state you didn't just verify, in bootstrap code)

