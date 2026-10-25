# Lab 3.05 — NetworkPolicy on Calico

| | |
|---|---|
| **Objective** | Build a default-deny policy set for a two-tier app one policy at a time, predicting the reachability matrix before every step, and see where Calico enforces it and what its own policy model adds. |
| **Time** | 5 h (week 12) |
| **Where** | k8slab, 2 workers, option 0 · WSL host |
| **Risk** | Safe — policies live in `lab-np-*` namespaces; the Calico GlobalNetworkPolicy selects only `lab-np-front` |

Overlap note: this also reinforces the CKS NetworkPolicy domain. It
doesn't teach it as such; the point here is debugging.

## 1. Prerequisites

- Labs 3.01, 3.04. `calicoctl` from the WSL host (`export DATASTORE_TYPE=kubernetes`).

```bash
export KUBECONFIG=~/k8slab/kubernetes/admin.conf
kubectl apply -f apps.yaml
kubectl -n lab-np-back rollout status deploy/api; kubectl -n lab-np-back rollout status deploy/db
kubectl wait --for=condition=Ready pod --all -n lab-np-front; kubectl wait --for=condition=Ready pod --all -n lab-np-other
bash test-matrix.sh            # baseline: everything OK
```

The cluster already has policies of its own in `monitoring` (ADR-034). Don't touch them.

## 2. Hands-on

**For each step: write the matrix you expect, then apply, then run
`bash test-matrix.sh`.** A wrong prediction is the lesson; note it.

| Step | Apply | What it's for |
|---|---|---|
| 1 | `policies/01-back-default-deny.yaml` | any policy selecting a pod for Ingress makes it deny-by-default for ingress |
| 2 | `policies/02-allow-frontend-to-api.yaml` | namespace **AND** pod selector in one peer |
| 3 | `policies/03-allow-api-to-db.yaml` | named port; test it: `kubectl -n lab-np-back run api-probe --labels app=api --image=nicolaka/netshoot:v0.13 -- sleep 3600`, then `kubectl -n lab-np-back exec api-probe -- curl -s -m2 db:5432` |
| 4 | `policies/04-the-or-mistake.yaml` | two peers = **OR**: who got in? Then `kubectl delete -f policies/04-the-or-mistake.yaml` |
| 5 | `policies/05-front-default-deny-egress.yaml` | egress default deny — notice DNS dies too |
| 6 | `policies/06-allow-dns.yaml` | DNS: kube-system namespace AND kube-dns pods, UDP **and** TCP 53 |
| 7 | `policies/07-allow-frontend-egress-to-back.yaml` | both ends must allow: egress here, ingress in 02 |
| 8 | `policies/08-allow-frontend-internet.yaml` | `ipBlock` with `except` for in-cluster ranges |

Expected final matrix (after step 8):

```
                        api (by name)     api (by IP)       db (by name)      1.1.1.1 (egress)
lab-np-front/frontend   OK                OK                --                OK
lab-np-front/stranger   --                --                --                --
lab-np-other/outsider   --                --                --                OK
```

Step 4's answer: `stranger` reaches api (any pod in lab-np-front is
allowed by the first peer). A YAML dash turned an AND into an OR.

### 2.1 Where Calico enforces it

```bash
calicoctl get networkpolicy -A -o wide          # your K8s policies, as knp.default.<name>, order 1000
NODE=$(kubectl -n lab-np-back get pod -l app=api -o jsonpath='{.items[0].spec.nodeName}')
ssh ${NODE/worker-/w-} "sudo iptables-save -t filter | grep -E '^:cali-(pi|po)-' | head"   # one chain per policy
ssh ${NODE/worker-/w-} "sudo iptables-save -t filter | grep -A8 'knp.default.allow-frontend-to-api' | head -20"
```

Policy is enforced on the **node hosting the selected pod**, in the `cali-tw-<veth>`
(to workload) / `cali-fw-<veth>` (from workload) chains that jump to the
per-policy chains. Ingress is checked on the destination's node, egress on
the source's node — a cross-node flow is checked twice, on two nodes.

### 2.2 What Calico adds: GlobalNetworkPolicy, order, Log, Deny

```bash
calicoctl apply -f calico/gnp-block-1111.yaml
bash test-matrix.sh                             # frontend → 1.1.1.1 now --
FN=$(kubectl -n lab-np-front get pod frontend -o jsonpath='{.spec.nodeName}')
ssh ${FN/worker-/w-} "sudo dmesg | grep calico-packet | tail -3"   # the Log action
calicoctl get globalnetworkpolicy -o wide
```

Kubernetes NetworkPolicy has no deny rule, no order and no cluster scope.
Calico's `order` (lower first) lets a platform team put guardrails ahead of
application policies. Read the comment in the GNP file about end-of-tier
denies before widening its selector.

## 3. Verification

| Check | Expected |
|---|---|
| matrix after step 2 | frontend → api OK; stranger, outsider → api `--` |
| step 3 | `api-probe` → db OK; frontend → db `--` |
| after step 5 | frontend: all `--`, including by IP |
| after step 6 | frontend: by name and by IP still `--` (no egress allow yet) — DNS resolves though: `kubectl -n lab-np-front exec frontend -- dig +short api.lab-np-back.svc.cluster.local` |
| final + GNP | as above, with frontend → 1.1.1.1 `--` and a `calico-packet` log line |

## 4. Break/fix

```bash
bash break.sh          # rebuilds the namespaces and a policy set, with one mistake
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

**Done when** the matrix shows frontend → api OK **by name**, and nothing
else changed (stranger and outsider still `--` to api).

<details><summary>Hint (only after 20 minutes)</summary>

By IP works, by name doesn't. Which egress does "by name" need that "by IP"
doesn't — and who does that policy actually select?
</details>

Solution: [`solution.md`](solution.md).

## 5. Cleanup

```bash
calicoctl delete globalnetworkpolicy lab-np-block-1111 2>/dev/null
kubectl delete ns lab-np-front lab-np-back lab-np-other
```

## 6. What I should be able to explain after this

- A pod selected by any policy of a type (Ingress/Egress) is default-deny for that type; allows are unioned; both the source's egress and the destination's ingress must allow a flow.
- `from`/`to` peers: one element with namespaceSelector + podSelector is AND; two elements are OR; a podSelector alone means "in this policy's namespace". Egress policies must allow DNS (UDP and TCP 53 to kube-dns) or names stop working.
- Calico renders policies as per-endpoint chains on the node hosting the pod, adds ordered GlobalNetworkPolicies with Deny and Log, and denies at the end of a tier anything selected but not decided.
