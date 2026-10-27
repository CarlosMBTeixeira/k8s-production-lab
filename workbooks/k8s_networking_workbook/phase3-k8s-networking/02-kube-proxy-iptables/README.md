# Lab 3.02 — kube-proxy in iptables mode

| | |
|---|---|
| **Objective** | Read a real ClusterIP and NodePort in kube-proxy's chains, watch them follow readiness and scaling, and see what `externalTrafficPolicy` does to source IPs and reachability. |
| **Time** | 5 h (week 11) |
| **Where** | k8slab, 2 workers, option 0 · WSL host + `ssh w-1` / `ssh w-2` |
| **Risk** | Hands-on: lab namespace only. Break/fix patches the **kube-proxy DaemonSet** (RISKY, see §4). |

## 1. Prerequisites

- Lab 2.10 (you built this by hand), lab 3.01.

```bash
export KUBECONFIG=~/k8slab/kubernetes/admin.conf
kubectl apply -f web.yaml
kubectl -n lab-svc rollout status deploy/web
kubectl -n lab-svc get pods -o wide
VIP=$(kubectl -n lab-svc get svc web -o jsonpath='{.spec.clusterIP}')
W1=$(kubectl get node worker-1 -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
W2=$(kubectl get node worker-2 -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
```

## 2. Hands-on

### 2.1 Which mode, and is it healthy

```bash
kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep -E '^mode|clusterCIDR'
ssh w-1 "curl -s localhost:10249/metrics | grep -E '^kubeproxy_sync_proxy_rules_(last_timestamp_seconds|duration_seconds_count)'"
ssh w-1 "curl -s localhost:10256/healthz"            # kube-proxy's own health, per node
```

`mode: ""` means iptables. The last-sync timestamp is the number you'd
alert on: if it stops moving, that node's Services are frozen.

### 2.2 Follow the ClusterIP

```bash
ssh w-1 "sudo iptables-save -t nat" > /tmp/w1-nat.txt   # "Warning: iptables-legacy tables present": empty leftovers, ignore. The rules are in iptables-nft.
grep "$VIP" /tmp/w1-nat.txt                            # KUBE-SERVICES → KUBE-SVC-XXXX
SVC=$(grep -- "-d $VIP/32" /tmp/w1-nat.txt | grep -o 'KUBE-SVC-[A-Z0-9]*' | head -1)
grep -- "-A $SVC " /tmp/w1-nat.txt                     # probability cascade → KUBE-SEP-*
grep -- '-A KUBE-SEP-' /tmp/w1-nat.txt | grep 'lab-svc/web:http'   # per endpoint: hairpin MARK-MASQ, then DNAT
grep -E 'KUBE-MARK-MASQ|KUBE-POSTROUTING' /tmp/w1-nat.txt | head
```

Map each line to the chain you wrote in lab 2.10: `LAB-SERVICES` = `KUBE-SERVICES`,
`LAB-SVC-WEB` = `KUBE-SVC-…`, `LAB-SEP-n` = `KUBE-SEP-…`, `LAB-MARK-MASQ` = `KUBE-MARK-MASQ`.
Spot the hairpin rule (`-s <podIP>/32 -j KUBE-MARK-MASQ`) in each SEP chain.

```bash
kubectl -n lab-svc exec client-w1 -- sh -c 'for i in $(seq 12); do curl -s web | grep Hostname; done' | sort | uniq -c
```

### 2.3 Endpoints follow readiness

```bash
kubectl -n lab-svc get endpointslices -l kubernetes.io/service-name=web -o wide
POD=$(kubectl -n lab-svc get pods -l app=web -o jsonpath='{.items[0].metadata.name}')
PIP=$(kubectl -n lab-svc get pod $POD -o jsonpath='{.status.podIP}')
kubectl -n lab-svc exec client-w1 -- curl -s -X POST -d 500 http://$PIP/health   # whoami: make /health return 500
kubectl -n lab-svc get pods -w        # READY 0/1 within ~2 s; Ctrl-C
kubectl -n lab-svc get endpointslices -l kubernetes.io/service-name=web -o yaml | grep -B2 -A4 "$PIP"   # ready: false
ssh w-1 "sudo iptables-save -t nat | grep -c 'lab-svc/web:http' "                                  # one SEP fewer
kubectl -n lab-svc exec client-w1 -- curl -s -X POST -d 200 http://$PIP/health   # back
kubectl -n lab-svc scale deploy/web --replicas=5; sleep 5
ssh w-1 "sudo iptables-save -t nat | grep -- '-A $SVC '"                       # 5 rules: 1/5, 1/4, 1/3, 1/2, rest
```

The chain is the **EndpointSlice, rendered**. When they disagree, the proxy
on that node is broken.

### 2.4 NodePort and externalTrafficPolicy

```bash
kubectl -n lab-svc scale deploy/web --replicas=1
kubectl -n lab-svc get pods -o wide              # one pod; note its node
for n in $W1 $W2; do echo "== $n"; curl -s -m3 http://$n:30080 | grep -E 'Hostname|RemoteAddr'; done
```

From the WSL host, both nodes answer; `RemoteAddr` is **not** your host's
address (10.215.138.1). It's the node's IP, or the other node's `tunl0` IP:
`externalTrafficPolicy: Cluster` SNATs so the reply can come back through
the node that received it.

```bash
kubectl -n lab-svc patch svc web-np -p '{"spec":{"externalTrafficPolicy":"Local"}}'
for n in $W1 $W2; do echo "== $n"; curl -s -m3 http://$n:30080 | grep -E 'Hostname|RemoteAddr' || echo "  no answer"; done
ssh w-1 "sudo iptables-save -t nat | grep -E 'KUBE-(EXT|SVL)' | grep lab-svc"                  # no KUBE-SVL jump on the node without the pod
ssh w-1 "sudo iptables-save -t filter | grep 'lab-svc/web-np:http has no local endpoints'"     # the DROP is in the filter table
```

Now `RemoteAddr` is 10.215.138.1 — the real client — and the node without a
local endpoint drops the connection (`KUBE-EXTERNAL-SERVICES … has no local
endpoints … -j DROP`, in the **filter** table). That's why cloud LBs
health-check `healthCheckNodePort` with `Local`. Kubernetes only allocates
that port for `type: LoadBalancer`, so switch the Service over for a moment
(k8slab's MetalLB hands it an external IP from the VM subnet):

```bash
kubectl -n lab-svc patch svc web-np -p '{"spec":{"type":"LoadBalancer"}}'
HC=$(kubectl -n lab-svc get svc web-np -o jsonpath='{.spec.healthCheckNodePort}')
curl -s $W1:$HC; curl -s $W2:$HC              # "localEndpoints": 0 on one node, 1 on the other
kubectl -n lab-svc patch svc web-np -p '{"spec":{"type":"NodePort"}}'
```

```bash
kubectl -n lab-svc patch svc web-np -p '{"spec":{"externalTrafficPolicy":"Cluster"}}'
kubectl -n lab-svc scale deploy/web --replicas=3
```

### 2.5 Session affinity, briefly

```bash
kubectl -n lab-svc patch svc web -p '{"spec":{"sessionAffinity":"ClientIP"}}'
kubectl -n lab-svc exec client-w1 -- sh -c 'for i in $(seq 6); do curl -s web | grep Hostname; done' | uniq -c   # one backend
ssh w-1 "sudo iptables-save -t nat | grep -- '-A $SVC' | grep recent"            # -m recent: the affinity table
kubectl -n lab-svc patch svc web -p '{"spec":{"sessionAffinity":"None"}}'
```

## 3. Verification

| Check | Expected |
|---|---|
| §2.1 | `mode: ""`; last-sync timestamp within the last ~30 s |
| §2.2 | `KUBE-SVC-*` with `--probability 0.33333` and `0.50000` rules; DNAT targets = the 3 pod IPs |
| §2.3 | SEP disappears within seconds of READY 0/1; 5 rules at 5 replicas |
| §2.4 | `Cluster`: both nodes answer, RemoteAddr = the receiving node's IP or `tunl0` IP · `Local`: one node answers, RemoteAddr = 10.215.138.1; health check `localEndpoints` 0 vs 1 |
| §2.5 | one Hostname with ClientIP affinity |

## 4. Break/fix

> **RISKY.** `break.sh` adds a node affinity to the **kube-proxy DaemonSet**
> in `kube-system` so it stops running on worker-2, then redeploys `web`.
> **Blast radius:** Service changes stop reaching worker-2's rules
> (existing rules stay, frozen) for every namespace. Nothing on worker-1
> or the control planes changes.
> **Rollback:** `kubectl -n kube-system patch ds kube-proxy --type json -p '[{"op":"remove","path":"/spec/template/spec/affinity"}]'`.
> The script refuses to run if kube-proxy already has an affinity.

```bash
bash break.sh
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

**Done when** `client-w2` reaches `web` 10 times out of 10 and kube-proxy
runs on all four nodes.

<details><summary>Hint (only after 20 minutes)</summary>

Only pods on one node are affected. Compare that node's rendered rules with
the EndpointSlice — and with the other node's rules.
</details>

Solution: [`solution.md`](solution.md).

## 5. Cleanup

```bash
kubectl delete -f web.yaml
rm -f /tmp/w1-nat.txt
```

## 6. What I should be able to explain after this

- kube-proxy (iptables) renders each EndpointSlice into `KUBE-SVC`/`KUBE-SEP` chains on **every node**, so Service behaviour is per-node and a broken proxy breaks only clients on that node.
- Readiness removes endpoints, not pods; the rule count follows `ready: true` endpoints within seconds.
- `externalTrafficPolicy: Cluster` SNATs (any node answers, client IP lost); `Local` preserves the client IP but only nodes with a local endpoint answer — which is what `healthCheckNodePort` tells a load balancer.
