# Lab 3.08 — Cilium policies and Hubble

| | |
|---|---|
| **Objective** | Enforce L3/L4, L7 HTTP and DNS-name egress policies with Cilium, and use Hubble to see every flow, verdict and drop reason — the visibility Calico-on-iptables doesn't give you. |
| **Time** | 5 h (week 15) |
| **Where** | kind `lab-cilium` (from lab 3.07, Cilium with KPR) |
| **Risk** | Safe — disposable cluster; policies in `lab-cil` only |

## 1. Prerequisites

- Lab 3.07 done and `lab-cilium` up with Cilium healthy; lab 3.05 for policy semantics.

```bash
unset KUBECONFIG; kubectl config use-context kind-lab-cilium
cd <workbook>/phase3-k8s-networking/08-cilium-policy-hubble
kubectl apply -f ../07-cilium-kpr/web.yaml && kubectl -n lab-cil rollout status deploy/web
cilium hubble enable --ui && cilium status --wait
cilium hubble port-forward &          # Hubble Relay on localhost:4245
hubble status                         # "Healthcheck (via localhost:4245): Ok"
C='kubectl -n lab-cil exec client --'
```

## 2. Hands-on

### 2.1 Flows before any policy

```bash
hubble observe -n lab-cil -f &        # leave it running in a second shell
$C curl -s -o /dev/null web/api/x; $C curl -s -o /dev/null http://example.com
```

Each line: source pod → destination (pod, `world`, `kube-dns`…), L4, and a
verdict (`FORWARDED`). With no L7 policy you see L3/L4 only.

### 2.2 Default deny, then DNS through the proxy

```bash
kubectl apply -f policies/01-default-deny.yaml
$C curl -s -m3 web                            # fails — and DNS fails first
hubble observe -n lab-cil --verdict DROPPED --last 10
#   … Policy denied DROPPED (UDP) … → kube-system/coredns-…:53
kubectl apply -f policies/02-allow-dns-visible.yaml
$C dig +short web.lab-cil.svc.cluster.local   # works
hubble observe -n lab-cil --protocol dns --last 10   # the queries and answers, by name
```

Note what the DROPPED line gave you: source, destination identity, port,
direction and "Policy denied". That's the answer to lab 3.05's break/fix in
one line.

### 2.3 L7: the API, but only GET /api/...

```bash
kubectl apply -f policies/03-client-to-web-l7.yaml
$C curl -s -o /dev/null -w '%{http_code}\n' web/api/users      # 200
$C curl -s -o /dev/null -w '%{http_code}\n' web/admin          # 403 — from Cilium's Envoy, not from the app
$C curl -s -o /dev/null -w '%{http_code}\n' -X POST web/api/x  # 403
hubble observe -n lab-cil --protocol http --last 10            # method, path, status, latency
hubble observe -n lab-cil --http-status 403 --last 5
```

Packets to :80 on web are now redirected to a per-node Envoy (inside the
agent or the `cilium-envoy` DaemonSet), which parses HTTP and applies the
rule. That costs latency and is why L7 policies are scoped tight.

### 2.4 DNS-name egress

```bash
$C curl -s -m5 -o /dev/null -w '%{http_code}\n' http://example.com      # 000: default deny
kubectl apply -f policies/04-client-fqdn.yaml
$C curl -s -m5 -o /dev/null -w '%{http_code}\n' http://example.com      # 200
$C curl -s -m5 -o /dev/null -w '%{http_code}\n' http://example.org      # 000
CIL=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=$(kubectl -n lab-cil get pod client -o jsonpath='{.spec.nodeName}') -o name)
kubectl -n kube-system exec $CIL -c cilium-agent -- cilium-dbg fqdn cache list | grep example
```

`toFQDNs` works by watching the answers the DNS proxy hands out and
allowing exactly those IPs, for their TTL. No proxy (no `rules.dns`) → no
answers seen → nothing allowed.

### 2.5 Identities: what policy really matches

```bash
kubectl -n kube-system exec $CIL -c cilium-agent -- cilium-dbg endpoint list | grep -E 'ENDPOINT|lab-cil'
kubectl -n kube-system exec $CIL -c cilium-agent -- cilium-dbg identity list | grep -A3 lab-cil
kubectl get ciliumidentities | head
kubectl -n kube-system exec $CIL -c cilium-agent -- cilium-dbg policy get | head -40
```

Cilium allocates a numeric identity per unique label set; policy is
compiled to "identity X may talk to identity Y on port P". Pod IPs are not
in the policy at all, which is why scaling and rescheduling don't churn rules.

### 2.6 The UI (optional, 10 min)

```bash
cilium hubble ui        # opens/port-forwards the UI on localhost:12000
```

Service map of `lab-cil`, red edges for drops. Good for explaining an
incident to someone else; the CLI is faster for finding it.

## 3. Verification

| Check | Expected |
|---|---|
| §2.2 | DROPPED to kube-dns before 02; `hubble observe --protocol dns` shows queries after |
| §2.3 | 200 for GET /api/…, 403 for /admin and POST; Hubble shows `http-request`/`http-response` with paths |
| §2.4 | example.com 200, example.org 000; `fqdn cache list` has example.com → IPs |
| §2.5 | `client` and each `web` pod with identities; `policy get` lists your rules |

## 4. Break/fix

```bash
bash break.sh          # recreates lab-cil with a policy set that has one subtle hole
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

**Done when** `$C curl -s -m5 -o /dev/null -w '%{http_code}\n' http://example.com`
prints `200`, `http://example.org` still fails, and `client` → `web/api/x` still works.

<details><summary>Hint (only after 20 minutes)</summary>

DNS resolves, the policy names the right host, and the connection is still
dropped. What does a `toFQDNs` rule need in order to learn IPs?
</details>

Solution: [`solution.md`](solution.md).

## 5. Cleanup

```bash
kill %1 2>/dev/null                       # the hubble port-forward
kubectl delete ns lab-cil
# keep lab-cilium for 3.13, or: kind delete cluster --name lab-cilium
```

## 6. What I should be able to explain after this

- Cilium compiles policy to security identities (from labels), not IPs, and enforces it in BPF per endpoint; L7 rules redirect matching traffic through Envoy, and `toFQDNs` learns allowed IPs from its own DNS proxy (`rules.dns`).
- Hubble shows every flow with its verdict and drop reason (`--verdict DROPPED`, `--type policy-verdict`, `--protocol dns|http`), turning policy debugging into one query.
- K8s NetworkPolicy and CiliumNetworkPolicy combine (union of allows); a default-deny K8s policy plus targeted CNPs is a normal production layout.
