# Stage 6 — Join controlplane-2

controlplane-2 becomes a second full control plane: its own etcd member,
API server, controller-manager and scheduler, plus the second kube-vip
candidate.

## 6.1 — Copy `super-admin.conf` to controlplane-2 first

Do this **before** the join (ADR-022). `kubeadm join` never creates
`super-admin.conf` — only `kubeadm init` does. But the kube-vip
manifest from stage 3 is already on controlplane-2 and points at that
file. When the join starts kubelet, kubelet starts kube-vip. Because the
volume type is `FileOrCreate`, kubelet would create an **empty** file in
its place, and kube-vip would crash-loop with `no configuration has
been provided`.

```bash
# WSL host
multipass exec controlplane-1 -- sudo cat /etc/kubernetes/super-admin.conf \
  | multipass exec controlplane-2 -- sudo tee /etc/kubernetes/super-admin.conf >/dev/null
multipass exec controlplane-2 -- sudo chmod 600 /etc/kubernetes/super-admin.conf
multipass exec controlplane-2 -- sudo ls -l /etc/kubernetes/super-admin.conf
```

Expected: a file of several KB, not 0 bytes.

## 6.2 — Build the control-plane join command

Two pieces, both generated on controlplane-1:

```bash
# On controlplane-1
sudo kubeadm init phase upload-certs --upload-certs
```

The last line of the output is the **certificate key** (64 hex
characters). It decrypts the certificates uploaded to the cluster and is
valid for 2 hours.

```bash
# On controlplane-1
sudo kubeadm token create --print-join-command
```

That prints the base join command, with a token valid for 24 hours:

```
kubeadm join 10.215.138.200:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
```

Add `--control-plane --certificate-key <key>` to the end. The full
command looks like:

```
kubeadm join 10.215.138.200:6443 --token <token> \
    --discovery-token-ca-cert-hash sha256:<hash> \
    --control-plane --certificate-key <key>
```

## 6.3 — Run the join on controlplane-2

```bash
# On controlplane-2
sudo kubeadm join 10.215.138.200:6443 --token <token> \
    --discovery-token-ca-cert-hash sha256:<hash> \
    --control-plane --certificate-key <key>
```

Expected: it downloads the certificates, generates this node's own
certificates, adds a new etcd member, starts the static pods, and ends
with `This node has joined the cluster and a new control plane instance
was created`.

## 6.4 — Give kubectl a kubeconfig on controlplane-2

```bash
# On controlplane-2
mkdir -p ~/.kube
sudo cp /etc/kubernetes/admin.conf ~/.kube/config
sudo chown "$(id -u):$(id -g)" ~/.kube/config
chmod 600 ~/.kube/config
```

## Check

```bash
# On controlplane-1 or controlplane-2
kubectl get nodes
kubectl -n kube-system get pods -o wide | grep -E 'etcd|kube-apiserver|kube-vip'
kubectl -n kube-system get lease plndr-cp-lock -o jsonpath='{.spec.holderIdentity}{"\n"}'
```

Expected:

- `controlplane-1` and `controlplane-2` both `Ready`, role `control-plane`.
- Two of each: `etcd-*`, `kube-apiserver-*`, `kube-vip-*`, all `Running`.
- The lease names exactly one holder — the control plane that currently
  owns the VIP.

Confirm etcd has two members:

```bash
# On controlplane-1
kubectl -n kube-system exec etcd-controlplane-1 -- etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    member list -w table
```

Expected: two members, both `started`.

Next: [Stage 7 — Join the workers and final check](07-join-workers.md)
