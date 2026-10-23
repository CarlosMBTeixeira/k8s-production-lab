# Session 6 — Troubleshooting lab (break and fix)

**Objective:** diagnose ten realistic mesh failures from the symptom
alone, the way they arrive on a platform team: a one-line complaint, no
hint of the cause. Each one becomes a runbook row.

**Prerequisites**
- Sessions 0–3 (you need the tools and the security model). 5 helps for
  scenario 8.
- Lab with choice **5** or **6**, `istioctl` installed, Kiali and Grafana
  tunnels open.
- `export KUBECONFIG=~/k8slab/kubernetes/admin.conf`

**Rules**
1. **Do not read `scripts/mesh-break.sh` or
   [`06-troubleshooting-solutions.md`](06-troubleshooting-solutions.md)**
   until you have written your diagnosis. The script's scenario bodies
   *are* the answers.
2. Write the hypothesis **before** the first command, as always.
3. Time-box each scenario to 20 minutes. If you run out, open only the
   **hint** for that scenario in the solutions file, not the answer.
4. Fix it **yourself** with `kubectl`/`istioctl`, then confirm with
   `mesh-break.sh check`. Use `mesh-break.sh restore <n>` only to reset if
   your fix went sideways — and note that you needed it.

**Read first:** istio.io → *Operations* → *Common Problems* (all four
pages) and *Diagnostic Tools*. That is the official troubleshooting
canon; every scenario here is a member of it.

---

## Using the script

```bash
./scripts/mesh-break.sh list            # all ten symptoms
./scripts/mesh-break.sh check           # 10 page loads: what users see
./scripts/mesh-break.sh break 3         # apply scenario 3, prints its symptom
./scripts/mesh-break.sh restore 3       # undo it
./scripts/mesh-break.sh restore all     # back to baseline (safe to run any time)
```

Baseline before you start — healthy looks like this (v1 has no stars,
v2/v3 have stars):

```
      3 http=200 details=ok reviews=ok ratings=none
      7 http=200 details=ok reviews=ok ratings=stars
```

Every scenario was applied, observed and restored on this lab on
2026-10-23. `restore all` on a healthy mesh takes ~20 s and changes
nothing.

---

## The scenarios

Run them in order the first time; they get less obvious. Four of them
(1, 3, 4, 8) present as "ratings or details unavailable" on purpose:
**the symptom does not identify the cause**, and telling them apart is
the skill.

| # | Reported symptom |
|---|---|
| 1 | About a third of product page loads say "Ratings service is currently unavailable". The rest look normal. |
| 2 | Every product page load says "Error fetching product reviews". Nobody changed the reviews code. |
| 3 | Product pages show reviews but never any stars: "Ratings service is currently unavailable" on every load. |
| 4 | Every product page load says "Error fetching product details". |
| 5 | The page works, but Kiali shows the reviews edges as TCP and the reviews request-rate panels went flat. |
| 6 | The product page is unreachable from outside the mesh. Inside the cluster everything looks fine. |
| 7 | The site works perfectly, but nobody can change routing: `kubectl apply` of any VirtualService fails, and a ratings rollout has been stuck for ages. |
| 8 | Reviews with stars have disappeared: "Ratings service is currently unavailable" on every page that should show them. |
| 9 | Kiali's traffic graph for bookinfo is empty, yet the generator logs show 200s every second. |
| 10 | After a routine rollout, the new details pod never becomes Ready. The old pods were fine. |

---

## Worksheet — copy once per scenario

```
Scenario:
Hypothesis (before any command):
First tool, and why that one:
What it showed:
Second tool (if needed):
Cause (a mechanism, not "misconfiguration"):
Fix applied (exact command):
Confirmed by:
Time taken:
What would have told me this first:
Did `istioctl analyze` catch it? (y/n)
```

That last line is worth tracking deliberately. Expect it to be "no" more
often than you would like — `analyze` checks that references resolve,
not that the mesh *behaves*.

---

## A diagnostic order that works

Not a rule, a default when you have no better idea:

1. **What do users see?** `mesh-break.sh check` — which service, how
   often, all versions or some.
2. **What does the caller's sidecar say?** Its access log for the failing
   hop: status + **response flag**.
3. **What does the callee's sidecar say?** If it has no line for the
   request, the failure is on the caller's side or in between.
4. **What does Envoy have?** `istioctl pc route|cluster|endpoint|listener`
   on the side that failed.
5. **What config applies?** `istioctl x describe pod`, `istioctl analyze`,
   `kubectl get vs,dr,pa,authorizationpolicy,sidecar -n bookinfo`.
6. **Is the control plane there?** `kubectl -n istio-system get pods`,
   `istioctl proxy-status`.

Scenarios 6, 9 and 10 sit outside that path — they are about entry,
telemetry, and pod startup. Recognising when the default order does not
apply is part of the exercise.

---

**Done when**
- All ten diagnosed, each with a completed worksheet, and each fixed by
  you (not by `restore`).
- `runbooks/06-troubleshooting-lab.md` has ten rows, and its *What would
  have told me this first* column is filled for every one.
- You can explain, for scenarios 1, 3, 4 and 8, the single signal that
  separates each from the other three.
- `mesh-break.sh restore all` then `check` shows the healthy baseline.

**Runbook:** `runbooks/06-troubleshooting-lab.md`.
