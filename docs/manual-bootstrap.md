# Manual cluster bootstrap

This document walks through every command the automated scripts run,
in order, to bring up a working K8s cluster from fresh VMs. It exists
for two reasons:

1. **CKA preparation.** The exam has no scripts; you operate the
   cluster with raw `kubeadm`, `kubectl`, `systemctl`, etc. Going
   through this list manually teaches each step.
2. **Troubleshooting.** When a script fails halfway, knowing which
   step it was on (and how to retry just that step) saves time.

## How to use this document

The canonical bootstrap path is the scripts:
```
./scripts/lab-management.sh build
./scripts/pipeline/01_initial_cluster_setup.sh
./scripts/pipeline/02_kubeadm_join.sh
```

Optionally, for the Gateway API + MetalLB smoke test (see ADR-023):

```bash
./scripts/pipeline/03_gateway_api_metallb.sh
```

Or run everything (VMs through Gateway API) in one go:

```bash
./scripts/pipeline/main.sh
```

This document expands what those scripts do, command by command. If
this document and the scripts diverge, **the scripts are right**.
Treat this file as didactic, not authoritative.

Each phase below corresponds to one script (or one section within a
script). At the end of each phase there's a "Verify" block — commands
that confirm the phase landed correctly before moving on.

---

## Prerequisites

Assumed already true at the start of this walkthrough:

- WSL2 Ubuntu 24.04 running with systemd as PID 1.
- Multipass installed and `mpqemubr0` bridge up.
- `~/.ssh/k8slab` private key exists.
- `ansible/inventory/hosts.ini` exists and has groups `controlplane`,
  `workers`, `all`.
- The repo is cloned at `~/k8slab`.

If any of these are not true, fix that first — `lab-management.sh build`
expects them.

---

## Phase A — Launch VMs

**Script equivalent:** `./scripts/lab-management.sh build`

This phase creates 4 Ubuntu 24.04 VMs via Multipass, applies a
cloud-init seed that creates two users (`ubuntu` for human SSH,
`ansible` for automation), rewrites `~/.ssh/config` with current
VM IPs, and runs a health check.

### Step A.1 — Render cloud-init from template

The cloud-init file at `cloud-init/seed.yaml.tmpl` is a template
with `${LAB_SSH_PUBLIC_KEY}` placeholders. Render to a real file:

```bash
export LAB_SSH_PUBLIC_KEY="$(cat ~/.ssh/k8slab.pub)"
envsubst < cloud-init/seed.yaml.tmpl > /tmp/seed.yaml
```

The rendered file is intentionally outside the repo (gitignored
path) because it contains the host's public key inline.

### Step A.2 — Launch each VM

For each VM (`controlplane-1`, `controlplane-2`, `worker-1`,
`worker-2`):

```bash
multipass launch \
    --name controlplane-1 \
    --cpus 2 \
    --memory 4G \
    --disk 20G \
    --cloud-init /tmp/seed.yaml \
    24.04
```

Repeat with `controlplane-2`, `worker-1`, `worker-2` (same flags,
different `--name`).

### Step A.3 — Confirm each VM is running

```bash
multipass list
```

Expected: 4 VMs in state `Running` with an IPv4 each (e.g.
`10.215.138.X`).

### Step A.4 — Rewrite `~/.ssh/config`

```bash
./scripts/sync-ssh-config.sh
```

This script idempotently rewrites the section of `~/.ssh/config`
between markers `# >>> k8slab` and `# <<< k8slab` with current
host aliases (`cp-1`, `cp-2`, `w-1`, `w-2`) and IPs from
`multipass list`.

### Step A.5 — Wait for cloud-init to finish

```bash
sleep 15
```

cloud-init runs asynchronously after `multipass launch` returns.
SSH may technically work before `ubuntu` user is set up. 15s is
empirically enough on this host.

### Verify Phase A

```bash
./scripts/morning-check.sh
```

Expected output: all green checks (or one ⚠️ on `git status clean`
if you have uncommitted work — that's informational, not blocking).

If any VM fails to launch, see [Troubleshooting](#troubleshooting)
below.

---

## Phase B — Configure the 4 nodes

**Script equivalent:** `ansible-playbook ansible/site.yml`

This is the bulk of the work. `site.yml` is one play that runs 8
roles in order against all 4 nodes. Below, each role expands to
the shell commands it would run on the target.

The Ansible side of this is also useful — `ansible all -m ping`
first to confirm connectivity:

```bash
ansible all -m ping
```

Expected: 4 SUCCESS lines, one per node.

### Step B.1 — apt-base role

Refresh apt cache and upgrade packages. Run on each node as root.

```bash
# On each node (cp-1, cp-2, w-1, w-2):
sudo apt-get update
sudo apt-get -y dist-upgrade
```

The role caches the result for 3600s, so re-runs within an hour
skip the network round trip.

### Step B.2 — ansible-user role

Add a passwordless-sudo entry for the `ansible` automation user
and authorize the lab SSH key for it.

```bash
# On each node, as root:
echo 'ansible ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/90-ansible
sudo chmod 0440 /etc/sudoers.d/90-ansible

# Then, also as root:
sudo mkdir -p /home/ansible/.ssh
sudo cp ~/.ssh/k8slab.pub /home/ansible/.ssh/authorized_keys
sudo chown -R ansible:ansible /home/ansible/.ssh
sudo chmod 700 /home/ansible/.ssh
sudo chmod 600 /home/ansible/.ssh/authorized_keys
```

### Step B.3 — disable-swap role

K8s 1.35 still requires swap off (or explicitly enabled via
`KubeletConfiguration.failSwapOn: false`, which we don't do).

```bash
# On each node:
sudo swapoff -a

# Persist across reboots — comment out swap lines in /etc/fstab:
sudo sed -i.bak -E '/\sswap\s/s/^/#/' /etc/fstab

# Verify:
free -h | grep -i swap   # should show 0B total
```

### Step B.4 — kernel-prereqs role

Load the kernel modules and sysctl values K8s needs:

```bash
# On each node, load modules now:
sudo modprobe overlay
sudo modprobe br_netfilter

# Persist modules across reboots:
cat <<EOF_INNER | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF_INNER

# Configure sysctl values K8s expects:
cat <<EOF_INNER | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF_INNER

# Apply now:
sudo sysctl --system

# Verify:
lsmod | grep -E 'overlay|br_netfilter'
sysctl net.ipv4.ip_forward            # should print: net.ipv4.ip_forward = 1
```

### Step B.5 — containerd-install role

Install containerd from Docker's apt repo (more recent and
better-maintained than Ubuntu's package).

```bash
# On each node:
sudo apt-get -y install ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings

# Download Docker's GPG key:
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the Docker apt repository (deb822 format):
sudo tee /etc/apt/sources.list.d/docker.sources <<EOF_INNER
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF_INNER

# Refresh cache and install ONLY containerd.io (not docker-ce):
sudo apt-get update
sudo apt-get -y install containerd.io

# Confirm it's running:
sudo systemctl enable --now containerd
sudo systemctl is-active containerd   # should print: active
```

### Step B.6 — containerd-configure role

Replace containerd's default `config.toml` with a v3-schema config
that uses `SystemdCgroup = true`. See ADR-013 and ADR-018.

```bash
# On each node:
sudo mkdir -p /etc/containerd
sudo tee /etc/containerd/config.toml <<'EOF_INNER'
# ===========================================================================
# /etc/containerd/config.toml — manually expanded equivalent of the Ansible
# template at ansible/roles/containerd-configure/templates/config.toml.j2.
# Schema v3, required for containerd 2.x (see ADR-018).
# ===========================================================================
version = 3

[plugins.'io.containerd.cri.v1.runtime']
  [plugins.'io.containerd.cri.v1.runtime'.containerd]
    default_runtime_name = 'runc'
    [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc]
      runtime_type = 'io.containerd.runc.v2'
      [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]
        SystemdCgroup = true

[plugins.'io.containerd.cri.v1.images']
  [plugins.'io.containerd.cri.v1.images'.pinned_images]
    sandbox = 'registry.k8s.io/pause:3.10'
EOF_INNER

# Restart containerd so the new config takes effect IMMEDIATELY (not at
# the end of the play — see ADR-019). The Ansible role uses
# 'meta: flush_handlers' to enforce this ordering; the manual equivalent
# is just to do the restart right after writing the file:
sudo systemctl daemon-reload
sudo systemctl restart containerd

# Wait for the socket to come back (the restart returns before the
# socket is ready):
while [ ! -S /run/containerd/containerd.sock ]; do sleep 1; done

# Verify the config parses:
sudo containerd config dump >/dev/null && echo OK
```

### Step B.7 — runtime-tools role

Install `crictl` (CRI debugging tool, ships separately from
containerd). See ADR-014.

```bash
# On each node:
CRICTL_VERSION=v1.35.0
CRICTL_TARBALL=crictl-${CRICTL_VERSION}-linux-amd64.tar.gz

sudo mkdir -p /tmp/crictl-download
cd /tmp/crictl-download

# Download with SHA256 verification:
curl -fsSL -O "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/${CRICTL_TARBALL}"
curl -fsSL -O "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/${CRICTL_TARBALL}.sha256"
sha256sum -c "${CRICTL_TARBALL}.sha256"   # must print: OK

# Install:
sudo tar -C /usr/local/bin -xzf "${CRICTL_TARBALL}"
sudo chmod 0755 /usr/local/bin/crictl

# Configure crictl to use containerd's socket (root-only by default):
sudo tee /etc/crictl.yaml <<EOF_INNER
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF_INNER

# Validate CRI v1 endpoint:
sudo crictl version                       # should print Version + RuntimeApiVersion: v1
```

### Step B.8 — kubernetes-repo role

Install `kubeadm`, `kubelet`, `kubectl`. See ADR-015 for the
apt-mark hold strategy.

```bash
# On each node:
sudo apt-get -y install apt-transport-https ca-certificates curl

# Download the K8s 1.35 apt key:
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.35/deb/Release.key \
    | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
sudo chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# Add the per-minor-version repo:
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.35/deb/ /' \
    | sudo tee /etc/apt/sources.list.d/kubernetes.list

# Install the pinned versions (1.35.6-1.1):
sudo apt-get update
sudo apt-get -y install kubeadm=1.35.6-1.1 kubelet=1.35.6-1.1 kubectl=1.35.6-1.1

# Pin them so unattended upgrades don't bump them silently:
sudo apt-mark hold kubeadm kubelet kubectl

# Enable kubelet (do NOT start — kubeadm init will start it):
sudo systemctl enable kubelet

# Verify versions:
kubeadm version
kubectl version --client
kubelet --version
```

### Verify Phase B

```bash
# From the host, against all 4 nodes:
ansible all -m shell -a 'systemctl is-active containerd && \
                        kubeadm version --output=short && \
                        sudo crictl version --output go-template --template "{{.RuntimeApiVersion}}"'
```

Expected: 4 lines per node, each ending with `v1` (the CRI API
version). If any node fails, that node's containerd or kubeadm
install went wrong.

---

## Phase B2 — Deploy kube-vip (HA)

**Script equivalent:** `ansible-playbook ansible/playbooks/08-kube-vip.yml`

Runs on cp-1 AND cp-2 (the `controlplane` group). Places a static pod
manifest for kube-vip in ARP mode, which provides the floating VIP that
Phase C's kubeadm init and Phase D2's cp-2 join both target instead of
any single node's IP.

Static pods are started directly by kubelet, not via `kubectl apply` —
this matters because kube-vip has to be up and holding the VIP BEFORE
`kubeadm init` runs, before the cluster technically exists.

### Step B2.1 — Pick a VIP

Must be: in the same subnet as the VMs (check `multipass list`), not
assigned to any VM, and outside Multipass's DHCP range. Set it once,
shared by every role that needs it, in
`ansible/inventory/group_vars/all.yml`:

```yaml
kube_vip_vip_address: "10.215.138.200"   # example — pick a free one
```

### Step B2.2 — Render the kube-vip static pod manifest

```bash
# On cp-1 AND cp-2:
sudo mkdir -p /etc/kubernetes/manifests
sudo tee /etc/kubernetes/manifests/kube-vip.yaml <<EOF_INNER
apiVersion: v1
kind: Pod
metadata:
  name: kube-vip
  namespace: kube-system
spec:
  hostNetwork: true
  containers:
    - name: kube-vip
      image: ghcr.io/kube-vip/kube-vip:v0.8.7
      imagePullPolicy: IfNotPresent
      args: ["manager"]
      env:
        - name: vip_arp
          value: "true"
        - name: port
          value: "6443"
        - name: vip_interface
          value: "ens3"
        - name: vip_cidr
          value: "32"
        - name: cp_enable
          value: "true"
        - name: cp_namespace
          value: "kube-system"
        - name: vip_leaderelection
          value: "true"
        - name: vip_leaseduration
          value: "5"
        - name: vip_renewdeadline
          value: "3"
        - name: vip_retryperiod
          value: "1"
        - name: address
          value: "10.215.138.200"    # your VIP from Step B2.1
      securityContext:
        capabilities:
          add: ["NET_ADMIN", "NET_RAW"]
      volumeMounts:
        - mountPath: /etc/kubernetes/admin.conf
          name: kubeconfig
  volumes:
    - name: kubeconfig
      hostPath:
        # IMPORTANT — see ADR-022. Must be super-admin.conf, NOT
        # admin.conf. kubeadm >=1.29's admin.conf uses a group
        # (kubeadm:cluster-admins) only bound to cluster-admin late in
        # 'kubeadm init', so kube-vip gets 403 doing leader election if
        # it reads admin.conf this early. super-admin.conf keeps
        # system:masters specifically for this kind of bootstrap tooling.
        path: /etc/kubernetes/super-admin.conf
        type: FileOrCreate
EOF_INNER
```

### Verify Phase B2

On cp-1, once containerd pulls the image (~10-20s):

```bash
sudo crictl ps -a | grep kube-vip
ip -br a   # should show the VIP as a secondary address on ens3
```

**Gotcha for cp-2 specifically:** at this point cp-2 has no
`/etc/kubernetes/super-admin.conf` at all (that file is only ever
created by `kubeadm init`, never by `kubeadm join`), and kubelet isn't
running on cp-2 yet either — nothing has started it. The manifest just
sits there inert for now; that's fine. This becomes relevant again in
Phase D2. Don't be alarmed if `crictl ps` on cp-2 shows nothing yet.

---

## Phase C — Bootstrap the control plane on cp-1

**Script equivalent:** `ansible-playbook ansible/playbooks/09-kubeadm-init.yml`

This runs only on `cp-1`. It uses a config file rather than CLI
flags so the choices are explicit and versionable.

### Step C.1 — Render the kubeadm config

```bash
# On cp-1:
CP1_IP=$(hostname -I | awk '{print $1}')
sudo tee /etc/kubernetes/kubeadm-config.yaml <<EOF_INNER
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
nodeRegistration:
  criSocket: "unix:///var/run/containerd/containerd.sock"
  name: "$(hostname)"
  kubeletExtraArgs:
    - name: node-ip
      value: "${CP1_IP}"
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: "v1.35.6"
# HA: every client (including kubeadm's own health checks) targets
# the VIP from now on, not cp-1's individual IP. Must be up already
# (Phase B2) before this runs.
controlPlaneEndpoint: "10.215.138.200:6443"   # your VIP from Step B2.1
networking:
  podSubnet: "192.168.0.0/16"
  serviceSubnet: "10.96.0.0/12"
  dnsDomain: "cluster.local"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: "systemd"
EOF_INNER
```

Note: the Ansible role uses `ansible_host` (the inventory-resolved
IP) instead of `hostname -I` for the kubelet `node-ip` — see
ADR-020 for why. The manual command here is a reasonable
approximation; if your VM has multiple interfaces, set `CP1_IP`
explicitly.

### Step C.2 — Pre-pull control plane images

Optional but speeds up the next step and surfaces image-pull
problems early:

```bash
# On cp-1:
sudo kubeadm config images pull --config /etc/kubernetes/kubeadm-config.yaml
```

### Step C.3 — Initialize the cluster

```bash
# On cp-1:
sudo kubeadm init --config /etc/kubernetes/kubeadm-config.yaml --upload-certs | tee /tmp/kubeadm-init.log
```

Expected:
- `[init] Using Kubernetes version: v1.35.6`
- Various `[certs] Generating ...` lines for PKI material.
- `[kubelet-start] Starting the kubelet`.
- `[kubelet-check] The kubelet is healthy after ~500ms`.
- `[api-check] The API server is healthy after ~4s`.
- `Your Kubernetes control-plane has initialized successfully!`
- A `kubeadm join` command at the bottom — **save this**, you'll
  use it in Phase E.

### Step C.4 — Make kubectl usable without sudo

```bash
# On cp-1, as the user that will run kubectl (ubuntu in this lab):
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

### Step C.5 — Save the worker join command for later

The Ansible role does this so Phase E doesn't have to scrape the
init log:

```bash
# On cp-1:
sudo kubeadm token create --print-join-command | sudo tee /etc/kubernetes/join-command-worker.sh
sudo chmod 0700 /etc/kubernetes/join-command-worker.sh
```

### Verify Phase C

```bash
# On cp-1:
kubectl get nodes
```

Expected:

```
NAME             STATUS     ROLES           AGE   VERSION
controlplane-1   NotReady   control-plane   ...   v1.35.6
```

`NotReady` is normal at this point — there's no CNI yet, so the
kubelet refuses to mark the node Ready.

---

## Phase D — Install Calico CNI

**Script equivalent:** `ansible-playbook ansible/playbooks/10-cni-calico.yml`

Only on cp-1; Calico's DaemonSet propagates to every other node
automatically when they join.

### Step D.1 — Apply the Calico manifest

```bash
# On cp-1:
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/calico.yaml
```

Expected: ~30 objects created (CRDs, ConfigMaps, ServiceAccounts,
ClusterRoles, ClusterRoleBindings, DaemonSet, Deployment).

### Step D.2 — Wait for Calico to roll out

```bash
# On cp-1:
kubectl rollout status daemonset/calico-node -n kube-system --timeout=300s
kubectl rollout status deployment/calico-kube-controllers -n kube-system --timeout=300s
```

This typically takes 1-2 minutes the first time (image pulls
from docker.io for calico/cni, calico/node,
calico/kube-controllers).

### Step D.3 — Wait for the node to become Ready

```bash
# On cp-1:
kubectl wait --for=condition=Ready node/controlplane-1 --timeout=120s
```

### Verify Phase D

```bash
# On cp-1:
kubectl get nodes -o wide
kubectl get pods -A
```

Expected:
- `controlplane-1` STATUS `Ready`, INTERNAL-IP is the VM's real IP.
- 9 pods total, all `Running`: calico-kube-controllers,
  calico-node, coredns (x2), etcd-controlplane-1,
  kube-apiserver-controlplane-1, kube-controller-manager-controlplane-1,
  kube-proxy, kube-scheduler-controlplane-1.

---

## Phase D2 — Join cp-2 as second control plane

**Script equivalent:** `ansible-playbook ansible/playbooks/11-controlplane-join.yml`

Only on cp-2. Brings up a second etcd member, a second API server, and
lets kube-vip actually do leader election between two real candidates
instead of just one.

### Step D2.1 — Copy super-admin.conf from cp-1 to cp-2 FIRST

Easy to miss, and the doc exists partly because of this: `kubeadm join
--control-plane` does NOT generate `super-admin.conf` — only `kubeadm
init` does. Skip this and go straight to Step D2.3, and kubelet starts
on cp-2, sees the kube-vip static pod manifest from Phase B2 pointing
at a file that doesn't exist yet, and — because the manifest uses
`hostPath` with `type: FileOrCreate` — CREATES AN EMPTY placeholder
file at that path. kube-vip then crash-loops trying to parse an empty
file as a kubeconfig. See ADR-022 and Troubleshooting below.

```bash
# From the host (or from cp-1):
ssh cp-1 "sudo cat /etc/kubernetes/super-admin.conf" | ssh cp-2 "sudo tee /etc/kubernetes/super-admin.conf > /dev/null"
ssh cp-2 "sudo chmod 600 /etc/kubernetes/super-admin.conf && sudo chown root:root /etc/kubernetes/super-admin.conf"
```

### Step D2.2 — Get the control-plane join command from cp-1

```bash
# On cp-1:
sudo kubeadm init phase upload-certs --upload-certs
# Prints a fresh certificate-key (valid 2h) — copy the last line.

sudo kubeadm token create --print-join-command
# Prints the base join command (no --control-plane flag yet).
```

Combine the two into the full command:
kubeadm join <VIP>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash> --control-plane --certificate-key <certificate-key>
### Step D2.3 — Run the join on cp-2

```bash
# On cp-2:
sudo <the combined command from Step D2.2>
```

Expected: same shape of output as the original `kubeadm init` on cp-1
(certs, kubeconfig files, kubelet-start, etc.), ending with cp-2
joining as an additional control-plane node.

### Verify Phase D2

```bash
# On cp-1:
kubectl get nodes -o wide
# Both controlplane-1 and controlplane-2 should show Ready,
# ROLES=control-plane.

kubectl get pods -n kube-system | grep kube-vip
# Both kube-vip-controlplane-1 and kube-vip-controlplane-2 Running.
# Exactly ONE holds the lease at a time:
kubectl logs -n kube-system kube-vip-controlplane-1 | grep "assuming leadership"
```

---

## Phase E — Join the workers

**Script equivalent:** `./scripts/pipeline/02_kubeadm_join.sh`

Adds worker-1 and worker-2 to the cluster as worker nodes (no
control-plane flag).

### Step E.1 — Generate a fresh join token

The token saved in Step C.5 expires 24h after creation. Generating
fresh ensures the script works in any later session:

```bash
# On cp-1:
JOIN_CMD=$(sudo kubeadm token create --print-join-command)
echo "$JOIN_CMD"
```

Expected:
```
kubeadm join 10.215.138.X:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
```

Note there is no `sudo` prefix — `kubeadm token create
--print-join-command` deliberately leaves elevation to the caller.

### Step E.2 — Join worker-1

```bash
# Copy the JOIN_CMD value into the next ssh command (or pipe it):
ssh w-1 "sudo <paste the kubeadm join ... line here>"
```

Expected on the worker:
- `[preflight] Running pre-flight checks`
- `[kubelet-start] Starting the kubelet`
- `[kubelet-check] The kubelet is healthy after ~500ms`
- `This node has joined the cluster:` + 2 bullets about TLS.

### Step E.3 — Wait for worker-1 to become Ready

```bash
# On cp-1:
kubectl wait --for=condition=Ready node/worker-1 --timeout=120s
```

The node goes Ready when Calico schedules a calico-node pod on it
and that pod reports Ready (~30-60s).

### Step E.4 — Repeat for worker-2

```bash
ssh w-2 "sudo <same kubeadm join ... line>"
kubectl wait --for=condition=Ready node/worker-2 --timeout=120s
```

### Verify Phase E

```bash
# On cp-1:
kubectl get nodes -o wide
kubectl get pods -A -o wide
```

Expected:
- 3 nodes Ready: controlplane-1, worker-1, worker-2.
- 13 pods total Running: 9 from Phase D, plus calico-node and
  kube-proxy on each new worker (DaemonSets spread automatically).

---

## Phase F — Smoke test

Confirms a real workload can run on a worker.

```bash
# On cp-1:
kubectl run nginx-test --image=nginx --restart=Never
kubectl wait --for=condition=Ready pod/nginx-test --timeout=60s
kubectl get pod nginx-test -o wide
```

Expected:
- `nginx-test   1/1   Running   0   Xs   192.168.X.X   worker-1 or worker-2`
- The pod IP is in the Calico pod subnet (`192.168.0.0/16`).
- The NODE is a worker, NOT controlplane-1 (because cp-1 has the
  `node-role.kubernetes.io/control-plane:NoSchedule` taint).

Cleanup:

```bash
kubectl delete pod nginx-test
```

---

## Troubleshooting

**`kubectl get nodes` shows INTERNAL-IP=`<none>`**

The kubelet's `--node-ip` flag references an IP that doesn't exist
on the host. Check `/var/lib/kubelet/kubeadm-flags.env`. The IP
there should match `ip a show ens3`. If it doesn't, regenerate
the kubeadm config (Step C.1) using `hostname -I` or a known-good
static IP, `sudo kubeadm reset --force`, and re-run Step C.3.
See ADR-020.

**`crictl version` fails with `unknown service runtime.v1.RuntimeService`**

containerd is running with a config that doesn't expose CRI v1.
Check `/etc/containerd/config.toml` — line 1 must be `version = 3`.
If it's `version = 2`, redo Step B.6 (rewrite the file with v3
schema, restart containerd). See ADR-018.

**A worker stays NotReady for more than 2 minutes after join**

The calico-node pod on that worker isn't reaching Ready. Check:

```bash
kubectl get pod -n kube-system -o wide | grep <worker-name>
kubectl logs -n kube-system <calico-node-pod-name>
```

Common causes: image pull failure (docker.io rate limit), kernel
modules not loaded (skipped Step B.4 on that node), iptables rules
leftover from a previous join.

**`kubeadm join` fails with `[ERROR Port-10250]`**

The worker has a kubelet running from a previous join attempt.
Reset and retry:

```bash
ssh <worker> "sudo kubeadm reset --force"
ssh <worker> "sudo <kubeadm join ... line>"
```

EOF
ls -la docs/manual-bootstrap.md
wc -l docs/manual-bootstrap.md

**`kube-vip` crash-loops with `403 Forbidden ... leases.coordination.k8s.io`**

kube-vip is reading `/etc/kubernetes/admin.conf` instead of
`/etc/kubernetes/super-admin.conf`. On kubeadm >= 1.29, admin.conf's
client cert uses the `kubeadm:cluster-admins` group, only bound to
`cluster-admin` late in `kubeadm init` — too late for kube-vip's own
leader election, which needs to happen immediately. Fix the
`hostPath.path` in the kube-vip manifest (Phase B2, Step B2.2) to
point at `super-admin.conf`, then delete the pod so kubelet restarts
it: `kubectl delete pod -n kube-system kube-vip-<node>`. See ADR-022.

**`kube-vip` crash-loops on cp-2 with `no configuration has been provided`**

`/etc/kubernetes/super-admin.conf` on cp-2 is a 0-byte file. This
happens when kube-vip's manifest (with `hostPath type: FileOrCreate`)
was deployed before `kubeadm join --control-plane` ran — kubelet
starts during the join and creates an empty placeholder for a file
that `kubeadm join` never generates (only `kubeadm init` does). Fix:
copy the real file from cp-1 (Phase D2, Step D2.1), then force a
restart: `kubectl delete pod -n kube-system kube-vip-controlplane-2`.
See ADR-022.

## Phase G — Install Rancher and access it from Windows

Mirrors `scripts/pipeline/04_rancher.sh` + `scripts/rancher-tunnel.sh`.
See ADR-026 (dedicated Gateway), ADR-027 (cert-manager dependency),
ADR-028 (replica count), ADR-029 (SSH tunnel access, no SNI).

### Step G.1 — Namespace + self-signed TLS secret

```bash
kubectl create namespace cattle-system --dry-run=client -o yaml | kubectl apply -f -

TMPDIR=$(mktemp -d)
openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
    -keyout "${TMPDIR}/tls.key" -out "${TMPDIR}/tls.crt" \
    -subj "/CN=rancher.lab" -addext "subjectAltName=DNS:rancher.lab"
kubectl create secret tls rancher-tls -n cattle-system \
    --cert="${TMPDIR}/tls.crt" --key="${TMPDIR}/tls.key" \
    --dry-run=client -o yaml | kubectl apply -f -
rm -rf "${TMPDIR}"
```

The cert's CN is cosmetic now (see below) — access is via `localhost`,
not the `rancher.lab` name the cert was issued for, so the browser
will always show a hostname-mismatch warning alongside the
self-signed warning. Both are expected; accept and continue.

### Step G.2 — Gateway + HTTPRoute (no hostname restriction)

Apply `kubernetes/manifests/rancher/gateway-rancher.yaml` and
`httproute-rancher.yaml` (repo-tracked, hand-authored). Deliberately
has **no** `hostname` field on either resource — ADR-029 found that
Envoy's SNI matching on a fixed hostname breaks `localhost`-based
access, and there's only one backend on this Gateway anyway, so
hostname routing adds friction with zero benefit here.

```bash
kubectl apply -f kubernetes/manifests/rancher/gateway-rancher.yaml
kubectl apply -f kubernetes/manifests/rancher/httproute-rancher.yaml
```

### Step G.3 — Install Rancher via Helm

```bash
helm repo add rancher-stable https://releases.rancher.com/server-charts/stable
helm repo update
helm upgrade --install rancher rancher-stable/rancher \
    --version 2.14.3 \
    --namespace cattle-system \
    --set hostname=rancher.lab \
    --set networkExposure.type=none \
    --set tls=ingress \
    --set ingress.tls.source=secret \
    --set replicas=1
```

`ingress.tls.source=secret` avoids a cert-manager dependency we don't
have yet (ADR-027). `replicas=1` is a RAM-budget choice, not a
required fix (ADR-028) — the default 3 also works, just heavier.

### Step G.4 — Access from Windows (SSH tunnel, no direct routing)

Windows has no route to the Multipass bridge (`10.215.138.0/24`) by
default, and getting one working hits a dead end on the VM's reply
path (ADR-029). Don't fight that — tunnel through cp-1 instead, which
is already a full peer of the bridge:

```bash
ssh -L 8443:$(kubectl get gateway/rancher -n cattle-system -o jsonpath='{.status.addresses[0].value}'):443 cp-1 -N
```

(or just run `scripts/rancher-tunnel.sh`, which does the same thing
plus fetches a fresh kubeconfig first). Leave it running, then open
`https://localhost:8443/` in the Windows browser. Accept the
certificate warnings (self-signed + hostname mismatch — both
expected). Log in with the `bootstrapPassword` set at install time.

### Verify Phase G

- `kubectl get pods -n cattle-system` — `rancher-*` and
  `rancher-webhook-*` pods `1/1 Running`.
- `https://localhost:8443/healthz` (through the tunnel) → `ok`.
- Rancher UI shows cluster `local` as `Active` — this cluster
  auto-registers itself since Rancher runs on top of it directly
  (chart default `addLocal: true`), no separate import step needed.
