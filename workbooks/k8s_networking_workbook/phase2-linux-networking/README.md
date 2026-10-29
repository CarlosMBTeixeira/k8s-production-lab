# Phase 2 — Linux networking, built by hand

Weeks 1–8. Everything Docker and a CNI plugin do, done with `ip`, `nft`,
`iptables`, `conntrack`, `tc` and `tcpdump`, until the capstone where you
write a working CNI plugin.

## Where

- **netlab-a** for single-host labs, **netlab-a + netlab-b** for 2.08 and 2.12.
  Both are Docker-free on purpose (see `../setup/README.md`).
- Inside a VM: `sudo -i`, then `cd /workbook/phase2-linux-networking/<lab>`.
  Every command in these labs runs as root unless it says otherwise.
- Labs 2.05, 2.06 and 2.10 change netlab-a's **root** namespace (sysctls,
  iptables). Blast radius: that VM only; your `multipass shell` keeps
  working because nothing touches INPUT or the uplink's own address. Reset:
  `multipass delete --purge netlab-a && bash setup/netlab.sh up a` (from the
  workbook folder on the WSL host).

## Shared pieces

- [`lib/topo-crs.sh`](lib/topo-crs.sh) — the client / router / server
  topology (`up`, `serve`, `down`). You build it by hand in 2.03; later labs
  call it.
- `break.sh` in each lab rebuilds that lab's starting state, injects a fault
  and prints a ticket. Run it, then diagnose with the lab README closed.
- `solution.md` — the fault in plaintext, the diagnosis path and the fix.

## Labs

| # | Lab | h | Week |
|---|---|---|---|
| 2.01 | [Network namespaces and veth pairs](01-netns-veth/) | 3 | 1 |
| 2.02 | [Bridges, ARP and VLAN filtering](02-bridge-arp-vlan/) | 4 | 1 |
| 2.03 | [Routing, policy routing and rp_filter](03-routing-policy-rpfilter/) | 4 | 2 |
| 2.04 | [iptables, nftables and packet tracing](04-iptables-nftables/) | 4 | 2 |
| 2.05 | [NAT — what Docker does](05-nat/) | 5 | 3 |
| 2.06 | [conntrack](06-conntrack/) | 4 | 5 |
| 2.07 | [tcpdump methodology](07-tcpdump-method/) | 3 | 5 |
| 2.08 | [VXLAN by hand](08-vxlan/) | 4 | 6 |
| 2.09 | [MTU and PMTUD](09-mtu-pmtudisc/) | 3 | 6 |
| 2.10 | [A Service by hand — DNAT, then IPVS](10-service-by-hand/) | 4 | 7 |
| 2.11 | [eBPF basics](11-ebpf-basics/) | 4 | 7 |
| 2.12 | [**Capstone** — a mini-CNI across two hosts](12-capstone-mini-cni/) | 9 | 8 |

## Exit check (end of week 8)

See the Phase 2 criteria in [`../README.md`](../README.md#phase-2--linux-networking-phase2-linux-networking).
Then write `../runbooks/phase2-linux-networking.md`.
