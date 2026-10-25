# Scoring sheet

Fill one block per scenario **before** running `reveal.sh`. Be strict:
you are the only one who'll know.

## Points per scenario (10)

| Criterion | Points |
|---|---|
| **Root cause** named as a mechanism ("X selects Y but Z", not "a config issue") | 4 — exact · 2 — right layer, wrong detail · 0 — wrong |
| **Fix** — minimal, correct, doesn't break something else | 2 · 1 if it works but is a workaround the solution calls out · 0 |
| **Proof** — the ticket's own command, now working | 1 |
| **Time** to root cause | 3 — ≤ 10 min · 2 — ≤ 15 · 1 — ≤ 20 · 0 — > 20 |

Used the workbook or a hint: cap the scenario at 5.

## Scenarios

```
S__   date ________   start __:__   root cause found __:__   fixed __:__
Hypothesis 1:
Tool / expected / seen:
Hypothesis 2 (if any):
Tool / expected / seen:
Root cause (one sentence, mechanism):
Fix:
Proof:
What would have told me first:
Score:  cause _/4  fix _/2  proof _/1  time _/3   = __/10
```

Copy the block twelve times, or keep them in `../runbooks/final-assessment.md`.

## Totals

| ID | Cause /4 | Fix /2 | Proof /1 | Time /3 | Total /10 | Minutes to cause |
|---|---|---|---|---|---|---|
| S01 | | | | | | |
| S02 | | | | | | |
| S03 | | | | | | |
| S04 | | | | | | |
| S05 | | | | | | |
| S06 | | | | | | |
| S07 | | | | | | |
| S08 | | | | | | |
| S09 | | | | | | |
| S10 | | | | | | |
| S11 | | | | | | |
| S12 | | | | | | |
| **Total** | | | | | **/120** | **max:** |

**Pass:** total ≥ 96 **and** "max minutes to cause" < 20.

## Pattern check (after reveal)

Which playbook layer was each root cause in? Count them:

| Layer (playbook) | Count | Avg minutes |
|---|---|---|
| 1 DNS | | |
| 2 Service → endpoints | | |
| 3 Policy | | |
| 4 Pod network on the node | | |
| 5 Cross-node / underlay | | |
| 6 Netfilter / conntrack | | |
| 7 Edge: LB, BGP, Gateway | | |
| 8 Egress | | |
| 9 L7 / TLS | | |

The slowest layer is what you study next.
