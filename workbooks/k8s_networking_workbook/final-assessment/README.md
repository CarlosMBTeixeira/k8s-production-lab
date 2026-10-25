# Final assessment

Weeks 24–26. A capstone you build alone, a consolidation week, then twelve
scenarios you have **not** seen, scored honestly.

| Week | What | File |
|---|---|---|
| 24 | Final capstone — a platform day | [`capstone.md`](capstone.md) |
| 25 | Rewrite `troubleshooting-playbook.md` and the cheatsheet's Flows from memory, then diff against the committed files; fix the gaps | `../troubleshooting-playbook.md`, `../cheatsheet.md` |
| 26 | 12 unseen break/fix scenarios | below + [`scoring-sheet.md`](scoring-sheet.md) |

## The rules

- **No workbook, no notes, no cheatsheet.** Official docs and `--help` / `man` are allowed —
  they're what you'd have at 03:00.
- **One scenario at a time.** Start the clock when the ticket prints, stop it
  when you've proved the fix with the ticket's own command.
- **Hard stop at 30 minutes.** Score what you have, then move on.
- **Don't read `break.sh` or `solution.b64`.** They're encoded so you can't by accident.
  After scoring a scenario, `bash reveal.sh S07` shows its solution.
- Write the four beats for every scenario on the sheet, as in every lab.

## The scenarios

Only the environment is listed — the ticket is the only description you get.
Grouped so each environment is built once.

| ID | Environment | Run |
|---|---|---|
| S01 | netlab-a | `sudo bash /workbook/final-assessment/scenarios/S01/break.sh` |
| S02 | netlab-a | `sudo bash /workbook/final-assessment/scenarios/S02/break.sh` |
| S03 | netlab-a + netlab-b | on b: `sudo bash …/S03/break.sh b`, then on a: `sudo bash …/S03/break.sh a` |
| S04 | k8slab (2 workers, option 0) | `bash scenarios/S04/break.sh` (WSL host) |
| S05 | k8slab | `bash scenarios/S05/break.sh` |
| S06 | k8slab | `bash scenarios/S06/break.sh` |
| S07 | k8slab — asks before changing a node | `bash scenarios/S07/break.sh` |
| S08 | k8slab | `bash scenarios/S08/break.sh` |
| S12 | k8slab | `bash scenarios/S12/break.sh` |
| S09 | kind `lab-cilium` with Cilium KPR + Hubble (lab 3.08's setup) | `bash scenarios/S09/break.sh` |
| S10 | kind `lab-plain` with MetalLB (lab 4.02's setup) | `bash scenarios/S10/break.sh` |
| S11 | lab 4.08's capstone environment (kind `lab-calico` + `lab-frr`) | `bash scenarios/S11/break.sh` |

A suggested week 26: day 1 netlab (S01–S03), day 2 k8slab (S04–S08, S12),
day 3 kind (S09–S11), day 4 scoring, reveal, and the runbook.

## Passing

From the program's exit criteria ([`../README.md`](../README.md)):

- **≥ 96 / 120** (80 %), **and**
- every scenario's root cause found in **< 20 minutes**.

Below that: the failed scenarios become the first rows of
`../runbooks/final-assessment.md`, and the labs they map to (named in each
solution) are redone in the following two weeks — outside the 26, by choice.

## After each scenario

```bash
bash reveal.sh S01          # only after the sheet row is filled
```

Then clean up as the ticket says, and write any row that taught you
something into `../runbooks/final-assessment.md`.
