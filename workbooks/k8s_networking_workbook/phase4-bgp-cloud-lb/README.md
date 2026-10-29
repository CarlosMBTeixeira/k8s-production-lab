# Phase 4 — BGP, cloud patterns, load balancing

Weeks 19–23. How clusters meet the network around them: BGP to the
fabric (FRR, MetalLB, Calico, Cilium), the cloud patterns those clusters
live inside, L4/L7 load balancing and TLS, and the metrics that would have
warned you about Phases 2–3's failures.

## Where

| Env | Labs | Notes |
|---|---|---|
| **netlab-c** (Containerlab) | 4.01, 4.05 | work from a **local copy**: `cp -r /workbook/phase4-bgp-cloud-lb ~/p4` — Docker can't reliably bind-mount files from the sshfs share |
| **kind** + [`lib/frr-kind.sh`](lib/frr-kind.sh) | 4.02, 4.03, 4.04, 4.06, 4.08 | FRR router (AS 65000) and an outside client on the WSL host's Docker |
| **k8slab**, 2 workers, option 3 | 4.07 | the repo's observability stack |

`lib/frr-kind.sh up <cluster> <frr.conf.tpl>` builds:

```
lab-client 172.30.99.10 ── [lab-ext 172.30.99.0/24] ── lab-frr (AS 65000) ── [kind network] ── kind nodes (AS 64512)
```

and gives every kind node a return route to `lab-ext` via `lab-frr`, so
"outside" traffic is really routed. `lib/daemons` and `lib/vtysh.conf` are
the FRR daemons and vtysh files every router in this phase (and Phase 1's
`routed` topology) uses.

## Labs

| # | Lab | Env | h | Week |
|---|---|---|---|---|
| 4.01 | [BGP with FRR](01-frr-bgp/) | netlab-c | 5 | 19 |
| 4.02 | [MetalLB — L2 vs BGP](02-metallb-l2-bgp/) | kind | 5 | 19 |
| 4.03 | [Calico BGP and advertising Service IPs](03-calico-bgp/) | kind | 5 | 20 |
| 4.04 | [Cilium BGP control plane](04-cilium-bgp/) | kind | 4 | 20 |
| 4.05 | [Cloud networking patterns, simulated](05-cloud-patterns/) | netlab-c | 5 | 21 |
| 4.06 | [L4/L7 load balancing, TLS, HTTP/2, QUIC](06-lb-tls-http2-quic/) | kind + Docker | 5 | 21 |
| 4.07 | [Network observability](07-network-observability/) | k8slab (3) | 4 | 23 |
| 4.08 | [**Capstone** — FRR ↔ cluster, Service IPs over BGP](08-capstone-bgp-service-ips/) | kind | 6 | 23 |

Week 22 is the buffer. **Cut order if behind:** 4.04 (4.03 covers the
concepts), then 4.06 §2.4 (QUIC).

## Exit check (end of week 23)

The Phase 4 criteria in [`../README.md`](../README.md#phase-4--bgp-cloud-load-balancing-phase4-bgp-cloud-lb).
Then write `../runbooks/phase4-bgp-cloud-lb.md`.
