# Workbook — Kubernetes and Linux networking

Twenty-six weeks, 8–10 hours a week, from "I run Kubernetes in
production" to "I find the broken hop in a cross-node, NATed, policy-
filtered, BGP-advertised packet path in fifteen minutes, with tcpdump."

The brief this answers is kept verbatim in [`00-brief.md`](00-brief.md).

**Start:** Monday 2026-10-26 · **End:** Sunday 2027-04-25.

---

## How to use this workbook

1. Bring up the environment the lab names — see [`setup/README.md`](setup/README.md).
   Only one environment runs at a time (19 GiB host).
2. Work the lab top to bottom. **Write the "Expected" column before
   running the command** — that is the whole discipline.
3. Run the lab's `break.sh`, close the lab README, and diagnose. Its payload
   is encoded so a glance does not spoil it. Open `solution.md` only after
   you have a fix, or after 45 minutes stuck.
4. Add what you used to [`cheatsheet.md`](cheatsheet.md) and the failure to the
   phase runbook in [`runbooks/`](runbooks/).
5. Tick the box below.

Every lab has the same seven sections: objective and time, prerequisites,
hands-on, verification, break/fix, cleanup, and three things you should be
able to explain. Every break/fix has the same four beats:

> **Hypothesis** — what you believe is broken, stated before you look.
> **Tool** — the single command that tests it.
> **Expected if right** — written *before* running it.
> **What would have told me this sooner** — the signal that existed before
> the symptom did. This column is the product.

**RISKY** marks anything that changes a node, the CNI, kube-proxy, sysctls
or cluster-wide state. Each one states its blast radius and rollback. Every
environment here is disposable, but read the box before running it.

---

## Environments

| Name | What | RAM | Used by |
|---|---|---|---|
| **netlab** | Plain Ubuntu 24.04 Multipass VMs: `netlab-a`, `netlab-b` (no Docker) for Phase 2; `netlab-c` with Docker + Containerlab + FRR | 3–6 GB | Phase 1 (c), Phase 2 (a, b), Phase 4 labs 01, 05 (c) |
| **k8slab** | The repo's cluster: `LAB_WORKERS=2 bash ../../scripts/pipeline/main.sh`, option **0** (3.12: option 8; 4.07: option 3) | ~16 GB | Phase 3 labs 01, 02, 04, 05, 06, 09, 12 · Phase 4 lab 07 |
| **kind** | Docker on the WSL host, configs in `setup/kind/` | 2–8 GB | Phase 3 labs 03, 07, 08, 10, 11, 13 · Phase 4 labs 02, 03, 04, 06, 08 |

Phase 4's BGP labs run on kind on purpose: FRR, the cluster and an
"outside" client all fit on one Docker host in ~4 GB, while k8slab plus an
FRR VM would not fit beside it.

---

## Schedule

Budget: 9 h/week. Buffer weeks are for catching up, then redoing the
break/fix of the lab you were slowest on, without notes.

| Wk | Starts | Phase | Work | h |
|---|---|---|---|---|
| 1 | 2026-10-26 | setup · 1 · 2 | `setup/` · drills 01–02 · labs 2.01–2.02 | 9 |
| 2 | 11-02 | 1 · 2 | drills 03–04 · labs 2.03–2.04 | 9 |
| 3 | 11-09 | 1 · 2 | drills 05–06 · lab 2.05 | 8 |
| **4** | 11-16 | — | **Buffer** | ≤9 |
| 5 | 11-23 | 1 · 2 | drills 07–08 · labs 2.06–2.07 | 9 |
| 6 | 11-30 | 1 · 2 | drills 09–10 · labs 2.08–2.09 | 9 |
| 7 | 12-07 | 1 · 2 | drills 11–12 · labs 2.10–2.11 | 10 |
| 8 | 12-14 | 2 | **capstone 2.12** · Phase 1+2 runbooks · Phase 1+2 exit check | 9 |
| **9** | 12-21 | — | **Buffer** (holidays) | ≤9 |
| 10 | 12-28 | 3 | lab 3.01 (light week) | 5 |
| 11 | 2027-01-04 | 3 | labs 3.02–3.03 | 10 |
| 12 | 01-11 | 3 | labs 3.04–3.05 | 10 |
| **13** | 01-18 | — | **Buffer** | ≤9 |
| 14 | 01-25 | 3 | labs 3.06–3.07 | 10 |
| 15 | 02-01 | 3 | labs 3.08–3.09 | 10 |
| 16 | 02-08 | 3 | labs 3.10–3.11 | 10 |
| 17 | 02-15 | 3 | lab 3.12 · **capstone 3.13** · Phase 3 runbook + exit check | 10 |
| **18** | 02-22 | — | **Buffer** | ≤9 |
| 19 | 03-01 | 4 | labs 4.01–4.02 | 9 |
| 20 | 03-08 | 4 | labs 4.03–4.04 | 9 |
| 21 | 03-15 | 4 | labs 4.05–4.06 | 10 |
| **22** | 03-22 | — | **Buffer** | ≤9 |
| 23 | 03-29 | 4 | lab 4.07 · **capstone 4.08** · Phase 4 runbook + exit check | 10 |
| 24 | 04-05 | final | Final capstone (`final-assessment/capstone.md`) | 9 |
| 25 | 04-12 | final | Consolidate `cheatsheet.md` and `troubleshooting-playbook.md` from memory, then diff against the files | 8 |
| 26 | 04-19 | final | **Final assessment** — 12 scenarios, scored | 9 |

**If you fall behind,** cut in this order and say so in the tracker:
lab 4.04 (Cilium BGP — 4.03 covers the concept), the QUIC part of 4.06,
lab 3.03's nftables half, lab 3.11. Never cut a buffer week to make room;
cut content.

---

## Phases and exit criteria

Each criterion is a timed, closed-book check. Do it at the end of the
phase; record the time in the tracker.

### Phase 1 — Network fundamentals, by doing ([`phase1-ccna-drills/`](phase1-ccna-drills/))
Twelve short drills replacing the CCNA course for a non-exam learner.
- [ ] Subnet 10 random prefixes (network, broadcast, host range, mask) in **< 5 min**, no calculator.
- [ ] Given one `tcpdump -e -nn -v` capture of a routed HTTP request, name every header field that changes per hop and why, in **< 10 min**.
- [ ] Build a 3-router OSPF topology in Containerlab from a blank file, converged, in **< 30 min**.

### Phase 2 — Linux networking ([`phase2-linux-networking/`](phase2-linux-networking/))
- [ ] Rebuild the capstone's two-host mini-CNI (namespaces, bridge, NAT, routing, then VXLAN) from an empty VM, **< 45 min**, no notes.
- [ ] Given a packet that enters `eth0` and never reaches a namespace, locate the dropping hook with `nft monitor trace` or `pwru` in **< 10 min**.
- [ ] Find and fix a PMTUD blackhole with only `tcpdump`, `ip` and `ping -M do` in **< 15 min**.
- [ ] Explain, from `conntrack -L`, why a DNAT'd reply would be dropped if conntrack were flushed mid-flow.

### Phase 3 — Kubernetes networking ([`phase3-k8s-networking/`](phase3-k8s-networking/))
- [ ] Diagnose a cross-node pod-to-pod failure using only `tcpdump`, `ip`, `conntrack` and `hubble` (Cilium) or `calicoctl` (Calico) in **< 15 min**.
- [ ] Follow a ClusterIP from `KUBE-SERVICES` to the backend pod's veth, naming every chain or BPF map, in **< 10 min**.
- [ ] Diagnose three DNS failures (ndots storm, upstream loop, policy blocking :53) from symptom to cause in **< 10 min each**.
- [ ] Trace one packet through OVN-Kubernetes with `ovnkube-trace` and say which logical port dropped it.

### Phase 4 — BGP, cloud, load balancing ([`phase4-bgp-cloud-lb/`](phase4-bgp-cloud-lb/))
- [ ] From a fresh cluster, peer it with FRR and advertise a LoadBalancer IP reachable from outside, in **< 30 min**.
- [ ] Given a BGP session stuck in `Active`, find the cause in **< 10 min**.
- [ ] Draw a hub-and-spoke design with private endpoints and split-horizon DNS and point to the hop where a resolution or route would fail.
- [ ] Explain, with a capture, why a gRPC client sends every request to one pod behind a ClusterIP.

### Program exit — all of these
- [ ] **Final assessment ≥ 80 %**, every scenario diagnosed in **< 20 min** ([`final-assessment/`](final-assessment/)).
- [ ] [`troubleshooting-playbook.md`](troubleshooting-playbook.md) rewritten from memory matches the committed one on every layer.
- [ ] Four runbooks in [`runbooks/`](runbooks/), one per phase, with every "what would have told me first" cell filled.
- [ ] At least one item from [`reference-track.md`](reference-track.md) published (blog post, upstream issue or PR).

---

## Progress tracker

Record the date and, for break/fix, the minutes to diagnose.

### Setup
- [ ] `setup/install-tools.sh` run, versions recorded
- [ ] `setup/netlab.sh up all` works; `/workbook` visible in all three VMs
- [ ] kind cluster from `setup/kind/cilium.yaml` comes up and is deleted cleanly

### Phase 1 — drills
- [ ] 01 Encapsulation, layer by layer
- [ ] 02 Ethernet, ARP and MAC learning
- [ ] 03 IPv4 addressing and subnetting
- [ ] 04 The IPv4 header: TTL, DF, fragmentation
- [ ] 05 Static routing and the life of a packet
- [ ] 06 VLANs and 802.1Q trunks
- [ ] 07 TCP and UDP on the wire
- [ ] 08 DNS resolution
- [ ] 09 DHCP
- [ ] 10 OSPF basics with FRR
- [ ] 11 First-hop redundancy with VRRP
- [ ] 12 IPv6 basics

### Phase 2 — Linux networking
- [ ] 2.01 Network namespaces and veth pairs
- [ ] 2.02 Bridges, ARP and VLAN filtering
- [ ] 2.03 Routing, policy routing and rp_filter
- [ ] 2.04 iptables, nftables and packet tracing
- [ ] 2.05 NAT — what Docker does
- [ ] 2.06 conntrack
- [ ] 2.07 tcpdump methodology
- [ ] 2.08 VXLAN by hand
- [ ] 2.09 MTU and PMTUD
- [ ] 2.10 A Service by hand — DNAT, then IPVS
- [ ] 2.11 eBPF basics
- [ ] 2.12 **Capstone — a mini-CNI across two hosts**

### Phase 3 — Kubernetes networking
- [ ] 3.01 Calico pod networking anatomy
- [ ] 3.02 kube-proxy in iptables mode
- [ ] 3.03 kube-proxy IPVS and nftables modes
- [ ] 3.04 CoreDNS and DNS troubleshooting
- [ ] 3.05 NetworkPolicy on Calico
- [ ] 3.06 MTU and conntrack in the cluster
- [ ] 3.07 Cilium with kube-proxy replacement
- [ ] 3.08 Cilium policies and Hubble
- [ ] 3.09 Gateway API in depth
- [ ] 3.10 OVN-Kubernetes anatomy
- [ ] 3.11 OVN-Kubernetes operations — the OpenShift view
- [ ] 3.12 The service mesh datapath
- [ ] 3.13 **Capstone — Cilium end to end**

### Phase 4 — BGP, cloud, load balancing
- [ ] 4.01 BGP with FRR
- [ ] 4.02 MetalLB — L2 vs BGP
- [ ] 4.03 Calico BGP and advertising Service IPs
- [ ] 4.04 Cilium BGP control plane
- [ ] 4.05 Cloud networking patterns, simulated
- [ ] 4.06 L4/L7 load balancing, TLS, HTTP/2, QUIC
- [ ] 4.07 Network observability
- [ ] 4.08 **Capstone — FRR ↔ cluster, Service IPs over BGP**

### Final
- [ ] Final capstone
- [ ] Cheatsheet and playbook consolidated
- [ ] Final assessment — score: ___ / 120

---

## Files

| Path | What |
|---|---|
| [`setup/`](setup/) | Tool installer, netlab VM script, kind configs |
| [`cheatsheet.md`](cheatsheet.md) | Commands and flows; grows lab by lab |
| [`troubleshooting-playbook.md`](troubleshooting-playbook.md) | Layer-by-layer incident checklist |
| [`runbooks/`](runbooks/) | One runbook per phase, from `_template.md` |
| [`reference-track.md`](reference-track.md) | Blog, runbook and upstream contribution ideas |
| [`final-assessment/`](final-assessment/) | Final capstone, 12 unseen scenarios, scoring sheet |
