# Lab 3.07 — Cilium with kube-proxy replacement

| | |
|---|---|
| **Objective** | Install Cilium on a cluster with no CNI and no kube-proxy, then find where Services, routing and the overlay live in its eBPF datapath — and why tcpdump shows something different from lab 3.02. |
| **Time** | 5 h (week 14) |
| **Where** | kind `lab-cilium` on the WSL host |
| **Risk** | Safe — disposable cluster |

## 1. Prerequisites

- Labs 2.08, 2.11, 3.02. `cilium` and `hubble` CLIs (`setup/install-tools.sh`). k8slab down (RAM).

```bash
unset KUBECONFIG
cd <workbook>/phase3-k8s-networking/07-cilium-kpr
kind create cluster --config ../../setup/kind/cilium.yaml
kubectl get nodes                               # NotReady: no CNI
kubectl -n kube-system get ds                   # no kube-proxy at all
```

## 2. Hands-on

### 2.1 Install

```bash
cilium install \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=lab-cilium-control-plane --set k8sServicePort=6443 \
  --set ipam.mode=kubernetes
cilium status --wait
cilium version                                  # record the Cilium version in the tracker
kubectl get nodes
```

`k8sServiceHost` is needed because without kube-proxy nothing implements
the `kubernetes` Service yet — the agent must reach the API server
directly. `ipam.mode=kubernetes` uses each node's `podCIDR` (10.244.x.0/24)
instead of Cilium's own pool, so addresses read like the kind config.

```bash
cilium config view | grep -E '^(kube-proxy-replacement|routing-mode|tunnel-protocol|enable-bpf-masquerade|ipam|enable-ipv4-masquerade) '
kubectl apply -f web.yaml && kubectl -n lab-cil rollout status deploy/web && kubectl -n lab-cil wait --for=condition=Ready pod/client
```

### 2.2 The agent's view

```bash
CIL=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=lab-cilium-worker -o name)
X="kubectl -n kube-system exec $CIL -c cilium-agent --"
$X cilium-dbg status --verbose | sed -n '/KubeProxyReplacement Details/,/^$/p'
$X cilium-dbg endpoint list                     # one per local pod: ID, identity, policy state, IP
$X cilium-dbg service list | grep -A3 "$(kubectl -n lab-cil get svc web -o jsonpath='{.spec.clusterIP}')"
$X cilium-dbg bpf lb list | head -20            # the same, as the BPF map the datapath reads
$X cilium-dbg bpf ct list global | head -5      # Cilium's own conntrack, not the kernel's
$X cilium-dbg bpf ipcache list | head           # IP → identity (+ tunnel endpoint) for the whole cluster
$X bpftool net show | head -20                  # tc programs on every lxc* veth and on eth0
```

The kernel's iptables and conntrack are mostly bystanders now:

```bash
docker exec lab-cilium-worker iptables-save | grep -c KUBE      # 0 (or near)
docker exec lab-cilium-worker iptables-save | grep -c CILIUM    # a few chains, not per Service
```

### 2.3 Node plumbing

```bash
docker exec lab-cilium-worker ip -br link       # cilium_host, cilium_net, cilium_vxlan, lxc*
docker exec lab-cilium-worker ip route          # pod CIDRs of other nodes via cilium_host
docker exec lab-cilium-worker ip -d link show cilium_vxlan | head -3   # vxlan … dstport 8472
```

### 2.4 Where did the ClusterIP go?

In lab 3.02 a capture in the client showed packets **to the ClusterIP**,
and the node DNATed them. Predict what you'll see here:

```bash
VIP=$(kubectl -n lab-cil get svc web -o jsonpath='{.spec.clusterIP}')
kubectl -n lab-cil exec client -- sh -c "tcpdump -nni eth0 -c4 tcp port 80 & sleep 1; curl -s -o /dev/null $VIP; sleep 1"
```

The SYN goes **to a pod IP**. Cilium's socket-level load balancer rewrites
the destination in `connect()`, before a packet exists. There is no
per-packet DNAT for pod-to-Service traffic and no conntrack entry to go
stale — and no VIP on the wire to grep for. `getpeername()` still returns
the VIP to the application.

### 2.5 The overlay on the wire

```bash
NODE=lab-cilium-worker2
docker run --rm --net container:$NODE --privileged nicolaka/netshoot:v0.13 \
  tcpdump -nni eth0 -c4 udp port 8472 &
kubectl -n lab-cil exec client -- sh -c 'for i in 1 2 3; do curl -s -o /dev/null web; done'
wait
```

VXLAN on 8472 (lab 2.08's Linux default, kept by Cilium), inner pod-to-pod.
The VNI isn't a network id here: Cilium puts the **source security
identity** in it, so the receiving node knows who sent the packet without
looking up the IP. Lab 3.08 uses that identity.

### 2.6 NodePort without kube-proxy

```bash
W=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' lab-cilium-worker)
for i in 1 2 3; do curl -s http://$W:30080 | grep -E 'Hostname|RemoteAddr'; done
$X cilium-dbg service list | grep 30080
```

The BPF program on the node's `eth0` handles NodePort at tc (or XDP, with
`loadBalancer.acceleration`). DSR and Maglev are flags away
(`loadBalancer.mode=dsr`, `loadBalancer.algorithm=maglev`); read what they
change in the Cilium docs' kube-proxy-free page and note one sentence each.

### 2.7 Health

```bash
$X cilium-health status                         # node-to-node and endpoint reachability, per node
cilium status
```

## 3. Verification

| Check | Expected |
|---|---|
| §2.1 | all nodes Ready, no kube-proxy, `kube-proxy-replacement true`, `routing-mode tunnel`, `tunnel-protocol vxlan` |
| §2.2 | `service list` shows the VIP with 3 backends; `bpftool net show` lists `cil_from_container` on lxc devices |
| §2.4 | the client's own capture shows SYNs to a 10.244.x.y pod IP, not to `$VIP` |
| §2.5 | UDP 8472 between node IPs, inner 10.244.x.y |
| §2.6 | NodePort answers from the WSL host with 3 different Hostnames |

## 4. Break/fix

```bash
bash break.sh          # needs lab-cilium up with Cilium installed as in §2.1
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

**Done when** `client` reaches `web` by name and the NodePort answers from the
WSL host, and you can say which component implements Services in this cluster.

<details><summary>Hint (only after 20 minutes)</summary>

Pod IPs work; Services don't. In this cluster, who is supposed to turn a
ClusterIP into a pod IP?
</details>

Solution: [`solution.md`](solution.md).

## 5. Cleanup

Keep `lab-cilium` for lab 3.08 if it's next. Otherwise:

```bash
kind delete cluster --name lab-cilium
```

## 6. What I should be able to explain after this

- With kube-proxy replacement, Cilium's BPF programs (socket-level LB for pods, tc/XDP on node interfaces for NodePort) implement Services from maps the agent fills — `cilium-dbg service list` / `bpf lb list` replace `iptables-save`.
- Socket LB translates the ClusterIP at `connect()`, so captures show backend pod IPs and nothing is DNATed per packet.
- Cilium's VXLAN (8472) carries the source security identity in the VNI; routes to other nodes' pod CIDRs go via `cilium_host`, and `cilium-dbg bpf ipcache list` maps every IP to an identity and tunnel endpoint.
