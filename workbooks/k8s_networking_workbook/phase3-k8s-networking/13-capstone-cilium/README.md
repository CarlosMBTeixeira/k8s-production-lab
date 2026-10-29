# Lab 3.13 — Capstone: Cilium end to end

| | |
|---|---|
| **Objective** | Build, from an empty kind cluster, a kube-proxy-free Cilium platform with LB IPAM + L2 announcements, Cilium's Gateway API, a three-tier zero-trust policy set and Hubble — then investigate a two-part incident, one of them a DNS failure. |
| **Time** | 7 h (week 17) |
| **Where** | a **fresh** kind `lab-cilium` |
| **Risk** | Safe — disposable cluster |

This is a build-it-yourself lab: a spec, a verifier and a reference. Write
your own manifests first; `reference/` is for after `verify.sh` passes or
after two hours stuck on one item.

## 1. Prerequisites

- Labs 3.07, 3.08, 3.09. k8slab down.

```bash
unset KUBECONFIG
kind delete cluster --name lab-cilium 2>/dev/null
cd <workbook>/phase3-k8s-networking/13-capstone-cilium
kind create cluster --config ../../setup/kind/cilium.yaml
KIND_NET=$(docker network inspect kind | jq -r '.[0].IPAM.Config[] | select(.Subnet | test("\\.")) | .Subnet')
export LB_START=$(echo $KIND_NET | awk -F. '{print $1"."$2".255.200"}') LB_STOP=$(echo $KIND_NET | awk -F. '{print $1"."$2".255.220"}')
echo "$KIND_NET  pool $LB_START-$LB_STOP"
```

## 2. The spec

Build each item; check it before the next. Names matter — the verifier and
the break/fix use them.

| # | Requirement | Hints |
|---|---|---|
| 1 | **Gateway API CRDs** installed at the version your Cilium release requires | Cilium docs → "Gateway API Support" → Installation lists the exact CRDs and version (Cilium 1.20: Gateway API v1.6.1, standard channel, which now includes TLSRoute); apply with `--server-side` |
| 2 | **Cilium** with kube-proxy replacement, `ipam.mode=kubernetes`, Gateway API, L2 announcements, Hubble relay + UI | flags: `kubeProxyReplacement`, `k8sServiceHost/Port`, `gatewayAPI.enabled`, `l2announcements.enabled`, `devices='{eth0}'`, `k8sClientRateLimit.qps/burst` (the L2 docs say why), `hubble.relay.enabled`, `hubble.ui.enabled` |
| 3 | **LB IPAM pool** `lab-pool` = `$LB_START`–`$LB_STOP`, announced on `eth0` | `CiliumLoadBalancerIPPool`, `CiliumL2AnnouncementPolicy` |
| 4 | Namespace **`lab-cap`** with `frontend` (2×, port 80), `api` (2×, port 80), `db` (1×, port 5432) — whoami, pods labelled `tier: frontend\|api\|db`, Services named like the Deployments | `whoami --name <x>` makes `Hostname`/`Name` readable; `--port 5432` for db |
| 5 | **Gateway `lab-cap/app`** (class `cilium`) + **HTTPRoute `lab-cap/app`**: `app.lab.local` → `frontend:80`. Nothing else exposed | the Gateway gets its address from your pool; `curl -H 'Host: app.lab.local' http://<addr>/` from the WSL host |
| 6 | **Policies**: default deny in and out for `lab-cap`; DNS for all, via the DNS proxy; frontend ← Gateway only; frontend → api :80 **GET only**; api → db :5432; api → `example.com` only; nothing else | Gateway traffic arrives with Cilium's reserved `ingress` identity (`fromEntities`) |
| 7 | **Hubble**: `cilium hubble port-forward &` running; every deny in the verifier visible with `hubble observe -n lab-cap --verdict DROPPED` | |

Then:

```bash
kubectl apply -f probes.yaml        # probe pods with tier labels, plus lab-cap-other
bash verify.sh                      # 14 checks
```

Record your time per item in the tracker. Then do items 2–6 again on a
fresh cluster without notes, timed.

## 3. Verification

`verify.sh` prints `14 passed, 0 failed` and at least one DROPPED flow from
Hubble. Also look at the Hubble UI service map for `lab-cap` (`cilium hubble ui`):
it should show exactly Gateway → frontend → api → db, plus api → world and
everyone → kube-dns.

## 4. Break/fix — the incident

```bash
bash break.sh          # two changes, one ticket
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

Two symptoms, possibly two causes. Fill the four beats **per symptom**.

**Done when** `verify.sh` passes again, and you can say for each symptom
which Hubble query (or status field) showed the cause.

<details><summary>Hint (only after 30 minutes)</summary>

For the DNS symptom: it's intermittent, and there are two CoreDNS pods.
Follow the DNS flows in Hubble per destination pod, with their verdicts.
For the web symptom: the Gateway is a Kubernetes object with status.
</details>

Solution: [`solution.md`](solution.md).

## 5. Cleanup

```bash
kill %1 2>/dev/null                 # hubble port-forward
kind delete cluster --name lab-cilium
```

## 6. What I should be able to explain after this

- How the pieces of a kube-proxy-free Cilium platform fit: socket/tc LB for Services, LB IPAM + L2 announcements (leader-elected ARP replies) for external IPs, Cilium's Envoy for Gateway API, identities for policy, Hubble for flows.
- Why Gateway traffic needs a `fromEntities: [ingress]` allow, and why a three-tier zero-trust set is: default deny + DNS-via-proxy + one allow per edge.
- How to split an incident with two symptoms — one status-visible (route `ResolvedRefs`), one only flow-visible (DNS drops to one backend) — and why intermittent DNS failures point at one bad backend among several.
- Why a label change on a pod takes effect on policy only after Cilium re-allocates its identity, seconds later.
