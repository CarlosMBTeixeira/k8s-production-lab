# Stage 2 — Prepare every node

Run **every block in this stage on all 4 VMs**. Nothing here depends on
the other nodes, so you can work through all four terminals in parallel.

Open one terminal per VM and log in with Multipass:

```bash
# WSL host — one per terminal
multipass shell controlplane-1
multipass shell controlplane-2
multipass shell worker-1
multipass shell worker-2
```

You land as the `ubuntu` user, with passwordless `sudo`. Plain `ssh
<ip>` doesn't work: VMs created without cloud-init only accept
Multipass's own key, not your `~/.ssh` keys.

## 2.1 — Update packages

```bash
# On every node
sudo apt-get update
sudo apt-get -y dist-upgrade
```

## 2.2 — Turn swap off

kubelet refuses to start with swap on unless it's configured to allow
it, which this lab doesn't do. Multipass images usually have no swap,
but make sure, and keep it off after a reboot:

```bash
# On every node
sudo swapoff -a
sudo sed -i -E 's/^([^#].*\sswap\s.*)$/# \1/' /etc/fstab
swapon --show        # must print nothing
```

## 2.3 — Kernel modules and sysctls

`overlay` is the filesystem containerd uses for image layers.
`br_netfilter` plus the `bridge-nf-call` sysctls let iptables see
bridged pod traffic. `ip_forward` lets the node route between pods. The
two inotify limits stop pods that watch a lot of files from failing with
"too many open files" (ADR-040).

```bash
# On every node
sudo modprobe overlay
sudo modprobe br_netfilter

cat <<'EOF' | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

cat <<'EOF' | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
fs.inotify.max_user_instances       = 8192
fs.inotify.max_user_watches         = 524288
EOF

sudo sysctl --system
```

Check:

```bash
# On every node
lsmod | grep -E '^(overlay|br_netfilter)\b'
sysctl net.bridge.bridge-nf-call-iptables net.ipv4.ip_forward fs.inotify.max_user_watches
```

Expected: both modules listed; the sysctls print `1`, `1` and `524288`.

## 2.4 — Install containerd

From Docker's apt repository — only the `containerd.io` package, not
Docker itself.

```bash
# On every node
sudo apt-get -y install ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod 0644 /etc/apt/keyrings/docker.asc

cat <<'EOF' | sudo tee /etc/apt/sources.list.d/docker.sources
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt-get update
sudo apt-get -y install containerd.io
sudo systemctl enable --now containerd
sudo ctr version
```

## 2.5 — Configure containerd

The package's default config disables the CRI plugin that kubelet talks
to. Replace it with a v3-schema config (containerd 2.x, ADR-018) that
uses the systemd cgroup driver, matching kubelet's (ADR-013).

```bash
# On every node
sudo mkdir -p /etc/containerd
cat <<'EOF' | sudo tee /etc/containerd/config.toml
version = 3
root = "/var/lib/containerd"
state = "/run/containerd"
oom_score = -999

[grpc]
  address = "/run/containerd/containerd.sock"
  uid = 0
  gid = 0

[plugins.'io.containerd.cri.v1.images']
  snapshotter = "overlayfs"

[plugins.'io.containerd.cri.v1.images'.pinned_images]
  sandbox = "registry.k8s.io/pause:3.10"

[plugins.'io.containerd.cri.v1.runtime']
  disable_apparmor = false

[plugins.'io.containerd.cri.v1.runtime'.containerd]
  default_runtime_name = "runc"

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc]
  runtime_type = "io.containerd.runc.v2"

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]
  SystemdCgroup = true
EOF

sudo systemctl restart containerd
while [ ! -S /run/containerd/containerd.sock ]; do sleep 1; done
sudo containerd config dump >/dev/null && echo "config OK"
```

Restart right after writing the file, before installing anything else
(ADR-019): later steps talk to containerd and need the new config live.

## 2.6 — Install crictl

The CLI for talking to containerd the way kubelet does. Ships
separately from containerd (ADR-014). The checksum is the one pinned in
the automation.

```bash
# On every node
CRICTL_VERSION=v1.35.0
CRICTL_SHA256=2e141e5b22cb189c40365a11807d69b76b9b3caced89fac2f4ec879408ce2177

cd /tmp
curl -fsSL -o crictl.tar.gz \
    "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz"
echo "${CRICTL_SHA256}  crictl.tar.gz" | sha256sum -c    # must print: crictl.tar.gz: OK
sudo tar -C /usr/local/bin -xzf crictl.tar.gz
sudo chmod 0755 /usr/local/bin/crictl
rm crictl.tar.gz
cd ~

cat <<'EOF' | sudo tee /etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF

sudo crictl version
```

Expected: `RuntimeName: containerd` and `RuntimeApiVersion: v1`.

## 2.7 — Install kubeadm, kubelet and kubectl

From the per-minor-version Kubernetes repo, pinned to the exact version
and held so a routine `apt upgrade` can't move them (ADR-015).

```bash
# On every node
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.35/deb/Release.key \
    | sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
sudo chmod 0644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

cat <<'EOF' | sudo tee /etc/apt/sources.list.d/kubernetes.sources
Types: deb
URIs: https://pkgs.k8s.io/core:/stable:/v1.35/deb/
Suites: /
Signed-By: /etc/apt/keyrings/kubernetes-apt-keyring.gpg
EOF

sudo apt-get update
sudo apt-get -y install kubeadm=1.35.6-1.1 kubelet=1.35.6-1.1 kubectl=1.35.6-1.1
sudo apt-mark hold kubeadm kubelet kubectl
sudo systemctl enable kubelet
```

Enable kubelet but don't start it — `kubeadm init` / `kubeadm join`
start it with the right config. Until then it restarts in a loop every
few seconds; that's expected.

## Check

```bash
# On every node
systemctl is-active containerd                        # active
sudo crictl version | grep RuntimeApiVersion          # v1
kubeadm version -o short                              # v1.35.6
kubelet --version                                     # Kubernetes v1.35.6
kubectl version --client | head -1                    # Client Version: v1.35.6
apt-mark showhold                                     # kubeadm kubectl kubelet
```

All four nodes must pass before stage 3.

Next: [Stage 3 — Floating API address (kube-vip)](03-kube-vip.md)
