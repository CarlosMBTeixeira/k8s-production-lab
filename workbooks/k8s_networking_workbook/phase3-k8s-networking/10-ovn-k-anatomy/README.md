# Lab 3.10 — OVN-Kubernetes anatomy

| | |
|---|---|
| **Objective** | Run OpenShift's CNI on kind and map a pod-to-pod and pod-to-Service packet through OVN's logical switches, routers and load balancers, down to OVS flows and Geneve on the wire. |
| **Time** | 5 h (week 16), of which ~1 h is the upstream bring-up |
| **Where** | kind cluster `ovn`, built by OVN-Kubernetes' own `contrib/kind.sh` |
| **Risk** | Safe — disposable cluster. The script installs nothing on the host besides the kind cluster and images. |

Why this lab exists: the Claranet platform is OpenShift, and OpenShift's
default CNI is OVN-Kubernetes. Everything in labs 3.01–3.09 has an OVN-K
equivalent, with different tools.

## 1. Prerequisites

- Labs 2.08, 3.01, 3.02, 3.05. k8slab down.
- On the WSL host: `git`, `docker`, `kind`, `kubectl`, `go` (the version
  in upstream's `go-controller/go.mod`), `python3` and `pip install --user jinjanator` (provides the `j2` the script uses).

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
./kind.sh                               # builds the image from source and creates cluster "ovn"
export KUBECONFIG=$HOME/ovn.conf        # where the script writes the kubeconfig
kubectl get nodes -o wide               # ovn-control-plane, ovn-worker, ovn-worker2
```

If your version's script names the cluster or kubeconfig differently, it
prints them at the end. Lab 3.11 may need AdminNetworkPolicy support: check
`--help` now for an ANP/admin-network-policy flag and, if it exists,
re-create with it.

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

Find the container that runs the **northbound** DB (`nb-ovsdb`) and the one
with `ovs-vsctl` (usually `ovs-daemons` or the ovnkube-node pod). In
interconnect mode (current default) every node has its **own** NB/SB
databases for its zone; older/central mode has one `ovnkube-db` pod. Set:

```bash
NBPOD=<pod with nb-ovsdb on ovn-worker>;  NB="kubectl -n ovn-kubernetes exec $NBPOD -c nb-ovsdb -- ovn-nbctl"
SB="kubectl -n ovn-kubernetes exec $NBPOD -c sb-ovsdb -- ovn-sbctl"     # same pod in IC mode
OVSPOD=<pod with ovs-vsctl on ovn-worker>; OVS="kubectl -n ovn-kubernetes exec $OVSPOD -c <container> --"
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
                                                       (distributed)                (gateway router: SNAT, NodePort, LB)
```

One logical switch per node (its pod subnet), one distributed cluster
router, a per-node gateway router for north-south. Logical, not physical:
`ovn-controller` on each node compiles all of it into OpenFlow on `br-int`.

### 2.3 Services are OVN load balancers

```bash
VIP=$(kubectl -n lab-ovn get svc web -o jsonpath='{.spec.clusterIP}')
$NB lb-list | grep -E "UUID|$VIP"           # VIP:80 → pod1:80,pod2:80
$NB --columns=name,load_balancer list Logical_Switch | head -20     # attached to every node switch
```

Same EndpointSlice-to-datapath idea as kube-proxy, rendered as OVN
`Load_Balancer` rows that ovn-controller turns into `ct(nat)` flows.

### 2.4 Southbound: chassis and tunnels

```bash
$SB show                                    # one Chassis per node, Encap geneve <node IP>
$SB --columns=logical_port,chassis list Port_Binding | grep lab-ovn
```

### 2.5 OVS on the node

```bash
$OVS ovs-vsctl show                         # br-int (pods, genev_sys_6081), breth0 (the node's eth0 lives here)
docker exec ovn-worker ip -br addr | grep -E 'breth0|eth0'   # the node IP is on breth0, not eth0 ("shared gateway")
$OVS ovs-ofctl -O OpenFlow13 dump-flows br-int | wc -l       # thousands of flows for a tiny cluster
```

### 2.6 Geneve on the wire

```bash
docker run --rm --net container:ovn-worker --privileged nicolaka/netshoot:v0.13 tcpdump -nni eth0 -c4 udp port 6081 &
kubectl -n lab-ovn exec client -- sh -c 'for i in 1 2 3 4; do curl -s -o /dev/null web; done'
wait
```

UDP 6081, Geneve options carrying OVN's logical ingress/egress port ids.
Overhead ≥ 50 bytes: check the pod MTU (`kubectl -n lab-ovn exec client -- ip link show eth0`).

### 2.7 Trace before you capture: ovnkube-trace

`ovnkube-trace` runs `ovn-trace` (logical) and `ofproto/trace` (OVS)
for a pod-to-pod or pod-to-Service flow and tells you where it would go or
die. If `kind.sh` built from source it's in `go-controller/_output/go/bin/`;
otherwise `cd ~/src/ovn-kubernetes/go-controller && go build -o /tmp/ovnkube-trace ./cmd/ovnkube-trace`.

```bash
T=~/src/ovn-kubernetes/go-controller/_output/go/bin/ovnkube-trace     # or /tmp/ovnkube-trace
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
| §2.2 | logical switches named after nodes, `ovn_cluster_router`, `join`, `GR_<node>`; LSP `lab-ovn_client` |
| §2.3 | an LB row with `$VIP:80` → two pod IPs |
| §2.5 | node IP on `breth0`; `genev_sys_6081` on br-int |
| §2.6 | UDP 6081 between node IPs |
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

- OVN-K's model: a logical switch per node, a distributed cluster router, per-node gateway routers for north-south (node IP on `breth0`), all compiled by `ovn-controller` into OpenFlow on `br-int`; Geneve (UDP 6081) between nodes.
- Services are OVN `Load_Balancer` rows on the node switches and gateway routers — there is no kube-proxy; NetworkPolicies are ACLs on port groups.
- `ovnkube-trace` (ovn-trace + ofproto/trace) shows where a flow goes or drops before any capture; the stage name (`ls_in_acl`, `ls_in_lb`, …) names the cause.
