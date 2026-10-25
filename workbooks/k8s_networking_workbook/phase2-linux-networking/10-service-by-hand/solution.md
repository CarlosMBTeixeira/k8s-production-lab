# Lab 2.10 — solution

## What was injected

<!--FAULT-->
```bash
bash "$LAB_DIR/topo.sh" up
iptables -t nat -N LAB-SERVICES
iptables -t nat -A PREROUTING -j LAB-SERVICES
iptables -t nat -A OUTPUT     -j LAB-SERVICES
iptables -t nat -N LAB-SVC-WEB
iptables -t nat -A LAB-SERVICES -d 10.96.100.10/32 -p tcp --dport 80 -j LAB-SVC-WEB
for i in 1 3; do
  iptables -t nat -N LAB-SEP-$i
  iptables -t nat -A LAB-SEP-$i -p tcp -j DNAT --to-destination 10.50.0.1$i:8080
done
# --- the fault ---
iptables -t nat -N LAB-SEP-2
iptables -t nat -A LAB-SEP-2 -p tcp -j DNAT --to-destination 10.50.0.14:8080
iptables -t nat -A LAB-SVC-WEB -m statistic --mode random --probability 0.33333 -j LAB-SEP-1
iptables -t nat -A LAB-SVC-WEB -m statistic --mode random --probability 0.50000 -j LAB-SEP-2
iptables -t nat -A LAB-SVC-WEB -j LAB-SEP-3
cat <<'T'

TICKET  The "web" Service (10.96.100.10:80) on this node is flaky: roughly a
        third of requests hang, the rest answer "b1" or "b3". All three
        backend pods are up:  for i in 1 2 3; do curl -s 10.50.0.1$i:8080; done
        Reproduce:  for i in $(seq 30); do curl -s -m2 10.96.100.10 || echo FAIL; done | sort | uniq -c
T
```
<!--/FAULT-->

Endpoint chain `LAB-SEP-2` DNATs to `10.50.0.14`, an address no pod has —
a stale endpoint, as if kube-proxy had stopped syncing after b2 was
rescheduled. One request in three goes there, ARP for it fails, and the
connection hangs.

## Diagnosis path

| Beat | Answer |
|---|---|
| Hypothesis | 1-in-N failures with N backends = one bad endpoint. |
| Tool | `iptables -t nat -L LAB-SVC-WEB -v -n` and `iptables -t nat -S \| grep -- '-j DNAT'` |
| Expected if right | three SEP chains; one DNAT target that isn't a running backend. |
| Tool 2 | `conntrack -L -d 10.96.100.10` during the failures |
| Expected if right | `SYN_SENT … src=10.50.0.14 … [UNREPLIED]` |
| Tool 3 | `ip neigh show dev svc0` |
| Expected if right | `10.50.0.14 FAILED` |
| What would have told me sooner | Compare the datapath's endpoints with the source of truth. In Kubernetes: `kubectl get endpointslices` vs `iptables-save \| grep KUBE-SEP` on the node (or `ipvsadm -Ln`, or `cilium-dbg service list`). A mismatch means the proxy isn't syncing — check its logs and `kubeproxy_sync_proxy_rules_last_timestamp_seconds`. |

## Fix

```bash
iptables -t nat -R LAB-SEP-2 1 -p tcp -j DNAT --to-destination 10.50.0.12:8080
for i in $(seq 30); do curl -s -m2 10.96.100.10 || echo FAIL; done | sort | uniq -c
```

## Why it matters later

Lab 3.02 reads the real chains on k8slab. "A few percent of requests hang"
on one node only is a stale-rules node: kube-proxy is crash-looping or
can't reach the API server.
