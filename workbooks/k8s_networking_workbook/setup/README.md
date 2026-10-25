# Setup — the three environments

One at a time. The host has 19 GiB of RAM and k8slab alone takes ~16 GB.

| Env | Up | Down | RAM |
|---|---|---|---|
| netlab | `setup/netlab.sh up` (a+b) · `up c` (Containerlab) | `setup/netlab.sh down` | 3 GB (a+b) · +3 GB (c) |
| k8slab | `LAB_WORKERS=2 bash ../../scripts/pipeline/main.sh` → **0** | `../../scripts/lab-management.sh destroy --force` | ~16 GB |
| kind | `kind create cluster --config setup/kind/<file>.yaml` | `kind delete cluster --name <name>` | 2–4 GB per cluster |

Paths are relative to the workbook folder. Run commands from there.

---

## Once per host

```bash
bash setup/install-tools.sh          # kind, cilium, hubble, calicoctl → ~/.local/bin
```

Record the printed versions in the README tracker. Labs that depend on a
version say which line to check.

## netlab

```bash
bash setup/netlab.sh up              # netlab-a + netlab-b (1.5G each, no Docker) — Phase 2
bash setup/netlab.sh up c            # netlab-c (3G, Docker + Containerlab) — Phase 1, 4.01, 4.05
multipass shell netlab-a             # the workbook is mounted at /workbook
```

**Why three VMs.** Docker loads `br_netfilter` and sets the iptables
FORWARD policy to DROP. On a VM with Docker, a hand-built bridge or router
silently drops forwarded traffic — a lesson worth having once (lab 2.02
does it on purpose on netlab-c), not on every lab. netlab-a and netlab-b
stay Docker-free.

Both VMs sit on the Multipass bridge (10.215.138.0/24), so they reach each
other directly. That bridge is the "physical wire" of Phase 2's two-host
labs. If `apt` fails inside a VM on first boot, the host's NAT rules are
missing; run `../../scripts/fix-network-access.sh` and relaunch.

To reset a VM after a lab has wrecked it: `multipass delete --purge netlab-a && bash setup/netlab.sh up a`.

Containerlab images (pulled on netlab-c by `netlab.sh`):
`quay.io/frrouting/frr:10.2.1` and `nicolaka/netshoot:v0.13`. Override with
`FRR_IMAGE=` / `NETSHOOT_IMAGE=` if a newer tag is wanted.

## k8slab

Phase 3 needs cross-node traffic, so **2 workers**, and menu option **0**
(cluster + Gateway API + MetalLB + cert-manager, nothing heavier). Labs
that need more say so: 3.12 uses option **8** (Istio), 4.07 uses option
**3** (observability).

```bash
export KUBECONFIG=~/k8slab/kubernetes/admin.conf
LAB_WORKERS=2 bash ../../scripts/pipeline/main.sh
```

Nodes: `controlplane-1`, `controlplane-2` (tainted NoSchedule), `worker-1`,
`worker-2`. SSH aliases `cp-1`, `cp-2`, `w-1`, `w-2`, with passwordless sudo.

**Node tools.** The nodes have `ip`, `tcpdump`, `iptables`, `nft`. For
`conntrack`, `bpftool`, `tshark` and friends, use a debug container in the
node's network namespace instead of installing anything:

```bash
kubectl debug node/worker-1 -it --profile=sysadmin --image=nicolaka/netshoot:v0.13
# you are in the node's netns and PID ns; the node's filesystem is at /host
# when done: kubectl get pods | grep node-debugger   then delete that pod
```

The debug pod lands in `default`. Delete it when done — it is privileged.

**Do not touch** namespaces you did not create: `kube-system`,
`metallb-system`, `envoy-gateway-system`, `cert-manager`, `istio-system`,
`monitoring`, `argocd`, `cattle-system`. Every lab works in a `lab-*`
namespace.

## kind

Configs in `setup/kind/`, all 1 control plane + 2 workers:

| File | Cluster | CNI | kube-proxy | Labs |
|---|---|---|---|---|
| `cilium.yaml` | lab-cilium | none (Cilium) | none (Cilium replaces it) | 3.07, 3.08, 3.13, 4.04 |
| `calico.yaml` | lab-calico | none (Calico) | iptables | 4.03, 4.08 |
| `kube-proxy-ipvs.yaml` | lab-ipvs | kindnet | ipvs | 3.03 |
| `kube-proxy-nftables.yaml` | lab-nft | kindnet | nftables | 3.03 |
| `plain.yaml` | lab-plain | kindnet | iptables | 4.02, 4.06 |

OVN-Kubernetes (3.10, 3.11) uses upstream's own kind script; see lab 3.10.

kind nodes are containers on the Docker network `kind`
(`docker network inspect kind` for its subnet). Get a node shell with
`docker exec -it lab-cilium-worker bash`.

**Known issue — "too many open files" in kind pods.** The host's
`fs.inotify.max_user_instances` is 128; kind's documentation recommends 512
when running several nodes. This is a host sysctl (**RISKY, small**: affects
only the WSL host's inotify limit, reverts on WSL restart):

```bash
sudo sysctl fs.inotify.max_user_instances=512   # rollback: sudo sysctl fs.inotify.max_user_instances=128
```

Only do this if a kind pod actually fails with that error.
