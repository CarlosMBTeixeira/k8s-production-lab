# Stage 5 — Pod network (Calico)

Calico gives pods their IPs and routes traffic between nodes (ADR-016).
Install it once from controlplane-1. It runs as a DaemonSet, so it
reaches the other nodes on its own as they join.

## 5.1 — Apply the manifest

```bash
# On controlplane-1
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.33.0/manifests/calico.yaml
```

Expected: a long list of `created` lines — CRDs, RBAC, a ConfigMap, the
`calico-node` DaemonSet and the `calico-kube-controllers` Deployment.

## 5.2 — Wait for it to come up

```bash
# On controlplane-1
kubectl -n kube-system rollout status daemonset/calico-node --timeout=300s
kubectl -n kube-system rollout status deployment/calico-kube-controllers --timeout=300s
kubectl wait --for=condition=Ready node/controlplane-1 --timeout=300s
```

The first run takes a couple of minutes while the Calico images download.

## Check

```bash
# On controlplane-1
kubectl get nodes -o wide
kubectl get pods -n kube-system
```

Expected:

- `controlplane-1` is `Ready`, and its `INTERNAL-IP` is the VM's address.
- Everything in `kube-system` is `Running`: `calico-node`,
  `calico-kube-controllers`, two `coredns`, `etcd-controlplane-1`,
  `kube-apiserver-controlplane-1`, `kube-controller-manager-controlplane-1`,
  `kube-scheduler-controlplane-1`, `kube-proxy` and `kube-vip-controlplane-1`.

CoreDNS stays `Pending` until a pod network exists, so seeing it
`Running` is the confirmation Calico works.

Next: [Stage 6 — Join controlplane-2](06-join-controlplane-2.md)
