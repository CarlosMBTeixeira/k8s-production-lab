# Phase 1 — Network fundamentals, by doing

Weeks 1–7, about 2 hours a week, alongside Phase 2. Twelve short drills that
replace the Jeremy's IT Lab CCNA course for someone who isn't taking the
exam and isn't watching the videos: each drill teaches its topic itself
(three bullets of theory at the end), with captures instead of slides.

Linux and FRR in Containerlab, not Cisco IOS in Packet Tracer: the
concepts are identical, the CLI is the one you'll use on Kubernetes nodes,
and it runs on netlab-c with no account or Windows install.

## Where

- **netlab-c** (Docker + Containerlab): drills 01–06, 08, 10. Work from a local copy:
  `sudo -i; cp -r /workbook ~/wb; cd ~/wb/phase1-ccna-drills` (Docker can't bind-mount from the sshfs share).
- **netlab-a** (namespaces): drills 07, 09, 11, 12, as root from `/workbook/phase1-ccna-drills/<drill>`.
- Every Containerlab node also has `eth0` on 172.20.20.0/24: Containerlab's management link, not part of any drill. Ignore it in `ip addr`/`ip route` output; `lan-setup.sh` removes its default route so it can't carry lab traffic.
- Shared topologies in [`topo/`](topo/): `routed` (3 FRR routers, 2 hosts), `lan` (2 bridges-as-switches, 4 hosts, a router), `dns` (CoreDNS + client).

## The course, mapped

The pasted playlist covers **Days 1–13**. Those carry their day number.
Later topics are listed **by name, not by day** — no guessed numbers.

### Days 1–13

| Course item | Verdict | Where it's covered |
|---|---|---|
| Day 1: Network Devices | skim — 10 min of reading is enough | drill 01 (what a switch vs a router does to a frame) |
| Day 1 Lab: Packet Tracer Introduction | **skip** | — |
| Day 1 Extra: Anki Flashcards | **skip** | — |
| Day 2: Interfaces and Cables | skim — only speed/duplex/autoneg matter | drill 02 (`ethtool`) |
| Day 2 Lab: Connecting Devices | **skip** | — |
| Day 3: OSI Model & TCP/IP Suite | **essential** | drill 01 |
| Day 3 Lab: OSI Model | **skip** (drill 01 replaces it) | drill 01 |
| Day 3 (Dec 2025): How the TCP/IP Model Actually Works | **essential** | drill 01 |
| Day 4: Intro to the CLI | **skip** — Cisco IOS | — |
| Day 4 Lab: Basic Device Security | **skip** — Cisco IOS | — |
| Day 5: Ethernet LAN Switching, Part 1 | **essential** | drill 02 |
| Day 6: Ethernet LAN Switching, Part 2 | **essential** | drill 02 |
| Day 6 Lab: Analyzing Ethernet Switching | replaced | drill 02 |
| Day 7: IPv4 Addressing, Part 1 | **essential** | drill 03 |
| Day 8: IPv4 Addressing, Part 2 | **essential** | drill 03 |
| Day 8 Lab: Configuring IP Addresses | replaced | drill 03 |
| Day 9: Switch Interfaces | skim — speed/duplex mismatch symptoms only | drill 02 |
| Day 9 Lab: Configuring Interfaces | **skip** — Cisco IOS | — |
| Day 10: IPv4 Header | **essential** | drill 04 |
| Day 11 (part 1): Routing Fundamentals | **essential** | drill 05 |
| Day 11 Lab 1: Configuring Static Routes | replaced | drill 05 |
| Day 11 Lab 2: Troubleshooting Static Routes | replaced | drill 05 |
| Day 11 (part 2): Static Routing | **essential** | drill 05 |
| Day 12: The Life of a Packet | **essential** | drills 01, 05 |
| Day 12 Lab: Life of a Packet | replaced | drill 05 |
| Day 13: Subnetting, Part 1 | **essential** | drill 03 |

### Later topics (by name)

| Topic | Verdict | Where |
|---|---|---|
| Subnetting (VLSM, the rest of the subnetting days) | **essential** | drill 03 |
| VLANs, trunks, inter-VLAN routing | **essential** | drill 06 |
| DTP, VTP | **skip** — Cisco-only protocols | — |
| Spanning Tree (STP/RSTP) | basics essential, details skim | drill 06 |
| EtherChannel / LACP | skim — it's Linux bonding/LACP on nodes | note in drill 02 |
| Dynamic routing intro, OSPF | **essential** (OSPF basics) | drill 10 |
| RIP, EIGRP | **skip** | — |
| First-hop redundancy (HSRP/VRRP/GLBP) | **essential** as VRRP (kube-vip, keepalived) | drill 11 |
| TCP and UDP | **essential** | drill 07 |
| IPv6 | **essential** basics | drill 12 |
| ACLs (standard/extended) | **essential** — as netfilter | Phase 2 lab 2.04 |
| NAT (static, dynamic, PAT) | **essential** | Phase 2 lab 2.05 |
| DNS | **essential** | drill 08 |
| DHCP | **essential** | drill 09 |
| CDP / LLDP | **skip** (know `lldpd` exists) | — |
| NTP | skim | — |
| SNMP, Syslog | skim — Prometheus/Loki replace them in this lab | Phase 4 lab 4.07 |
| SSH, FTP/TFTP | **skip** | — |
| QoS | skim — Linux `tc` | Phase 2 lab 2.07 |
| Security fundamentals, port security, DHCP snooping, DAI | **skip** (know they exist; DHCP snooping is drill 09's break/fix in reverse) | — |
| LAN / WAN architectures | skim | — |
| Virtualization and cloud | skim | Phase 4 lab 4.05 |
| Wireless (all days) | **skip** | — |
| Network automation, REST, JSON/YAML, Ansible/Puppet/Chef | **skip** — already your day job | — |

## Drills

| # | Drill | Env | Week |
|---|---|---|---|
| 01 | [Encapsulation, layer by layer](01-encapsulation/) | netlab-c, routed | 1 |
| 02 | [Ethernet, ARP and MAC learning](02-ethernet-arp/) | netlab-c, lan | 1 |
| 03 | [IPv4 addressing and subnetting](03-ipv4-subnetting/) | netlab-c, lan | 2 |
| 04 | [The IPv4 header: TTL, DF, fragmentation](04-ipv4-header/) | netlab-c, routed | 2 |
| 05 | [Static routing and the life of a packet](05-static-routing/) | netlab-c, routed | 3 |
| 06 | [VLANs, trunks and STP](06-vlans-stp/) | netlab-c, lan | 3 |
| 07 | [TCP and UDP on the wire](07-tcp-udp/) | netlab-a | 5 |
| 08 | [DNS resolution](08-dns/) | netlab-c, dns | 5 |
| 09 | [DHCP](09-dhcp/) | netlab-a | 6 |
| 10 | [OSPF basics with FRR](10-ospf/) | netlab-c, routed | 6 |
| 11 | [First-hop redundancy with VRRP](11-vrrp/) | netlab-a | 7 |
| 12 | [IPv6 basics](12-ipv6/) | netlab-a | 7 |

Every drill has the same seven sections as the labs, smaller: ~1.5 h each.

## Exit check (end of week 8)

The Phase 1 criteria in [`../README.md`](../README.md). Then write
`../runbooks/phase1-fundamentals.md`.
