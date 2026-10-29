# Lab 4.08 — Capstone: FRR ↔ cluster, Service IPs over BGP

| | |
|---|---|
| **Objective** | From a fresh cluster, build the production pattern for bare-metal Service exposure — cluster peered with the fabric through route reflectors, only Service IPs advertised, ECMP with source-IP preservation, fast withdrawal — and then debug a change-window failure with two layered causes. |
| **Time** | 6 h (week 23) |
| **Where** | a fresh kind `lab-calico` + `lib/frr-kind.sh` on the WSL host |
| **Risk** | Safe — disposable |

Build it yourself from the spec. `reference/` holds one working answer;
open it after `verify.sh` passes, or after two hours stuck on one item.

## 1. Prerequisites

- Labs 4.01–4.03. 3.02 for `externalTrafficPolicy`.

```bash
unset KUBECONFIG; export DATASTORE_TYPE=kubernetes
cd <workbook>/phase4-bgp-cloud-lb/08-capstone-bgp-service-ips
kind delete cluster --name lab-calico 2>/dev/null
kind create cluster --config ../../setup/kind/calico.yaml
kubectl config use-context kind-lab-calico          # calicoctl follows the current context
```

## 2. The spec

Names matter — `verify.sh` and the break/fix use them.

| # | Requirement | Hints |
|---|---|---|
| 1 | Calico, no encapsulation (`../03-calico-bgp/install-calico.sh`) | |
| 2 | Cluster AS **64512**, node-to-node mesh **off**, `lab-calico-worker` a route reflector | 4.03 §2.4 — order matters: RR first, mesh off last |
| 3 | `lab-frr` (AS **65000**) via `../lib/frr-kind.sh up lab-calico <your frr.conf.tpl>`, every node peering with it; Calico peer object named **`lab-frr`** | dynamic neighbors from the kind subnet |
| 4 | FRR accepts **only** `10.202.0.0/24` (and its /32s) from the cluster, through a prefix-list named **`CLUSTER-IN`**; ECMP on | no pod CIDR may appear in FRR's table |
| 5 | Hold time ≤ 9 s on the sessions | FRR `timers`; the lower value wins in negotiation |
| 6 | Namespace `lab-cap4`, Deployment `web` (3× whoami), Service `web` with `externalIPs: [10.202.0.20]` and `externalTrafficPolicy: Local` | Calico `serviceExternalIPs` |
| 7 | From `lab-client`, `curl http://10.202.0.20/` works and shows `RemoteAddr: 172.30.99.10` | the client's real address, end to end |
| 8 | FRR's next hops for `10.202.0.20` are exactly the nodes running a `web` pod, and every path comes **from** the node it points to — a node that dies leaves the ECMP set within the hold time | 4.03 §2.3 asked who re-exports what; here `keepOriginalNextHop` is not enough (measure it). Calico `BGPFilter` |

```bash
bash verify.sh               # 11 checks
```

Then measure, and write the numbers in the tracker:

- Scale `web` so all replicas sit on one node: how fast does FRR drop the
  other next hops? (A withdrawal: seconds.)
- `docker pause` a node with a replica on it: how long until FRR drops
  that next hop? (A dead peer: the hold time.) What do clients see in between?
  `docker unpause` within 5 minutes — after that the pods are evicted and
  you'll be measuring something else.
- Do the pause again with `keepOriginalNextHop: true` on `lab-frr` instead
  of your answer to row 8. How long now, and whose timer is it?

## 3. Verification

`verify.sh` prints `11 passed, 0 failed`. Run it once more after a
`kubectl -n lab-cap4 rollout restart deploy/web` — the ECMP check must
still pass when pods land on different nodes.

## 4. Break/fix — the change window

```bash
bash break.sh          # "AS renumbering and filter clean-up" on the fabric side
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

There may be more than one cause. Fill the beats per cause.

**Done when** `verify.sh` passes again. You may change the cluster side,
the FRR side, or both — but say which side was "right" according to the
change request in the ticket.

<details><summary>Hint (only after 30 minutes)</summary>

First get the sessions to Established — the error is in a NOTIFICATION, and
FRR logs it. Then count the prefixes FRR *receives* versus what it *accepts*
(seeing what it received needs `soft-reconfiguration inbound`). "curl works
again" is not the done-criterion.
</details>

Solution: [`solution.md`](solution.md).

## 5. Cleanup

```bash
bash ../lib/frr-kind.sh down lab-calico
kind delete cluster --name lab-calico
```

## 6. What I should be able to explain after this

- The bare-metal Service exposure pattern end to end: IPs advertised as /32s from nodes with endpoints (`Local`), ECMP at the fabric, kube-proxy only on the node that received the flow, client IP intact.
- Where BGP sessions fail (OPEN errors: AS mismatch, MD5, TCP) vs where routes fail (filters: `received-routes` vs accepted), and how to tell them apart in two commands.
- Withdrawal vs failure: a withdrawn route disappears in seconds; a dead peer's routes live until the hold timer (or BFD) says otherwise.
- Why a route reflector inside the cluster makes *which* hold timer matters: copies of a dead node's route reflected through other nodes live until the **iBGP** session times out, however short the fabric's timers are — so each node should advertise only what it originates.
