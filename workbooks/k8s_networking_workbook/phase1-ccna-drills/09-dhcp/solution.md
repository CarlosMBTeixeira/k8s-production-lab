# Drill 09 — solution

## What was injected

<!--FAULT-->
```bash
bash "$LAB_DIR/topo.sh" up >/dev/null
# --- the fault: someone's test DHCP server on the same segment ---
ip netns add drog
ip link add p-drog netns dsw type veth peer name eth0 netns drog
ip -n dsw link set p-drog master br0 up; ip -n drog link set eth0 up; ip -n drog link set lo up
ip -n drog addr add 10.80.0.66/24 dev eth0
ip netns exec drog dnsmasq --interface=eth0 --bind-interfaces --port=0 --user=root --group=root --no-ping \
  --dhcp-range=10.80.0.200,10.80.0.220,255.255.255.0,2m \
  --dhcp-option=option:router,10.80.0.66 \
  --dhcp-leasefile=/var/tmp/drog.leases --pid-file=/var/tmp/drog.pid
cat <<T

TICKET  Clients on the 10.80.0.0/24 segment get a lease but can't reach
        the outside (10.81.0.1). It worked yesterday.
        Run a client several times:
          ip netns exec dcli busybox udhcpc -i eth0 -s $LAB_DIR/udhcpc-script.sh -f -q -n; ip netns exec dcli ping -c1 -W1 10.81.0.1
        The DHCP server (10.80.0.2) config hasn't changed.
T
```
<!--/FAULT-->

A second DHCP server (namespace `drog`, 10.80.0.66) answers on the same
segment, handing out 10.80.0.200–220 with **router 10.80.0.66** — which
doesn't route anywhere. Clients take whichever Offer arrives first; those
that pick the rogue get an address but no way out. Here the rogue wins
almost every run (10–11 of 12 on netlab-a): the bridge floods the Discover
to its newest port first, so the rogue hears it, and answers, a moment
earlier. On a real segment it's a race, and the symptom is "some clients".

| Beat | Answer |
|---|---|
| Hypothesis | "Got a lease, can't get out" → the lease itself is wrong. Read it: router and server-id should be 10.80.0.1 and 10.80.0.2. |
| Tool | `ip netns exec dsw tcpdump -nnvi br0 'port 67 or port 68'` during a client run |
| Expected if right | **two** Offers per Discover, from 10.80.0.2 and 10.80.0.66 (option 54), with different `yiaddr` and router options. |
| Tool 2 | the client script's output: `router=10.80.0.66 server=10.80.0.66` on the bad runs |
| What would have told me sooner | DHCP snooping (switch-side: only trusted ports may send Offers/ACKs), or simply alerting on more than one server-identifier seen on a segment. In VMs/labs: someone's "test" dnsmasq. |

## Fix

```bash
kill "$(cat /var/tmp/drog.pid)"; ip netns del drog
for i in $(seq 10); do ip netns exec dcli busybox udhcpc -i eth0 -s $PWD/udhcpc-script.sh -f -q -n | grep lease; ip netns exec dcli ping -c1 -W1 10.81.0.1 >/dev/null && echo ok; done
```
