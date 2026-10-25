# Reference track

Things worth publishing or contributing, picked up along the way. **Rule:**
none of this takes time from a lab. Do one in a buffer week, or not at all.
The program exit needs one item done.

## Blog posts — each one is a lab you already did, written for someone else

| Idea | Built from | Angle |
|---|---|---|
| "A CNI plugin in 80 lines of bash" | 2.12 | The CNI spec is small; show ADD/DEL, IPAM, and what kubelet passes in |
| "Where did my packet go? `pwru` vs `nft monitor trace`" | 2.04, 2.11 | Same drop, two tools, which answers faster |
| "The 5-second DNS delay, reproduced on purpose" | 2.06, 3.04 | conntrack `insert_failed`, `single-request-reopen`, NodeLocal DNSCache |
| "ClusterIP, four ways" | 3.02, 3.03, 3.07, 3.10 | One Service through iptables, IPVS, eBPF and OVN load balancers |
| "Calico IPIP vs Cilium VXLAN vs OVN Geneve on the wire" | 3.01, 3.07, 3.10 | Three captures, overhead per packet, MTU defaults |
| "Why your gRPC service ignores your replicas" | 4.06 | Connection-level balancing; fixes: headless + client LB, mesh, L7 Gateway |
| "MetalLB L2 failover: what the client's ARP cache does" | 4.02 | GARP timing measured |
| "Pod CIDR overlapping a host network: a found-in-the-wild bug" | 3.01 | The 192.168.0.0/16 vs virbr0 case from this lab |

## Runbooks worth sharing at work

- The Phase 3 runbook, filtered to what applies on OpenShift (OVN-K rows).
- A one-page "DNS in Kubernetes" triage, from 3.04 + playbook layer 1.
- A conntrack sizing and alerting note, from 3.06 + 4.07.

## Upstream contributions — start small

| Project | Where to look | First step |
|---|---|---|
| Cilium | `good-first-issue` label; docs under `Documentation/` | A docs fix found while doing 3.07/3.08 (a command that changed, an unclear step) |
| Calico | `projectcalico/calico` docs repo; `calicoctl` UX issues | Reproduce an open issue on the kind Calico cluster and add the repro |
| CoreDNS | plugin docs (`plugin/*/README.md`) | Clarify a plugin behaviour you tested in 3.04 (`forward`, `cache`, `loop`) |
| OVN-Kubernetes | `docs/` and the kind setup | Report or fix anything that broke when following lab 3.10's upstream steps |
| netshoot | tool list | Add a missing tool you needed |
| Containerlab | lab examples | Contribute the Phase 4 FRR + kind topology as an example |

Track here: date, link, status.

| Date | Item | Link | Status |
|---|---|---|---|
| | | | |
