# Lab 3.04 — CoreDNS and DNS troubleshooting

| | |
|---|---|
| **Objective** | Read how a pod resolves names (resolv.conf, search list, ndots, CoreDNS plugins, upstream), measure the cost of `ndots:5`, and diagnose DNS failures from the pod outward. |
| **Time** | 5 h (week 12) |
| **Where** | k8slab, 2 workers, option 0 · WSL host |
| **Risk** | Hands-on: read-only plus the lab namespace. Break/fix edits the **CoreDNS ConfigMap** in kube-system (RISKY, see §4). |

## 1. Prerequisites

- Phase 1 drill 08 (DNS), lab 2.06 (conntrack), lab 3.02.

```bash
export KUBECONFIG=~/k8slab/kubernetes/admin.conf
kubectl apply -f apps.yaml
kubectl -n lab-dns rollout status deploy/web; kubectl -n lab-dns rollout status sts/db
kubectl -n lab-dns wait --for=condition=Ready pod/client pod/client-ndots1
C='kubectl -n lab-dns exec client --'
```

## 2. Hands-on

### 2.1 The resolver chain

```bash
$C cat /etc/resolv.conf
kubectl -n kube-system get svc kube-dns -o wide                # the nameserver is this ClusterIP
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}'
ssh w-1 "sudo grep resolvConf /var/lib/kubelet/config.yaml; cat /run/systemd/resolve/resolv.conf | grep nameserver"
```

Draw it: pod → `nameserver 10.96.0.10` (kube-proxy DNATs to a CoreDNS pod)
→ CoreDNS `kubernetes` plugin answers `cluster.local` → everything else goes
to `forward . /etc/resolv.conf` → **the CoreDNS pod's** resolv.conf, which is
the node's file given by kubelet's `resolvConf`. On Ubuntu that's
`/run/systemd/resolve/resolv.conf` (the real upstream), not `/etc/resolv.conf`
(`127.0.0.53`, which inside CoreDNS would point at itself — the `loop`
plugin exists to catch that and crash loudly).

### 2.2 Record types Kubernetes serves

```bash
$C dig +short web.lab-dns.svc.cluster.local                    # the ClusterIP
$C dig +short db.lab-dns.svc.cluster.local                     # headless: pod IPs
$C dig +short db-0.db.lab-dns.svc.cluster.local                # one StatefulSet pod
$C dig +short SRV _http._tcp.web.lab-dns.svc.cluster.local     # port + target
$C dig +short -x $(kubectl -n lab-dns get svc web -o jsonpath='{.spec.clusterIP}')   # PTR
$C dig +search +short web                                      # short name via the search list
$C dig +short kubernetes.default                               # wrong without +search: why?
```

### 2.3 What ndots:5 costs

```bash
$C sh -c 'tcpdump -nni eth0 -l udp port 53 2>/dev/null & sleep 1; curl -s -o /dev/null -m5 http://example.com; sleep 1; kill %1'
```

Count the queries. `example.com` has 1 dot, fewer than 5, so the resolver
tries every search domain first (`example.com.lab-dns.svc.cluster.local`,
`.svc.cluster.local`, `.cluster.local`, plus any node search domain), each
for A and AAAA, each an NXDOMAIN round trip, before the real name. Then:

```bash
$C sh -c 'tcpdump -nni eth0 -l udp port 53 2>/dev/null & sleep 1; curl -s -o /dev/null -m5 http://example.com.; sleep 1; kill %1'   # trailing dot
kubectl -n lab-dns exec client-ndots1 -- sh -c 'tcpdump -nni eth0 -l udp port 53 2>/dev/null & sleep 1; curl -s -o /dev/null -m5 http://example.com; sleep 1; kill %1'
```

Three fixes, in order of preference: FQDNs with a trailing dot in config
for external names; `dnsConfig.options ndots: 2` for pods that mostly call
outside; NodeLocal DNSCache to absorb the NXDOMAIN storm on the node.

Note: netshoot is Alpine (musl). glibc sends A and AAAA in parallel **from
the same socket**, which is what triggers the conntrack insert race below.

### 2.4 CoreDNS as a service you operate

```bash
kubectl -n kube-system port-forward svc/kube-dns 9153:9153 >/dev/null & sleep 2
curl -s localhost:9153/metrics | grep -E '^coredns_(dns_requests_total|dns_responses_total|cache_hits_total|proxy_healthcheck_failures_total|forward_healthcheck_broken_total)' | head -20
kill %1
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=20
```

Watch `coredns_dns_responses_total{rcode="NXDOMAIN"}` against `NOERROR` —
the ndots storm is visible as a huge NXDOMAIN share. `SERVFAIL` rising is an
upstream problem. `coredns_proxy_healthcheck_failures_total{to="<upstream>"}`
counts failed upstream health checks; `coredns_forward_healthcheck_broken_total`
only moves when **every** upstream is down. (Since CoreDNS 1.11 the forward
plugin's per-upstream metrics are `coredns_proxy_*`; older dashboards still
query `coredns_forward_requests_total`, which no longer exists.)

### 2.5 The 5-second delay (explain, don't reproduce)

glibc's parallel A+AAAA from one UDP socket = two packets with the same
5-tuple, racing through conntrack's DNAT to the DNS ClusterIP. If both
create an entry, one insert fails, that packet is dropped, and the client
waits its 5 s timeout. Evidence on a node:

```bash
kubectl debug node/worker-1 -it --profile=sysadmin --image=nicolaka/netshoot:v0.13
# inside the debug shell (node netns):
conntrack -S | grep -o 'insert_failed=[0-9]*'
conntrack -L -p udp --dport 53 | head
```

Fixes: `options single-request-reopen` (glibc), NodeLocal DNSCache (pods
talk to a link-local address, no DNAT), or TCP for DNS. Lab 3.06 has more
conntrack. Delete the debug pod afterwards.

### 2.6 dnsPolicy

```bash
kubectl -n lab-dns run dflt --image=nicolaka/netshoot:v0.13 --restart=Never \
  --overrides='{"spec":{"dnsPolicy":"Default"}}' -- sleep 3600
kubectl -n lab-dns exec dflt -- cat /etc/resolv.conf            # the node's resolvers
kubectl -n lab-dns exec dflt -- dig +search +short web          # fails: cluster names unknown
```

`ClusterFirst` (default), `Default` (node's file — CoreDNS itself uses
this), `ClusterFirstWithHostNet` (hostNetwork pods that need cluster names),
`None` (only `dnsConfig`).

## 3. Verification

| Check | Expected |
|---|---|
| §2.1 | `nameserver 10.96.0.10`, `search lab-dns.svc.cluster.local svc.cluster.local cluster.local …`, `options ndots:5` |
| §2.2 | headless returns 2 pod IPs; SRV `0 100 80 web.lab-dns.svc.cluster.local.` (one target: the ClusterIP); `kubernetes.default` without `+search` → nothing |
| §2.3 | ~8–10 queries without the dot; 2 with it; 2 with ndots:1 |
| §2.4 | NXDOMAIN counter grows after §2.3 |
| §2.6 | `dflt` can resolve example.com but not `web` |

## 4. Break/fix

> **RISKY.** `break.sh` edits the `coredns` ConfigMap in kube-system and
> restarts CoreDNS. **Blast radius:** every pod in the cluster loses
> resolution of external names (cluster names keep working).
> **Rollback:** the original Corefile is saved to `.Corefile.orig` in this
> folder;
> `kubectl -n kube-system create cm coredns --from-file=Corefile=.Corefile.orig --dry-run=client -o yaml | kubectl apply -f - && kubectl -n kube-system rollout restart deploy/coredns`
> (then give it ~8 s: the old pods keep answering during their 5 s lameduck).

```bash
bash break.sh
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

**Done when** `$C dig +short example.com` answers in under a second, from
the pod, and the Corefile matches the original.

<details><summary>Hint (only after 20 minutes)</summary>

Split the path: does the pod reach CoreDNS? Does CoreDNS reach its upstream?
CoreDNS logs its errors.
</details>

Solution: [`solution.md`](solution.md).

## 5. Cleanup

```bash
kubectl delete ns lab-dns
kubectl get pods | grep node-debugger | awk '{print $1}' | xargs -r kubectl delete pod
```

## 6. What I should be able to explain after this

- The full resolution path: pod resolv.conf → kube-dns ClusterIP (DNAT) → CoreDNS `kubernetes` plugin for cluster names, `forward` to the node's upstream (kubelet `resolvConf`) for the rest; `loop` exists because `127.0.0.53` would point CoreDNS at itself.
- `ndots:5` + search list turns one external lookup into ~10 queries; trailing dots, lower ndots or NodeLocal DNSCache fix it, and CoreDNS's NXDOMAIN share shows it.
- How to split a DNS failure: pod → CoreDNS (`dig @<coredns-pod-ip>`), CoreDNS → upstream (CoreDNS logs and `forward` metrics), policy on port 53 UDP **and** TCP.
