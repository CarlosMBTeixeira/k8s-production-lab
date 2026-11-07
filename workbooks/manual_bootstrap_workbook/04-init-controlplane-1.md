# Stage 4 — Start the cluster on controlplane-1

Run this stage on **controlplane-1 only**.

## 4.1 — Write the kubeadm config

A config file instead of command-line flags, so every choice is
written down in one place.

```bash
# On controlplane-1
VIP=10.215.138.200                         # same VIP as stage 3
NODE_IP=$(hostname -I | awk '{print $1}')  # this VM's own address
echo "VIP=${VIP} NODE_IP=${NODE_IP}"

cat <<EOF | sudo tee /etc/kubernetes/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
nodeRegistration:
  criSocket: "unix:///var/run/containerd/containerd.sock"
  name: "$(hostname)"
  kubeletExtraArgs:
    - name: node-ip
      value: "${NODE_IP}"
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: "v1.35.6"
controlPlaneEndpoint: "${VIP}:6443"
networking:
  podSubnet: "192.168.0.0/16"
  serviceSubnet: "10.96.0.0/12"
  dnsDomain: "cluster.local"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: "systemd"
EOF
```

What each choice does:

- **`controlPlaneEndpoint` is the VIP**, not this node's IP. It is
  written into every certificate and kubeconfig, which is what lets
  controlplane-2 join later. It can't be added after `init`.
- **`node-ip`** pins the address kubelet reports for the node
  (ADR-020). Check that `NODE_IP` matches the address `multipass list`
  shows for controlplane-1.
- **`podSubnet: 192.168.0.0/16`** is Calico's default pool, so the
  Calico manifest in stage 5 needs no edits.
- **`cgroupDriver: systemd`** matches `SystemdCgroup = true` in
  containerd (stage 2.5).

## 4.2 — Pull the images first (optional)

Surfaces registry problems before `init` starts, and makes `init` faster.

```bash
# On controlplane-1
sudo kubeadm config images pull --config /etc/kubernetes/kubeadm-config.yaml
```

## 4.3 — Run kubeadm init

```bash
# On controlplane-1
sudo kubeadm init --config /etc/kubernetes/kubeadm-config.yaml --upload-certs \
    | tee ~/kubeadm-init.log
```

`--upload-certs` stores the control-plane certificates as an encrypted
Secret in the cluster, so controlplane-2 can fetch them in stage 6
instead of you copying them by hand.

Expected, in order:

- `[certs]` lines generating the cluster CA and component certificates,
- `[kubelet-start] Starting the kubelet` — kubelet now starts the static
  pods: etcd, API server, controller-manager, scheduler **and kube-vip**,
- `[api-check] The API server is healthy`,
- `Your Kubernetes control-plane has initialized successfully!`,
- two `kubeadm join` commands at the end. You don't need to save them —
  stages 6 and 7 generate fresh ones.

## 4.4 — Give kubectl a kubeconfig

```bash
# On controlplane-1
mkdir -p ~/.kube
sudo cp /etc/kubernetes/admin.conf ~/.kube/config
sudo chown "$(id -u):$(id -g)" ~/.kube/config
chmod 600 ~/.kube/config
```

## Check

```bash
# On controlplane-1
kubectl get nodes
```

Expected:

```
NAME             STATUS     ROLES           AGE   VERSION
controlplane-1   NotReady   control-plane   1m    v1.35.6
```

`NotReady` is correct for now: there's no pod network yet, so kubelet
won't report the node as ready.

Confirm kube-vip holds the VIP and the API answers on it:

```bash
# On controlplane-1
ip -4 addr show | grep 10.215.138.200          # the VIP, as an extra address
kubectl -n kube-system get pods -o wide         # kube-vip-controlplane-1 Running
grep server ~/.kube/config                      # https://<VIP>:6443
```

```bash
# WSL host
curl -k https://10.215.138.200:6443/livez        # ok
```

Next: [Stage 5 — Pod network (Calico)](05-calico.md)
