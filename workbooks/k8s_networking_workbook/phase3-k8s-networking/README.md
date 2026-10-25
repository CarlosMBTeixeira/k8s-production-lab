# Phase 3 — Kubernetes networking

Weeks 10–17. The Phase 2 primitives, now assembled by real CNIs and
proxies: Calico on k8slab, Cilium and OVN-Kubernetes on kind, kube-proxy in
all three modes, CoreDNS, NetworkPolicy, Gateway API and the mesh datapath.

## Where

| Env | Labs | Bring-up |
|---|---|---|
| **k8slab**, 2 workers, option 0 | 3.01, 3.02, 3.04, 3.05, 3.06, 3.09 | `LAB_WORKERS=2 bash ../../scripts/pipeline/main.sh` → 0 |
| **k8slab**, 2 workers, option 8 | 3.12 | same, → 8 (Istio + Kiali) |
| **kind** | 3.03, 3.07, 3.08, 3.10, 3.11, 3.13 | per lab; `unset KUBECONFIG` first |

Shell setup for k8slab labs, on the WSL host:

```bash
export KUBECONFIG=~/k8slab/kubernetes/admin.conf
kubectl get nodes -o wide           # controlplane-1/2, worker-1/2
```

Node access: `ssh w-1` / `ssh w-2` (passwordless sudo), or a netshoot debug
pod in the node's namespaces (see `../setup/README.md`). kind nodes:
`docker exec -it <node> bash`, or netshoot in the node's netns:
`docker run --rm -it --net container:<node> --privileged nicolaka/netshoot:v0.13`.

## Rules for this phase

- Every lab works in its own `lab-*` namespace and deletes it at cleanup.
- **RISKY** steps (node netfilter, sysctls, CNI config, kube-system objects)
  are boxed with blast radius and rollback. Read the box, then decide.
- `break.sh` runs on the **WSL host**. It talks to the cluster with kubectl
  and to nodes over `ssh` (k8slab) or `docker exec` (kind). Labs whose
  break touches kube-system or nodes say so in the lab's Risk line.
- Images are pinned: `nicolaka/netshoot:v0.13` (client/debug) and
  `traefik/whoami:v1.10.3` (server: echoes hostname, IP, headers; `/data?size=N&unit=MB`
  streams N MB; `POST /health` sets the readiness status code).

## Labs

| # | Lab | Env | h | Week |
|---|---|---|---|---|
| 3.01 | [Calico pod networking anatomy](01-calico-pod-anatomy/) | k8slab | 5 | 10 |
| 3.02 | [kube-proxy in iptables mode](02-kube-proxy-iptables/) | k8slab | 5 | 11 |
| 3.03 | [kube-proxy IPVS and nftables modes](03-kube-proxy-modes/) | kind | 5 | 11 |
| 3.04 | [CoreDNS and DNS troubleshooting](04-coredns/) | k8slab | 5 | 12 |
| 3.05 | [NetworkPolicy on Calico](05-networkpolicy-calico/) | k8slab | 5 | 12 |
| 3.06 | [MTU and conntrack in the cluster](06-mtu-conntrack/) | k8slab | 5 | 14 |
| 3.07 | [Cilium with kube-proxy replacement](07-cilium-kpr/) | kind | 5 | 14 |
| 3.08 | [Cilium policies and Hubble](08-cilium-policy-hubble/) | kind | 5 | 15 |
| 3.09 | [Gateway API in depth](09-gateway-api/) | k8slab | 5 | 15 |
| 3.10 | [OVN-Kubernetes anatomy](10-ovn-k-anatomy/) | kind | 5 | 16 |
| 3.11 | [OVN-Kubernetes operations — the OpenShift view](11-ovn-k-operations/) | kind | 5 | 16 |
| 3.12 | [The service mesh datapath](12-mesh-datapath/) | k8slab (8) | 3 | 17 |
| 3.13 | [**Capstone** — Cilium end to end](13-capstone-cilium/) | kind | 7 | 17 |

Order within a week is free; across weeks, keep it — 3.07 before 3.08 before 3.13, 3.10 before 3.11.

## Exit check (end of week 17)

The Phase 3 criteria in [`../README.md`](../README.md#phase-3--kubernetes-networking-phase3-k8s-networking).
Then write `../runbooks/phase3-k8s-networking.md`.
