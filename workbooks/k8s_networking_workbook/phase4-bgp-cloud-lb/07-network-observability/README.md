# Lab 4.07 — Network observability

| | |
|---|---|
| **Objective** | Turn the failure modes of Phases 2–3 into metrics and alerts — conntrack, retransmits, listen overflows, NIC and softnet drops, DNS error rate and latency — and prove each alert fires by causing the failure. |
| **Time** | 4 h (week 23) |
| **Where** | k8slab, **2 workers, option 3** (kube-prometheus-stack + Loki + Alloy) · WSL host |
| **Risk** | Hands-on adds a PrometheusRule in `lab-netobs`. §2.4 reuses two RISKY injectors from Phase 3 (node conntrack, CoreDNS config) — their own boxes apply. |

This lab connects to `../../../observability_workbook/` (PrometheusRule as code,
session 4). That workbook owns alerting practice; this one owns *which
network signals matter*.

## 1. Prerequisites

- Labs 2.06, 3.04, 3.06. Pipeline option 3 on 2 workers.

```bash
export KUBECONFIG=~/k8slab/kubernetes/admin.conf
bash ../../../../scripts/tunnels/prometheus-tunnel.sh &      # http://localhost:9090  (see the repo README for the tunnels)
P() { curl -s localhost:9090/api/v1/query --data-urlencode "query=$1" | jq -r '.data.result[] | "\(.metric | to_entries | map("\(.key)=\(.value)") | join(",")) \(.value[1])"'; }   # every label, then the value
```

## 2. Hands-on

### 2.1 What's already scraped

```bash
curl -s localhost:9090/api/v1/targets | jq -r '.data.activeTargets[] | "\(.labels.job) \(.health)"' | sort | uniq -c
kubectl -n monitoring get servicemonitors
```

node-exporter and CoreDNS are there. **kube-proxy is not** (`kubeProxy.enabled: false`
in the repo's values, ADR-031: it binds metrics to 127.0.0.1), and Calico's
Felix metrics are off by default. Write down the gap: you can't alert on
"kube-proxy stopped syncing" (lab 3.02) with this stack as it stands.
Closing it means `metricsBindAddress: 0.0.0.0:10249` in the kube-proxy
ConfigMap and `prometheusMetricsEnabled` in Felix — both cluster-wide
changes; propose them as ADR text, don't apply them here.

### 2.2 The queries — write each before you run it

| Question | PromQL |
|---|---|
| How full is conntrack, per node? | `node_nf_conntrack_entries / node_nf_conntrack_entries_limit` |
| Is TCP losing packets? | `rate(node_netstat_Tcp_RetransSegs[5m]) / rate(node_netstat_Tcp_OutSegs[5m])` |
| Are apps not accepting fast enough? | `rate(node_netstat_TcpExt_ListenOverflows[5m])` and `…ListenDrops…` |
| Is a NIC dropping? | `rate(node_network_receive_drop_total{device!~"lo\|cali.*\|tunl0\|vxlan.*"}[5m])` |
| Is the kernel dropping before the stack? | `rate(node_softnet_dropped_total[5m])`, `rate(node_softnet_times_squeezed_total[5m])` |
| DNS error ratio | `sum by (rcode) (rate(coredns_dns_responses_total[5m]))` |
| DNS latency p99 | `histogram_quantile(0.99, sum by (le) (rate(coredns_dns_request_duration_seconds_bucket[5m])))` |
| Is the upstream healthy? | `rate(coredns_forward_healthcheck_broken_total[5m])`, `sum by (to) (rate(coredns_proxy_request_duration_seconds_count[5m]))` (CoreDNS 1.13 renamed `coredns_forward_requests_total` to `coredns_proxy_*`, lab 3.04) |
| The ndots storm | `sum(rate(coredns_dns_responses_total{rcode="NXDOMAIN"}[5m])) / sum(rate(coredns_dns_responses_total[5m]))` |

```bash
P 'node_nf_conntrack_entries / node_nf_conntrack_entries_limit'
P 'sum by (rcode) (rate(coredns_dns_responses_total[5m]))'
```

Generate an NXDOMAIN storm and watch its share rise (lab 3.04's ndots):

```bash
kubectl create ns lab-netobs-load 2>/dev/null
kubectl -n lab-netobs-load run storm --image=nicolaka/netshoot:v0.13 -- sh -c 'while true; do curl -s -o /dev/null -m2 http://example.com; done'
sleep 120; P 'sum(rate(coredns_dns_responses_total{rcode="NXDOMAIN"}[2m])) / sum(rate(coredns_dns_responses_total[2m]))'
kubectl delete ns lab-netobs-load
```

### 2.3 Alerts as code

```bash
kubectl apply -f rules.yaml
until curl -s localhost:9090/api/v1/rules | jq -e '.data.groups[] | select(.name=="lab-network")' >/dev/null; do sleep 10; done   # ~90 s
curl -s localhost:9090/api/v1/rules | jq -r '.data.groups[] | select(.name=="lab-network") | .rules[] | "\(.name) \(.health) \(.state)"'
```

Loading takes about 90 s: the operator renders the rule into the
`prometheus-…-rulefiles-0` ConfigMap, the kubelet syncs it into the pod
(up to a minute), and the config reloader tells Prometheus. Three rules,
`health: ok`, `state: inactive`. Each threshold is a judgement
call — write in the tracker why you'd pick a different one in production
(e.g. conntrack at 80 % gives minutes of warning on a busy node, not hours).

### 2.4 Prove they fire

Conntrack (RISKY, auto-rollback after 180 s — read the box in lab 3.06).
Two runs: one that fills worker-2's table to ~85-95 %, and one that fills it
completely.

```bash
kubectl apply -f ../../phase3-k8s-networking/06-mtu-conntrack/apps.yaml && kubectl -n lab-mtu wait --for=condition=Ready pod/sink
W2=$(kubectl get node worker-2 -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'):9100
mon() { for i in $(seq 16); do sleep 10
  R=$(curl -s localhost:9090/api/v1/query --data-urlencode "query=node_nf_conntrack_entries{instance=\"$W2\"} / node_nf_conntrack_entries_limit" | jq -r '.data.result[0].value[1] // "-" | .[0:5]')
  U=$(curl -s localhost:9090/api/v1/query --data-urlencode "query=up{job=\"node-exporter\",instance=\"$W2\"}" | jq -r '.data.result[0].value[1]')
  A=$(curl -s localhost:9090/api/v1/alerts | jq -r '[.data.alerts[] | select(.labels.alertname=="NodeConntrackHigh") | .state] | join(",")')
  echo "$((i*10))s ratio=$R up=$U alert=${A:-none}"; done; }

CT_HOLD=4000 CT_HEADROOM=4500 bash ../../phase3-k8s-networking/06-mtu-conntrack/ct-exhaust.sh start; mon   # limit = count + 4500, 4000 held
bash ../../phase3-k8s-networking/06-mtu-conntrack/ct-exhaust.sh stop
```

4000 held connections against a limit of count + 4500 keep the ratio near
0.9 even though the node's own baseline drifts by a few hundred entries;
with only the default 800 held there's no room between "above 80 %" and
"full". If `kubectl apply` refuses to update `pod/sink` (an older sink from
lab 3.06), delete the pod and apply again.

Now fill it completely (the default headroom of 400 is less than the 800
held connections):

```bash
bash ../../phase3-k8s-networking/06-mtu-conntrack/ct-exhaust.sh start; mon
bash ../../phase3-k8s-networking/06-mtu-conntrack/ct-exhaust.sh stop
kubectl -n monitoring get pods -o wide | grep 'node-exporter.*worker-2'      # RESTARTS went up, maybe CrashLoopBackOff
```

Expect worker-2's node-exporter (and sometimes calico-node) to show several
restarts, possibly `CrashLoopBackOff` for a minute after `stop`; it comes
back on its own.

Measured: the ratio touches `1`, then `up` drops to `0` and the alert stays
`none` or flickers `pending` without ever firing. A full table refuses
**new** connections, and Prometheus's scrape of worker-2's node-exporter is
a new connection; so is the kubelet's liveness probe, which restarted
node-exporter 5 times in one run. Each failed scrape ends the series and
resets `for:`. The node can't report the very condition that's hurting it.
That's why the threshold is 80 %: it fires while the table *fills*. Pair it
with alerting on the scrape itself (`up{job="node-exporter"} == 0`,
kube-prometheus-stack's `TargetDown`). node-exporter here doesn't expose
the kernel's conntrack drop counters, which would survive the gap.

DNS SERVFAIL (RISKY: CoreDNS config, see lab 3.04's box). The break points
CoreDNS's forwarder at an unreachable address, so every external name
fails:

```bash
bash ../../phase3-k8s-networking/04-coredns/break.sh
kubectl -n lab-dns exec client -- sh -c 'for w in 1 2 3 4; do (end=$(($(date +%s)+200)); while [ $(date +%s) -lt $end ]; do dig +tries=1 +time=2 +short example.com >/dev/null; done) & done; wait' &
for i in $(seq 20); do sleep 10; echo "$((i*10))s $(curl -s localhost:9090/api/v1/alerts | jq -r '[.data.alerts[] | select(.labels.alertname=="CoreDNSServfailRatioHigh") | .state] | join(",")')"; done
wait
```

Measured: SERVFAIL share climbs to ~0.6, `pending` at ~40 s, `firing` at
~155 s (`for: 2m`). Restore with lab 3.04's fix (run in its folder:
re-create the ConfigMap from `.Corefile.orig`, restart CoreDNS, wait out
the lameduck pods). Look at the same window in Grafana
(`grafana-tunnel.sh` → https://localhost:8445, "CoreDNS" and
"Node Exporter / Nodes" dashboards).

## 3. Verification

| Check | Expected |
|---|---|
| §2.1 | node-exporter and coredns targets `up`; no kube-proxy target |
| §2.2 | NXDOMAIN share clearly > 50 % during the storm |
| §2.3 | the three rules loaded, `health: ok` |
| §2.4 | `CT_HOLD=4000 CT_HEADROOM=4500`: NodeConntrackHigh firing for worker-2 in ~2 min; full table: `up=0`, node-exporter restarts, no firing; CoreDNSServfailRatioHigh firing in ~2.5 min during the DNS break |

## 4. Break/fix

```bash
bash break.sh          # recreates lab-netobs's rules "from the team's repo"
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

**Done when** `NodeConntrackHigh` appears in Prometheus's rule list and you've
made it fire with `CT_HOLD=4000 CT_HEADROOM=4500 bash ct-exhaust.sh start` (§2.4 — a
completely full table can't fire it, labelled or not).

<details><summary>Hint (only after 20 minutes)</summary>

The object exists in the cluster. Does Prometheus know about it? Which
rules does this Prometheus pick up?
</details>

Solution: [`solution.md`](solution.md).

## 5. Cleanup

```bash
kubectl delete ns lab-netobs lab-mtu lab-dns --ignore-not-found    # lab-dns comes from 3.04's break.sh
kill %1 2>/dev/null          # the tunnel
```

## 6. What I should be able to explain after this

- The node-level signals that predict network incidents — conntrack fill ratio, retransmit ratio, listen overflows, NIC/softnet drops — and the DNS signals — rcode mix, latency, upstream health — with the PromQL for each.
- What this stack can't see (kube-proxy sync, CNI agent internals) until scraping is enabled, and why that's a cluster-wide change to propose, not to hack in — and that a node can't report a full conntrack table at all, because the scrape is a new connection: alert at 80 % and on `up == 0`.
- How kube-prometheus-stack selects PrometheusRules (`ruleSelector` labels, `ruleNamespaceSelector`), and that an alert isn't real until you've watched it fire.
