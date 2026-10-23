# Runbooks — Istio Service Mesh

One per session, from [`_template.md`](_template.md), named
`NN-<session-slug>.md` to match the session file. Same rules as
`workbooks/observability_workbook/runbooks/`: write the row while the symptom is
still fresh, and the fifth column — *what would have told me this
first* — is the point.

| # | Runbook | Written |
|---|---|---|
| 00 | Toolbox, and following one request | ☐ |
| 01 | Traffic routing | ☐ |
| 02 | Resilience | ☐ |
| 03 | Security | ☐ |
| 04 | Observability for daily operations | ☐ |
| 05 | Operating the mesh | ☐ |
| 06 | Troubleshooting lab (one row per scenario) | ☐ |
| 07 | OpenShift Service Mesh 3 | ☐ |

Already written, from bringing the mesh up:
[`../../observability_workbook/runbooks/mesh-istio-kiali-install.md`](../../observability_workbook/runbooks/mesh-istio-kiali-install.md).

## Envoy response flags — the column you will fill most

The flag in the access log is usually the fastest discriminator. These
are the ones the sessions produce on purpose:

| Flag | Meaning | Produced in |
|---|---|---|
| `NR` | no route — or, on an inbound listener, `filter_chain_not_found` (plaintext into STRICT) | 06 scenario 1 |
| `NC` | no cluster — a route points at a cluster Envoy doesn't have (missing subset) | 06 scenario 2 |
| `UC` | upstream connection terminated (TLS mismatch, server reset) | 06 scenario 3 |
| `UO` | upstream overflow — circuit breaker tripped, request never sent | 02 |
| `UH` | no healthy upstream — all endpoints ejected | 02 |
| `URX` | upstream retry limit exceeded | 02 |
| `DI` / `FI` | delay / fault injected by config | 02 |
| `-` with `direct_response … block_all` | `REGISTRY_ONLY` blocked an unknown destination | 05, 06 scenario 8 |

Reference: Envoy docs → *Access logging* → "Command operators" →
`%RESPONSE_FLAGS%`.
