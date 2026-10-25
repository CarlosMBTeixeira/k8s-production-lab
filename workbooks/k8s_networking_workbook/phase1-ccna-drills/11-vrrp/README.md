# Drill 11 — First-hop redundancy with VRRP

| | |
|---|---|
| **Objective** | Give hosts a gateway that survives a router failure: two routers share a virtual IP with VRRP (keepalived), and you measure failover, gratuitous ARP and preemption. |
| **Time** | 1.5 h (week 7) · course: first-hop redundancy (HSRP/VRRP/GLBP — VRRP is the open standard) |
| **Where** | netlab-a, root |
| **Risk** | Safe — namespaces; keepalived runs inside them |

Why here: k8slab's API endpoint is a kube-vip virtual IP (ADR-021) and
MetalLB L2 (lab 4.02) is the same idea — an address that moves between
machines with ARP.

## 1. Prerequisites

```bash
cd /workbook/phase1-ccna-drills/11-vrrp && bash topo.sh up
```

## 2. Hands-on

### 2.1 Who owns the VIP

```bash
ip -n vA -br addr show eth0; ip -n vB -br addr show eth0     # 10.90.0.1 on vA (priority 150)
ip netns exec vh ping -c2 10.91.0.10
ip -n vh neigh show 10.90.0.1                                # the VIP's MAC = vA's real MAC
ip -n vA link show eth0 | grep -o 'link/ether [^ ]*'
ip netns exec vsw tcpdump -nni br0 -c3 vrrp                  # adverts from the master every second: vrid 51, prio 150
```

### 2.2 Failover

```bash
ip netns exec vh ping -i0.2 -c60 10.91.0.10 | tail -2 &
ip netns exec vsw tcpdump -nnei br0 -c4 'vrrp or arp' &
sleep 3; kill "$(cat /var/tmp/kA.pid)"                       # the master's keepalived dies
wait
ip -n vB -br addr show eth0                                  # VIP moved
ip -n vh neigh show 10.90.0.1                                # now vB's MAC — updated by gratuitous ARP
```

Count the lost pings: ~3–4 s = 3 missed adverts + skew. VRRP sends
**gratuitous ARP** from the new master so hosts update their cache
immediately instead of waiting for it to expire.

### 2.3 Preemption

```bash
ip netns exec vA keepalived -P -f /var/tmp/kA.conf -p /var/tmp/kA.pid -r /var/tmp/kA-vrrp.pid
sleep 3; ip -n vA -br addr show eth0                         # vA takes the VIP back: higher priority preempts
```

Preemption causes a second, avoidable blip. `nopreempt` (with `state
BACKUP` on both) keeps the VIP where it is until the next failure — usually
what you want for stateful things like an API endpoint.

## 3. Verification

| Check | Expected |
|---|---|
| §2.1 | VIP on vA; adverts `vrid 51 prio 150` each second |
| §2.2 | a few seconds of loss; VIP on vB; host's neighbour entry changes MAC; GARP in the capture |
| §2.3 | VIP back on vA |

## 4. Break/fix

```bash
bash break.sh
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

**Done when** exactly one router holds 10.90.0.1 and `ip netns exec vh ping
-c30 -i0.2 10.91.0.10` loses nothing — and killing the master still fails over.

Solution: [`solution.md`](solution.md).

## 5. Cleanup

```bash
bash topo.sh down
```

## 6. What I should be able to explain after this

- VRRP: the highest-priority router is master, owns the virtual IP, advertises to 224.0.0.18 (protocol 112) every advert interval; backups take over after ~3 missed adverts.
- Failover is visible to hosts only as a MAC change, which gratuitous ARP propagates; preemption is a choice.
- Two routers that don't hear each other (different VRID, filtered multicast, split L2) both become master — a duplicate IP.
