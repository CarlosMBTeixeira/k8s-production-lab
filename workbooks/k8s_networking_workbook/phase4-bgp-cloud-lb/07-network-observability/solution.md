# Lab 4.07 — solution

## What was injected

<!--FAULT-->
```bash
export KUBECONFIG="$WB_DIR/../../kubernetes/admin.conf"
kubectl get crd prometheusrules.monitoring.coreos.com >/dev/null || { echo "kube-prometheus-stack not installed (pipeline option 3)"; exit 1; }
kubectl delete ns lab-netobs --ignore-not-found --wait=true >/dev/null
# --- the fault: the rule "from the team's repo", without the selector label ---
sed '/labels: {release: kube-prometheus-stack}/d' "$LAB_DIR/rules.yaml" | kubectl apply -f - >/dev/null
cat <<'T'

TICKET  Post-incident review: worker-2's conntrack table was full for 3
        minutes this morning (simulate a near-full table: lab 3.06's
        CT_HOLD=4000 CT_HEADROOM=4500 bash ct-exhaust.sh start).
        We have an alert for exactly that — NodeConntrackHigh in
        lab-netobs/lab-network — and it never fired. Nobody got paged.
        "kubectl get prometheusrule -n lab-netobs" shows it's there.
T
```
<!--/FAULT-->

The PrometheusRule is valid and present, but lacks the
`release: kube-prometheus-stack` label. This Prometheus only loads rules
whose labels match its `ruleSelector`, so the rule was never evaluated —
no error, no warning, just an alert that can't fire.

The ticket's real morning had a twist: a table that's *completely* full
blocks Prometheus's scrapes of that node too (lab §2.4), so even the fixed
rule wouldn't have fired at 100 %. It fires on the way up, at 80 %. Pair it
with `up{job="node-exporter"} == 0`.

## Diagnosis path

| Beat | Answer |
|---|---|
| Hypothesis | The condition happened (conntrack did fill) and the alert never fired → either the expression doesn't match, or the rule isn't loaded. |
| Tool | `curl -s localhost:9090/api/v1/rules \| jq -r '.data.groups[].name'` |
| Expected if right | no `lab-network` group. |
| Tool 2 | `kubectl -n monitoring get prometheus -o jsonpath='{.items[0].spec.ruleSelector}{"\n"}{.items[0].spec.ruleNamespaceSelector}'` and `kubectl -n lab-netobs get prometheusrule lab-network --show-labels` |
| Expected if right | selector `{"matchLabels":{"release":"kube-prometheus-stack"}}`; the rule has no such label. |
| Tool 3 (expression check, for completeness) | `P 'node_nf_conntrack_entries / node_nf_conntrack_entries_limit'` |
| Expected if right | returns one series per node: the expression itself is fine. |
| What would have told me sooner | A CI step that runs `promtool test rules` **and** asserts every PrometheusRule carries the selector label; or a meta-alert comparing rule-group count in Git with `prometheus_rule_group_rules` in Prometheus. |

## Fix

```bash
kubectl -n lab-netobs label prometheusrule lab-network release=kube-prometheus-stack
sleep 60; curl -s localhost:9090/api/v1/rules | jq -r '.data.groups[] | select(.name=="lab-network") | .rules[].name'
CT_HOLD=4000 CT_HEADROOM=4500 bash ../../phase3-k8s-networking/06-mtu-conntrack/ct-exhaust.sh start   # firing in ~2 min, then stop
```

## Why it matters later

On OpenShift's user-workload monitoring the rules must sit in a namespace
monitored by the user-workload Prometheus, and alerting rules for
platform namespaces go elsewhere — a different selector, the same failure
(observability workbook, session 6).
