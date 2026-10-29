# Final capstone — a platform day

| | |
|---|---|
| **Objective** | In one working day, alone, design and build a small bare-metal-style Kubernetes platform network from nothing, document it, and break it once on purpose with a failure you choose. |
| **Time** | 9 h (week 24), one sitting if you can |
| **Where** | kind on the WSL host (`lab-final`), plus `../phase4-bgp-cloud-lb/lib/frr-kind.sh` |
| **Rules** | No workbook labs open. Official docs allowed. Your own cheatsheet allowed **only** for this capstone. |

## The brief

A team needs a platform for a three-tier app that's reachable from "the
corporate network" (lab-client behind lab-frr), with production
constraints. Build it, then hand it over.

### Requirements

1. **Cluster:** kind, 1 control plane + 2 workers, named `lab-final`. CNI of
   your choice — **Cilium or Calico**; write down why in the design note.
2. **No overlay:** pods routed natively; the fabric (lab-frr, AS 65000)
   learns what it needs by BGP and **only** what it needs (no pod CIDRs).
3. **Service exposure:** one external IP per public app, advertised by BGP
   from nodes with endpoints only; client source IP preserved end to end.
4. **Ingress:** Gateway API in front of the frontend, **HTTPS only** on
   `app.corp.lab`, certificate from **your own CA** (root + intermediate,
   full chain served), HTTP redirected to HTTPS.
5. **Policy:** default deny in and out for the app namespace; DNS allowed;
   one allow per edge (gateway → frontend → api → db); api may reach
   `example.com` only.
6. **Observability:** Hubble (if Cilium) or Calico's policy logging (if
   Calico) shows every denied flow from requirement 5.
7. **Failure budget:** a dead node must be removed from ECMP in ≤ 10 s.

### Deliverables

- [ ] `final-assessment/capstone/` with every manifest, values file and FRR
      config, applied in order by one `build.sh` that rebuilds it all from
      `kind create cluster` in under 20 minutes.
- [ ] `final-assessment/capstone/DESIGN.md`, one page: IP plan (node, pod,
      Service, external, client ranges), MTU budget, BGP design (ASNs,
      sessions, what's advertised, filters, timers), the policy matrix, and
      the top five failure modes with **the metric or command that detects
      each**.
- [ ] `final-assessment/capstone/verify.sh` — your own checks for every
      requirement above (reuse ideas from 3.13 and 4.08's verifiers).
- [ ] One **break.sh** of your own design: a realistic single fault, plus
      its runbook row. Run it a week later (during week 26) and time
      yourself.

### Done when

`build.sh` on a fresh kind cluster, then `verify.sh`, passes with no manual
steps, and DESIGN.md's five failure modes each have a detection that you
have actually seen fire or fail.

This is also the first item for `../reference-track.md`: a blog post or a
public repo of exactly this.
