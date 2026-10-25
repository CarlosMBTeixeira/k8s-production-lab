# Drill 06 — VLANs, trunks and STP

| | |
|---|---|
| **Objective** | Split one switched network into two VLANs across two switches, route between them with a router-on-a-stick, then add a redundant link and let Spanning Tree keep it from melting the network. |
| **Time** | 2 h (week 3) · course: VLANs, trunking, STP (later days) |
| **Where** | netlab-c, `topo/lan`, root |
| **Risk** | §2.3 creates a loop **on purpose** for a few seconds without STP — keep it to 5 s; worst case is a busy netlab-c until you remove it. |

## 1. Prerequisites

- Drill 02; Phase 2 lab 2.02 §2.3 if you've done it (same bridge VLAN commands).

```bash
cd ~/wb/phase1-ccna-drills/topo; containerlab deploy -t lan.clab.yml --reconfigure && bash lan-setup.sh
cd ../06-vlans-stp && bash vlans.sh
x() { docker exec clab-p1l-$1 sh -c "$2"; }
```

Read `vlans.sh` first: it's the configuration you'd type on two switches
and a router.

## 2. Hands-on

### 2.1 Access ports, trunks, tags

```bash
x sw1 'bridge vlan show'; x sw2 'bridge vlan show'
x h1 'ping -c2 10.0.10.3'                     # VLAN 10 across the trunk
x sw2 'tcpdump -nnei eth3 -c4 icmp' & sleep 1; x h1 'ping -c2 10.0.10.3 >/dev/null'; wait   # "vlan 10, p 0, ethertype IPv4"
x h1 'ping -c2 -W1 10.0.20.2'                 # VLAN 20: only via the router
x r1 'tcpdump -nnei eth1 -c4 icmp' & sleep 1; x h1 'ping -c2 10.0.20.2 >/dev/null'; wait    # in on vlan 10, out on vlan 20, same wire
```

Access port = one VLAN, untagged. Trunk = several VLANs, tagged with
802.1Q (4 bytes: TPID 0x8100 + 12-bit VLAN ID). The router-on-a-stick
routes between VLANs over a single trunk.

### 2.2 STP on a redundant link

Turn STP on **first**, make sw1 the root, then add the second link:

```bash
for s in sw1 sw2; do x $s 'ip link set br0 type bridge stp_state 1'; done
x sw1 'ip link set br0 type bridge priority 4096'          # lowest priority (+ MAC) = root bridge
for s in sw1 sw2; do x $s 'ip link set eth4 master br0; bridge vlan add dev eth4 vid 10; bridge vlan add dev eth4 vid 20; bridge vlan del dev eth4 vid 1'; done
sleep 35                                                    # listening → learning → forwarding: 2 × 15 s
x sw2 'bridge link'                                        # one of eth3/eth4 "blocking"
x sw2 'tcpdump -nnei eth4 -c2 stp'                          # BPDUs to 01:80:c2:00:00:00 from the root
```

Fail the active link and time the recovery:

```bash
x h1 'ping -i0.5 -c120 10.0.10.3' | tail -3 &
sleep 3; x sw1 'ip link set eth3 down'; wait
x sw1 'ip link set eth3 up'
```

Classic 802.1D (the Linux kernel's STP) takes 30–50 s. RSTP (802.1w,
`mstpd` in userspace on Linux) converges in about a second — which is
why every modern switch runs RSTP/MSTP.

### 2.3 Why STP exists (5 seconds, no more)

```bash
for s in sw1 sw2; do x $s 'ip link set br0 type bridge stp_state 0'; done
x h1 'arping -c1 -I eth1 10.0.10.3 >/dev/null' ; sleep 3
x sw1 'ip -s link show eth4 | sed -n 4p'                  # RX packets climbing by the thousand
for s in sw1 sw2; do x $s 'ip link set eth4 nomaster'; done   # break the loop NOW
```

One broadcast, looping forever between two switches: no TTL at L2. That's
a broadcast storm.

## 3. Verification

| Check | Expected |
|---|---|
| §2.1 | h1 ↔ h3 direct with `vlan 10` tags on the trunk; h1 → h2 only via r1, seen tagged 10 in and 20 out |
| §2.2 | one inter-switch port blocking; BPDUs every 2 s; recovery in tens of seconds after the link failure |
| §2.3 | counters explode while STP is off; they stop when eth4 leaves the bridges |

## 4. Break/fix

```bash
cd ~/wb/phase1-ccna-drills/06-vlans-stp && bash break.sh     # fresh lan + vlans.sh, then one change (no STP involved)
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

**Done when** `x h2 'ping -c2 10.0.20.4'` works and VLAN 10 still works.

Solution: [`solution.md`](solution.md).

## 5. Cleanup

```bash
containerlab destroy -t ~/wb/phase1-ccna-drills/topo/lan.clab.yml --cleanup
```

## 6. What I should be able to explain after this

- Access vs trunk ports, the 802.1Q tag, native/PVID VLAN, and why two hosts in the same subnet can't talk across VLANs without a router.
- STP elects a root (lowest bridge ID), blocks redundant ports, and reconverges slowly (802.1D) or fast (RSTP); without it, one broadcast loops forever.
- A VLAN missing from one end of a trunk silently partitions that VLAN only.
