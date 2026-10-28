# Lab 3.10 — OVN-Kubernetes anatomy

| | |
|---|---|
| **Objective** | Run OpenShift's CNI on kind and map a pod-to-pod and pod-to-Service packet through OVN's logical switches, routers and load balancers, down to OVS flows and Geneve on the wire. |
| **Time** | 5 h (week 16), of which ~15 min is the upstream bring-up (the first image build is ~5 min) |
| **Where** | kind cluster `ovn`, built by OVN-Kubernetes' own `contrib/kind.sh` |
| **Risk** | Safe — disposable cluster. The script installs nothing on the host besides the kind cluster and images. |

Why this lab exists: the Claranet platform is OpenShift, and OpenShift's
default CNI is OVN-Kubernetes. Everything in labs 3.01–3.09 has an OVN-K
equivalent, with different tools.

## 1. Prerequisites

- Labs 2.08, 3.01, 3.02, 3.05. k8slab down.
- On the WSL host: `git`, `docker`, `kind`, `kubectl`, `helm`, and
  `jinjanate` (from jinjanator), which `kind.sh` renders its templates with.
  No Go: the image (and `ovnkube-trace`, §2.7) build inside upstream's Go
  container. Ubuntu 24.04's Python refuses `pip install --user`
  (PEP 668), so give jinjanator its own venv:

  ```bash
  python3 -m venv ~/.local/share/venvs/jinjanator
  ~/.local/share/venvs/jinjanator/bin/pip install jinjanator
  ln -sf ~/.local/share/venvs/jinjanator/bin/jinjanate ~/.local/bin/jinjanate
  ```

  (`pipx install jinjanator` does the same if you have pipx; `kind.sh`
  tries pipx itself when `jinjanate` is missing.)
- `kind.sh` may ask for your sudo password once: it raises
  `fs.inotify.max_user_instances` to 512 on the host if it's lower (not
  persistent). With the default flags it changes nothing else outside
  Docker.

### Bring-up (upstream's procedure — the flags are theirs, and change)

Official doc: the OVN-Kubernetes docs page "Launching OVN-Kubernetes on KIND"
(in the repo under `docs/`). Read it once; follow it if it disagrees with this.

```bash
unset KUBECONFIG
mkdir -p ~/src && cd ~/src
git clone https://github.com/ovn-kubernetes/ovn-kubernetes.git && cd ovn-kubernetes
git log -1 --format='%h %cs'            # record the commit in the tracker
cd contrib
./kind.sh --help | less                 # read the options for this version (HA, IPv6, IC, ANP, gateway mode…)
./kind.sh 2>&1 | tee ~/kindsh.log      # builds the image from source and creates cluster "ovn" (~5 min)
export KUBECONFIG=$HOME/ovn.conf        # where the script writes the kubeconfig
kubectl get nodes -o wide               # ovn-control-plane, ovn-worker, ovn-worker2
```

If your version's script names the cluster or kubeconfig differently, it
prints them at the end. AdminNetworkPolicy (lab 3.11) needs no flag: the
script enables it (`global.enableAdminNetworkPolicy=true`) and installs the
ANP/BANP CRDs on every run.

```bash
cd <workbook>/phase3-k8s-networking/10-ovn-k-anatomy
kubectl apply -f apps.yaml && kubectl -n lab-ovn rollout status deploy/web && kubectl -n lab-ovn wait --for=condition=Ready pod/client
kubectl -n lab-ovn get pods -o wide
```

## 2. Hands-on

### 2.1 What runs, and where the databases are

```bash
kubectl -n ovn-kubernetes get pods -o wide
kubectl -n ovn-kubernetes get pods -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName,CONTAINERS:.spec.containers[*].name
kubectl -n kube-system get ds                                  # no kube-proxy: OVN implements Services
```

In interconnect mode (the default) every node is its own zone with its
**own** NB/SB databases: the `ovnkube-node` pod on each node runs
`nb-ovsdb`, `sb-ovsdb`, `ovn-northd`, `ovnkube-controller` and
`ovn-controller`. OVS itself runs in the `ovs-node` pod (`ovs-daemons`).
Older central mode had one `ovnkube-db` pod instead. Set:

```bash
NBPOD=$(kubectl -n ovn-kubernetes get pod -l app=ovnkube-node --field-selector spec.nodeName=ovn-worker -o name)
NB="kubectl -n ovn-kubernetes exec $NBPOD -c nb-ovsdb -- ovn-nbctl"
SB="kubectl -n ovn-kubernetes exec $NBPOD -c sb-ovsdb -- ovn-sbctl"
OVSPOD=$(kubectl -n ovn-kubernetes get pod -l app=ovs-node --field-selector spec.nodeName=ovn-worker -o name)
OVS="kubectl -n ovn-kubernetes exec $OVSPOD -c ovs-daemons --"
```

### 2.2 The logical topology

```bash
$NB show | head -60
$NB ls-list; $NB lr-list
$NB lsp-list ovn-worker | head              # logical switch ports: <namespace>_<pod>, plus k8s-ovn-worker, stor-…
kubectl get node ovn-worker -o jsonpath='{.metadata.annotations}' | tr ',' '\n' | grep k8s.ovn.org
```

Draw it (this is the picture to keep):

```
 pod ── [logical switch "ovn-worker" 10.244.x.0/24] ── ovn_cluster_router ── join ── GR_ovn-worker ── ext_ovn-worker ── breth0/eth0 ── outside
                                                              │                    (gateway router: SNAT, NodePort, LB)
                                                       transit_switch ── other nodes' ovn_cluster_router (remote ports tstor-<node>)
```

One logical switch per node (its pod subnet), a cluster router per zone,
a `transit_switch` (100.88.0.0/16) joining the zones' routers, and a
per-node gateway router for north-south. This NB only holds ovn-worker's
zone: the other nodes appear as `type: remote` ports on the transit switch. Logical, not physical:
`ovn-controller` on each node compiles all of it into OpenFlow on `br-int`.

### 2.3 Services are OVN load balancers

```bash
VIP=$(kubectl -n lab-ovn get svc web -o jsonpath='{.spec.clusterIP}')
$NB lb-list | grep -E "UUID|$VIP"           # VIP:80 → pod1:80,pod2:80
$NB --columns=name,load_balancer_group list Logical_Switch ovn-worker   # LBs come in groups
$NB --columns=name,load_balancer list Load_Balancer_Group            # clusterLBGroup holds the Service LBs
```

The Service LB isn't attached to switches one by one: it's in
`clusterLBGroup`, and that group is attached to every node switch and
gateway router.

Same EndpointSlice-to-datapath idea as kube-proxy, rendered as OVN
`Load_Balancer` rows that ovn-controller turns into `ct(nat)` flows.

### 2.4 Southbound: chassis and tunnels

```bash
$SB show                                    # one Chassis per node, Encap geneve <node IP>
$SB --format=table --columns=logical_port,chassis list Port_Binding | grep -E 'logical_port|lab-ovn'
```

Each zone's SB binds only its own node's pods: from ovn-worker's SB you see
the web pod that runs there, not the client on ovn-worker2.

### 2.5 OVS on the node

```bash
$OVS ovs-vsctl show                         # br-int: pod ports, a geneve port ovn-<chassis>-0 per remote node; breth0 (eth0 lives here)
docker exec ovn-worker ip -br addr | grep -E 'breth0|eth0'   # the node IP is on breth0, not eth0 ("shared gateway")
docker exec ovn-worker ip -br link | grep genev              # genev_sys_6081: the kernel device behind those ports
$OVS ovs-ofctl -O OpenFlow13 dump-flows br-int | wc -l       # thousands of flows for a tiny cluster
```

### 2.6 Geneve on the wire

Curl a web pod on the **other** node from the client by IP (a Service
name adds the DNS lookups to the capture, and a same-node backend never
touches the tunnel):

```bash
CNODE=$(kubectl -n lab-ovn get pod client -o jsonpath='{.spec.nodeName}')
read RIP RNODE < <(kubectl -n lab-ovn get pod -l app=web -o jsonpath='{range .items[*]}{.status.podIP} {.spec.nodeName}{"\n"}{end}' | grep -v " $CNODE$" | head -1)
echo "client on $CNODE, remote web $RIP on $RNODE"    # none → kubectl -n lab-ovn rollout restart deploy/web
docker run --rm --net container:$RNODE --privileged nicolaka/netshoot:v0.13 tcpdump -nni eth0 -c4 udp port 6081 </dev/null &
sleep 3; kubectl -n lab-ovn exec client -- curl -s -o /dev/null $RIP
wait $!
```

UDP 6081; the VNI is the logical datapath's tunnel key and the Geneve
option carries OVN's logical ingress/egress port ids. Overhead ≥ 50 bytes:
check the pod MTU (`kubectl -n lab-ovn exec client -- ip link show eth0`,
1400 on kind.sh's default).

### 2.7 Trace before you capture: ovnkube-trace

`ovnkube-trace` runs `ovn-trace` (logical) and `ofproto/trace` (OVS)
for a pod-to-pod or pod-to-Service flow and tells you where it would go or
die. `kind.sh` builds it inside the image builder but doesn't ship it in
the image or leave it on the host, so build it once in the same Go
container (about a minute):

```bash
docker run --rm -u $(id -u):$(id -g) -e GOCACHE=/tmp/gocache -e GOFLAGS=-mod=vendor \
  -v ~/src/ovn-kubernetes:/src -w /src/go-controller quay.io/projectquay/golang:1.26 \
  go build -o /src/ovnkube-trace ./cmd/ovnkube-trace    # Go version: see go-controller/go.mod
T=~/src/ovn-kubernetes/ovnkube-trace
WEB=$(kubectl -n lab-ovn get pod -l app=web -o jsonpath='{.items[0].metadata.name}')
$T -src-namespace lab-ovn -src client -dst-namespace lab-ovn -dst $WEB -tcp -dst-port 80 -loglevel 0
$T -src-namespace lab-ovn -src client -dst-namespace lab-ovn -service web -tcp -dst-port 80 -loglevel 0
```

Read the summary lines: "ovn-trace … indicates success" for each direction.
`-loglevel 2` prints every logical stage (ls_in_acl, ls_in_lb, lr_in_ip_routing…).

On OpenShift the same tool runs against `openshift-ovn-kubernetes` (lab 3.11).

## 3. Verification

| Check | Expected |
|---|---|
| §2.1 | no kube-proxy; ovnkube pods on every node |
| §2.2 | logical switch named after the node, `ovn_cluster_router`, `join`, `transit_switch`, `GR_<node>`; LSPs `lab-ovn_<pod>` for pods on that node |
| §2.3 | an LB row with `$VIP:80` → two pod IPs, inside `clusterLBGroup` |
| §2.5 | node IP on `breth0`; geneve ports `ovn-<chassis>-0` on br-int; `genev_sys_6081` in the node |
| §2.6 | UDP 6081 between node IPs, inner client → web pod :80 |
| §2.7 | both traces report success in both directions |

## 4. Break/fix

```bash
bash break.sh          # rebuilds lab-ovn and makes one change
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

**Done when** `kubectl -n lab-ovn exec client -- curl -s -m3 web` answers and
ovnkube-trace reports success for client → web.

<details><summary>Hint (only after 20 minutes)</summary>

Don't capture first. Trace, and read which logical stage drops it.
</details>

Solution: [`solution.md`](solution.md).

## 5. Cleanup

Keep the cluster for lab 3.11. Afterwards: `kind delete cluster --name ovn`.

## 6. What I should be able to explain after this

- OVN-K's model: a logical switch per node, a cluster router per zone joined by a transit switch (interconnect mode: one zone per node, each with its own NB/SB), per-node gateway routers for north-south (node IP on `breth0`), all compiled by `ovn-controller` into OpenFlow on `br-int`; Geneve (UDP 6081) between nodes.
- Services are OVN `Load_Balancer` rows in a load-balancer group attached to the node switches and gateway routers — there is no kube-proxy; NetworkPolicies are ACLs on port groups.
- `ovnkube-trace` (ovn-trace + ofproto/trace) shows where a flow goes or drops before any capture; the stage name (`ls_in_acl`, `ls_in_lb`, …) names the cause.
