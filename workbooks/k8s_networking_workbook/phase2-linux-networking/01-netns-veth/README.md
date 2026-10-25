# Lab 2.01 — Network namespaces and veth pairs

| | |
|---|---|
| **Objective** | Build two isolated network stacks joined by a veth pair, and find any container's host-side veth from its PID. |
| **Time** | 3 h (week 1) |
| **Where** | netlab-a, root |
| **Risk** | Safe — namespaces only |

## 1. Prerequisites

- `setup/netlab.sh up` done; `multipass shell netlab-a`, `sudo -i`.
- Nothing else. This is the first lab.

## 2. Hands-on

### 2.1 An empty stack

```bash
ip netns add red
ip netns list                         # red
ls -l /run/netns/                     # a bind-mounted nsfs file — that is all a "named" netns is
ip netns exec red ip -br link         # only lo, and it is DOWN
ip netns exec red ping -c1 -W1 127.0.0.1   # fails: lo is down. Write down why before you fix it
ip -n red link set lo up
ip netns exec red ping -c1 127.0.0.1
ip netns exec red ip route            # empty: no interfaces, no routes
ip netns exec red iptables -S         # its own netfilter, empty
```

`ip -n red <cmd>` is shorthand for `ip netns exec red ip <cmd>`.

### 2.2 A wire between two stacks

```bash
ip netns add blue
ip link add veth-red type veth peer name veth-blue
ip -br link | grep veth               # both ends exist in the root ns, DOWN
ip link set veth-red netns red
ip link set veth-blue netns blue
ip -br link | grep veth               # gone from root

ip -n red  addr add 10.0.0.1/24 dev veth-red
ip -n blue addr add 10.0.0.2/24 dev veth-blue
ip -n red  link set veth-red up
ip -n blue link set veth-blue up
ip -n blue link set lo up

ip netns exec red ping -c3 10.0.0.2
```

Before the ping, write in the table below what `ip -n red neigh` will show
afterwards, and what `ip -n red route` shows now (hint: the `/24`).

### 2.3 Which end is which

```bash
ip -n red -d link show veth-red       # "veth-red@if<N>": N is the PEER's ifindex; "link-netns blue"
ip -n blue -o link | grep "^<N>:"     # confirm it's veth-blue
ip netns exec red ethtool -S veth-red # peer_ifindex: <N>
cat /sys/class/net/lo/iflink          # for a non-veth, iflink == ifindex
```

### 2.4 Processes and sockets live in a namespace

```bash
ip netns exec red python3 -m http.server 8080 >/dev/null 2>&1 &
ip netns pids red                     # the python PID
ss -ltn | grep 8080                   # root ns: nothing
ip netns exec red ss -ltnp            # there it is
ip netns exec blue curl -s 10.0.0.1:8080 | head -3
nsenter --target "$(ip netns pids red | head -1)" --net ss -ltn   # same view, by PID
ls -l /proc/"$(ip netns pids red | head -1)"/ns/net               # net:[inode] — compare with: ip netns identify <pid>
lsns -t net                           # every netns on the box, including ones `ip netns` can't see
```

### 2.5 Finding a container's host-side veth (what you do on a k8s node)

Container runtimes do **not** register their namespaces in `/run/netns`, so
`ip netns list` is empty on a Kubernetes node. You go via the PID. Simulate
an unnamed namespace with `unshare`:

```bash
unshare --net sleep 3600 &
PID=$!; sleep 0.5                     # unshare(2) on itself, then exec sleep: same PID, new netns
readlink /proc/$PID/ns/net /proc/self/ns/net   # two different net:[inode]s
ip link add host-side type veth peer name eth0 netns $PID
ip link set host-side up
nsenter -t $PID -n ip link set eth0 up
nsenter -t $PID -n ip -o link show eth0   # "eth0@if<M>": M = host-side's ifindex
ip -o link | grep "^M:"               # replace M: host-side. This is the k8s-node move
```

Careful: `nsenter -n` enters only the network namespace. `/sys` is still
the host's mount, so `nsenter -t $PID -n cat /sys/class/net/eth0/iflink`
reads the **host's** eth0 (or fails). Ask `ip`, which uses netlink inside
the namespace. Inside a container (`kubectl exec … cat
/sys/class/net/eth0/iflink`) it works because the container mounted its own sysfs.

On a k8s node the PID comes from `crictl inspect <ctr> | jq .info.pid`.

## 3. Verification

| Check | Expected |
|---|---|
| `ip netns exec red ping -c3 10.0.0.2` | 0 % loss |
| `ip -n red neigh` | `10.0.0.2 dev veth-red lladdr <mac> REACHABLE` (or STALE later) — `<mac>` equals `ip -n blue link show veth-blue` |
| `ip netns exec blue tcpdump -nni veth-blue -c4 icmp` during a ping | `echo request` and `echo reply` pairs |
| `ip -n red route` | `10.0.0.0/24 dev veth-red proto kernel scope link src 10.0.0.1` — created by the address, not by you |
| §2.5 | the `@if<M>` index matches `host-side`'s ifindex |

## 4. Break/fix

```bash
bash break.sh          # rebuilds red/blue, injects a fault, prints a ticket
```

Diagnose without reopening this README. Fill in before each command:

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

**Done when** `ip netns exec red ping -c3 10.0.0.2` succeeds and you can
name the one setting that was changed. Fix it in place, don't rebuild.

<details><summary>Hint (only after 20 minutes)</summary>

Which layer fails? Ask the neighbour table, then watch the wire from the
receiving side.
</details>

Solution: [`solution.md`](solution.md).

## 5. Cleanup

```bash
ip netns pids red | xargs -r kill; ip netns pids blue | xargs -r kill
ip netns del red; ip netns del blue
kill $PID; ip link del host-side 2>/dev/null   # new shell? pkill -f 'sleep 3600'
lsns -t net                           # only /sbin/init's netns left
```

Deleting a netns only removes the name; a process still inside keeps the
stack alive (and its veths). That is why the kills come first.

## 6. What I should be able to explain after this

- A network namespace is a full, separate stack: interfaces, addresses, routes, neighbour table, netfilter rules, sockets and sysctls under `net.*`. A process sees exactly one.
- A veth pair is a pipe: a frame sent into one end comes out the other. `@ifN` and `iflink` name the peer's ifindex, which is how you map a pod's `eth0` to its `cali…`/`lxc…`/`veth…` interface on the node.
- `ip netns` is a naming convenience over `/run/netns` bind mounts; runtimes skip it, so on a node you enter namespaces by PID (`nsenter -t <pid> -n`).
