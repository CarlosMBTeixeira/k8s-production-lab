# Stage 7 — Join the workers and final check

Workers join with a plain `kubeadm join`: no `--control-plane` flag and
no certificate key.

## 7.1 — Generate a join command

```bash
# On controlplane-1
sudo kubeadm token create --print-join-command
```

Expected:

```
kubeadm join 10.215.138.200:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
```

The output has no `sudo` — add it yourself when you run it.

## 7.2 — Join worker-1 and worker-2

```bash
# On worker-1, then on worker-2 — same command on both
sudo kubeadm join 10.215.138.200:6443 --token <token> \
    --discovery-token-ca-cert-hash sha256:<hash>
```

Expected on each worker: `This node has joined the cluster`.

## 7.3 — Wait for them to become Ready

A worker becomes `Ready` once its `calico-node` pod is running, usually
within 30–60 seconds.

```bash
# On controlplane-1
kubectl wait --for=condition=Ready node/worker-1 node/worker-2 --timeout=180s
```

## Final check

### All four nodes

```bash
# On controlplane-1
kubectl get nodes -o wide
```

Expected:

```
NAME             STATUS   ROLES           VERSION   INTERNAL-IP
controlplane-1   Ready    control-plane   v1.35.6   10.215.138.x
controlplane-2   Ready    control-plane   v1.35.6   10.215.138.x
worker-1         Ready    <none>          v1.35.6   10.215.138.x
worker-2         Ready    <none>          v1.35.6   10.215.138.x
```

### System pods on the right nodes

```bash
# On controlplane-1
kubectl get pods -A -o wide
```

Expected, all `Running`:

- one `calico-node` and one `kube-proxy` on **each** of the 4 nodes,
- `etcd`, `kube-apiserver`, `kube-controller-manager`, `kube-scheduler`
  and `kube-vip` on **each** control plane,
- `calico-kube-controllers` and two `coredns`.

### Control planes don't take ordinary workloads

```bash
# On controlplane-1
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints[*].key
```

Expected: both control planes have `node-role.kubernetes.io/control-plane`,
and the workers have no taints.

### A test pod runs on a worker and is reachable

```bash
# On controlplane-1
kubectl create deployment smoke --image=nginx --replicas=2
kubectl rollout status deployment/smoke --timeout=120s
kubectl get pods -l app=smoke -o wide
```

Expected: 2 pods `Running`, each on a **worker**, with IPs from
`192.168.0.0/16`.

Check that a Service and cluster DNS work across nodes:

```bash
# On controlplane-1
kubectl expose deployment smoke --port=80
kubectl run probe --image=busybox:1.36 --restart=Never --rm -it -- \
    wget -qO- http://smoke.default.svc.cluster.local | head -4
```

Expected: the first lines of the nginx welcome page.

Clean up:

```bash
# On controlplane-1
kubectl delete service smoke
kubectl delete deployment smoke
```

### What two control planes do and don't give you

Two API servers and two kube-vip instances mean the API endpoint isn't
tied to one VM. **etcd is a different story.** It needs a majority of
its members to serve anything, and with two members the majority is
both of them. Stop either control plane and etcd stops answering, which
takes the API down with it: reads and writes both fail. kube-vip can't
renew its lease either, because the lease lives in the API.

So this cluster doesn't survive losing a control plane: with two, the
API is down until the stopped node comes back. Tolerating one failed
control plane takes three. Don't test failover by stopping a control
plane here — it shows an outage, not a failover.

---

The cluster is built: 2 control planes and 2 workers, all `Ready`.

To use `kubectl` from the WSL host instead of from a VM:

```bash
# WSL host
mkdir -p ~/.kube
multipass exec controlplane-1 -- sudo cat /etc/kubernetes/admin.conf > ~/.kube/k8slab-manual.conf
chmod 600 ~/.kube/k8slab-manual.conf
export KUBECONFIG=~/.kube/k8slab-manual.conf
kubectl get nodes
```
