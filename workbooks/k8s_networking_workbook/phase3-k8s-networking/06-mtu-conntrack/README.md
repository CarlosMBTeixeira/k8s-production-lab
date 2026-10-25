# Lab 3.06 — MTU and conntrack in the cluster

| | |
|---|---|
| **Objective** | Read the MTU budget of a Calico IPIP cluster, watch kube-proxy clean up UDP conntrack entries, and fill a node's conntrack table to see what a full table does to a Kubernetes node. |
| **Time** | 5 h (week 14) |
| **Where** | k8slab, 2 workers, option 0 · WSL host + `ssh w-1` / `ssh w-2` |
| **Risk** | §2.1–2.3 read-only. **§2.4 is RISKY** (node sysctl, auto-rollback). The break/fix adds nftables on both workers and needs a **Calico config change** to fix (RISKY, see §4). |

## 1. Prerequisites

- Labs 2.06, 2.09, 3.01, 3.04.

```bash
export KUBECONFIG=~/k8slab/kubernetes/admin.conf
kubectl apply -f apps.yaml && kubectl -n lab-mtu wait --for=condition=Ready pod --all --timeout=120s
C='kubectl -n lab-mtu exec client --'
SRV=$(kubectl -n lab-mtu get pod server -o jsonpath='{.status.podIP}')
```

## 2. Hands-on

### 2.1 The MTU budget

```bash
$C ip link show eth0 | grep -o 'mtu [0-9]*'                    # 1480
ssh w-1 "ip -o link show tunl0 | grep -o 'mtu [0-9]*'; ip -o link show \$(ip -o route show default | awk '{print \$5}') | grep -o 'mtu [0-9]*'"
kubectl -n kube-system get cm calico-config -o jsonpath='{.data.veth_mtu}'; echo   # "0" = auto-detect
$C ping -c1 -M do -s 1452 $SRV        # 1452 + 28 = 1480: fits
$C ping -c1 -M do -s 1453 $SRV        # "message too long, mtu=1480": refused inside the pod, before the wire
$C tracepath -n $SRV
```

Budget: NIC 1500 − IPIP 20 = tunl0/pod 1480. Calico auto-detects it from the
node's uplink. Change the underlay (a VPN, a cloud with 1450, jumbo frames
on some nodes) and the auto-detected value can be wrong for some paths.

### 2.2 The node's conntrack table

```bash
kubectl debug node/worker-1 -it --profile=sysadmin --image=nicolaka/netshoot:v0.13
# in the debug shell (worker-1's netns):
conntrack -C; cat /proc/sys/net/netfilter/nf_conntrack_max
conntrack -L -p tcp --dport 6443 | head -3        # kubelet → API server through the VIP
conntrack -L -p udp --dport 53 | head -5          # pod DNS: orig dst 10.96.0.10, reply src = a CoreDNS pod IP
conntrack -S | head -4
```

Every Service connection from every pod on the node is an entry here, in
the node's root namespace, translated by kube-proxy's DNAT.

### 2.3 kube-proxy cleans UDP entries (the lab 2.06 bug, handled)

Keep the debug shell open:

```bash
# debug shell
conntrack -E -p udp --orig-port-dst 53 -e DESTROY &
```

```bash
# WSL host: a client that keeps one source port, then remove a CoreDNS pod
$C sh -c 'while true; do dig -b 0.0.0.0#40000 +short +time=1 +tries=1 server.lab-mtu.svc.cluster.local >/dev/null; sleep 0.5; done' &
kubectl -n kube-system delete pod $(kubectl -n kube-system get pods -l k8s-app=kube-dns -o jsonpath='{.items[0].metadata.name}')
```

The debug shell prints `[DESTROY]` lines for flows whose reply source was
the deleted pod's IP: kube-proxy deletes UDP conntrack entries for removed
endpoints so source-port-reusing clients don't stick to a dead backend.
Stop the loop (`kill %1` on the host) and exit the debug shell.

### 2.4 A full table (RISKY)

> **RISKY.** `ct-exhaust.sh start` sets worker-2's `nf_conntrack_max` to
> (current count + 400) and starts a pod holding 800 connections.
> **Blast radius:** every **new** connection to, from or through worker-2
> — pods, kubelet probes, calico-node health checks — can fail.
> **Rollback:** automatic after 180 s, or now with `bash ct-exhaust.sh stop`.

```bash
bash ct-exhaust.sh start
sleep 20
ssh w-2 "cat /proc/sys/net/netfilter/nf_conntrack_count /proc/sys/net/netfilter/nf_conntrack_max"
ssh w-2 "sudo dmesg | grep -i 'table full' | tail -3"
$C curl -s -m3 -o /dev/null -w '%{http_code}\n' http://$SRV/        # new flow into worker-2: predict
kubectl get events -A --field-selector involvedObject.kind=Pod --sort-by=.lastTimestamp | tail -5   # probe failures?
bash ct-exhaust.sh stop
$C curl -s -m3 -o /dev/null -w '%{http_code}\n' http://$SRV/
```

What you saw is what a SYN flood on a NodePort, a DNS-heavy batch job or a
connection-leaking client does to a real node: established flows survive,
everything new — including the kubelet's own probes — drops.

## 3. Verification

| Check | Expected |
|---|---|
| §2.1 | pod and tunl0 at 1480; `-s 1452` works, `-s 1453` "message too long" |
| §2.2 | DNS entries with `dst=10.96.0.10` in orig and a CoreDNS pod IP in reply |
| §2.3 | `[DESTROY] udp … dport=53` lines within seconds of deleting the CoreDNS pod |
| §2.4 | count = max, `table full, dropping packet` in dmesg, curl → `000`, then `200` after stop |

## 4. Break/fix

> **RISKY.** `break.sh` adds an nftables table `inet lab-underlay` on
> **worker-1 and worker-2**, emulating a new underlay link between them with
> an effective MTU of 1400 that drops larger packets silently, and turns
> GRO off on both workers' uplinks (so the emulation judges wire-sized packets). The ticket
> says that link stays — so the fix is a **cluster-wide Calico MTU change**
> (`calico-config`, calico-node restart, pod restarts).
> **Blast radius:** large pod-to-pod packets between the two workers until
> fixed; the fix changes the MTU of every pod created afterwards.
> **Full rollback** is in `solution.md` (MTU back to auto, remove the tables).

```bash
bash break.sh
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

**Done when**, with `inet lab-underlay` still in place on both workers:
`$C curl -s -m10 -o /dev/null -w '%{http_code} %{size_download}\n' "http://$SRV/data?size=5&unit=MB"`
prints `200 5000000` (pods recreated after the fix: refresh `$SRV`).

<details><summary>Hint (only after 20 minutes)</summary>

Find the largest packet that gets through between the two pods, then work
out what the pods' MTU has to be for every packet to fit. Calico has one
setting for it.
</details>

Solution: [`solution.md`](solution.md).

## 5. Cleanup

```bash
bash ct-exhaust.sh stop 2>/dev/null
kubectl delete ns lab-mtu
kubectl get pods | grep node-debugger | awk '{print $1}' | xargs -r kubectl delete pod
for n in w-1 w-2; do ssh $n sudo nft delete table inet lab-underlay 2>/dev/null; ssh $n 'sudo ethtool -K $(ip -o route show default | awk "{print \$5}") gro on'; done
```

If you changed the Calico MTU, roll it back as in `solution.md` before the next lab.

## 6. What I should be able to explain after this

- The MTU budget: underlay MTU − encapsulation overhead = tunnel and pod MTU; Calico auto-detects it from the node's uplink, and a smaller path somewhere in the underlay needs a manual `veth_mtu` (or `FelixConfiguration`), a calico-node restart and pod restarts.
- Every Service flow on a node is a conntrack entry in the node's root namespace; kube-proxy deletes UDP entries of removed endpoints, which is why the stale-DNS bug is rare now and serious when the cleanup fails.
- A full conntrack table drops new flows of every kind on that node — application traffic and kubelet probes alike — while established ones survive; `nf_conntrack_count/max` is the metric.
