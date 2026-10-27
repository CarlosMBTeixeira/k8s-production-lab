# Lab 2.12 — Capstone: a mini-CNI across two hosts

| | |
|---|---|
| **Objective** | Write a working CNI plugin (bridge, IPAM, NAT) and connect pods across two hosts, first routed, then over VXLAN — what Flannel does, by hand. |
| **Time** | 9 h (week 8) |
| **Where** | netlab-a **and** netlab-b, root |
| **Risk** | Changes both VMs' root namespaces: `cni0`, routes, a VXLAN device, a NAT rule, `/etc/cni`, `/opt/cni`. Blast radius: these two VMs. Rollback: §5. |

## 1. Prerequisites

- Every Phase 2 lab, especially 2.02, 2.05, 2.08, 2.09.
- Both VMs up; `setup/netlab.sh env` run on the WSL host.
- Read the CNI spec's "Execution Protocol" and "Result" sections once
  (official: `github.com/containernetworking/cni/blob/main/SPEC.md`). That's
  the only reading in Phase 2.

What's in this folder:

| File | What |
|---|---|
| `skeleton/lab-cni` | **your plugin** — scaffolding plus 11 TODOs |
| `runtime.sh` | plays containerd: creates the netns, calls your plugin with the right env and stdin |
| `install.sh a\|b [plugin]` | copies a plugin to `/opt/cni/bin`, writes `/etc/cni/net.d/10-lab.conf` (A = 10.244.1.0/24, B = 10.244.2.0/24) |
| `verify.sh a\|b` | the done-criteria as 13 checks |
| `echo-server.py` | HTTP :8080 replying with the client IP it sees |
| `reference/` | a working plugin, `hostgw.sh` and `vxlan.sh`. **Closed until you're done or stuck 2 h.** |

Edit the skeleton on the WSL host (it's the mounted `/workbook`), run it in the VMs.

## 2. Hands-on — milestones

### M1 — ADD/DEL on one node (2 h)

Implement TODOs 1, 2, 4–10. (Untouched, the skeleton's ADD fails with
`no free addresses in 10.244.1.0/24`: that's TODO 4's stub, not a full
subnet.) Then on netlab-a:

```bash
cd /workbook/phase2-linux-networking/12-capstone-mini-cni
bash install.sh a
bash runtime.sh version
bash runtime.sh add pod1 && bash runtime.sh add pod1b
ip netns exec pod1 ping -c2 10.244.1.1
ip netns exec pod1 ping -c2 "$(ip -n pod1b -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1)"
tail -20 /var/log/lab-cni.log                      # your plugin's chatter
bash runtime.sh del pod1b; bash runtime.sh del pod1b   # the second DEL must also exit 0
```

If ADD fails, the runtime prints your error JSON. A plugin that writes
anything other than JSON to stdout breaks every real runtime — that's why
the skeleton sends everything else to the log.

### M2 — Egress (1 h)

TODO 3 (masquerade). `ip netns exec pod1 ping -c2 1.1.1.1` and
`ip netns exec pod1 getent hosts example.com` (runtime.sh wrote the pod's
`resolv.conf`, as a real runtime does from the result's `dns` or the node's file).

### M3 — Two nodes, routed (2 h)

On netlab-b: `bash install.sh b && bash verify.sh b` (creates pod2 =
10.244.2.2 with the echo server). On netlab-a nothing works across yet.
Add the routes yourself — each node needs a route to the **other** node's
pod CIDR via the other node's IP. Then from netlab-a:

```bash
ip netns exec pod1 curl -s 10.244.2.2:8080      # must print pod1's own IP, 10.244.1.2
```

If it prints A_IP instead, your masquerade rule is too broad. That's why
TODO 3 says "destination NOT the cluster CIDR": pod-to-pod traffic must keep
its source, or every NetworkPolicy and log on the other side sees the node.

### M4 — Two nodes, VXLAN (2 h)

Remove the routes. Build the Flannel model on both nodes: a VXLAN device
with `nolearning`, an address `10.244.N.0/32` on it, and for the remote node
a route (`via 10.244.P.0 dev <vxlan> onlink`), a permanent neighbour entry
and a permanent FDB entry (lab 2.08 §2.3). Pods now need MTU 1450:
`MTU=1450 bash install.sh a`, delete and re-add the pods (both nodes).

```bash
tcpdump -nni $(ip -o route show default | awk '{print $5}') udp port 8472 -c4   # inner 10.244.1.2 > 10.244.2.2
```

tcpdump decodes UDP/8472 as `OTV … instance 42` (OTV uses the same port):
"instance" is the VNI. `-T vxlan` makes it print `VXLAN … vni 42`.

Forget the MTU change once on purpose and watch `verify.sh`'s full-MTU check fail.

### M5 — Prove it (1 h)

```bash
# netlab-b
bash verify.sh b
# netlab-a
bash verify.sh a          # 13 checks
```

Then do it again from scratch on fresh VMs, no notes, against the clock —
that's the Phase 2 exit criterion (< 45 min).

## 3. Verification

`verify.sh a` prints `13 passed, 0 failed` in both M3 (routed) and M4
(VXLAN) modes. In VXLAN mode, an underlay capture shows UDP/8472 and no
direct 10.244.x.x packets on the uplink.

## 4. Break/fix

Needs pod1 on A and pod2 on B, in **routed** mode. If you finished in VXLAN
mode, switch back first (pods can keep MTU 1450):
`bash reference/vxlan.sh a down && bash reference/hostgw.sh a` on A, the same
with `b` on B, then `bash verify.sh a` → 13 passed.

Why not VXLAN: there the injected rule masquerades pod1 to the VTEP address
`10.244.1.0`, which is inside the cluster CIDR, so pod2's allowlist lets it
through and the ticket doesn't reproduce. `verify.sh` still fails (`pod2
sees '10.244.1.0'`). That's the overlay version of this bug: it hides from
firewalls and only shows up in the server's logs.

```bash
# netlab-b
bash break.sh b
# netlab-a
bash break.sh a        # prints the ticket
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

**Done when** `verify.sh a` passes again and you have removed exactly the
change that caused it.

<details><summary>Hint (only after 20 minutes)</summary>

"Rejected" means something decided based on who was asking. Find out who
pod2's node thinks is asking.
</details>

Solution: [`solution.md`](solution.md).

## 5. Cleanup

On each node (A shown; on B use `pod2` and side `b`):

```bash
for p in pod1 pod1b; do bash runtime.sh del $p 2>/dev/null; done
bash reference/vxlan.sh a down 2>/dev/null; bash reference/hostgw.sh a down
ip link del cni0 2>/dev/null
iptables-save -t nat | grep -v 'lab-cni' | iptables-restore -T nat
iptables-save -t filter | grep -v 'lab-cni' | iptables-restore -T filter
rm -rf /etc/cni/net.d/10-lab.conf /opt/cni/bin/lab-cni /var/lib/lab-cni /var/log/lab-cni.log
```

## 6. What I should be able to explain after this

- What a CNI plugin is: an executable called by the runtime with env vars and a JSON config, which creates the pod's interface, assigns IPAM, and prints a result; kubelet never runs it, the runtime does, using the first config file in `/etc/cni/net.d`.
- The two ways to connect pod CIDRs across nodes: routed (needs L2 adjacency or BGP to distribute routes) and encapsulated (VXLAN: route + permanent neighbour + FDB per remote node, and a 50-byte smaller MTU).
- Why pod egress is masqueraded only outside the cluster CIDR, and what breaks when it isn't (source IPs, NetworkPolicy, audit logs).
