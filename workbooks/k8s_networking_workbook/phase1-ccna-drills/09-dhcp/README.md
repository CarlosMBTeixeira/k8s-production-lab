# Drill 09 — DHCP

| | |
|---|---|
| **Objective** | Watch a client get an address with DHCP's four messages, read the options that configure it, see renewal, and know what a second DHCP server on the segment does. |
| **Time** | 1.5 h (week 6) · course: DHCP (+ DHCP snooping, as the reason for the break/fix) |
| **Where** | netlab-a, root |
| **Risk** | Safe — namespaces only; dnsmasq runs DHCP-only (`--port=0`, no DNS) |

## 1. Prerequisites

```bash
cd /workbook/phase1-ccna-drills/09-dhcp && bash topo.sh up
```

## 2. Hands-on

### 2.1 DORA

```bash
ip netns exec dsw tcpdump -nnvi br0 -c4 'port 67 or port 68' &
sleep 1
ip netns exec dcli busybox udhcpc -i eth0 -s $PWD/udhcpc-script.sh -f -q -n
wait
ip -n dcli -br addr; ip -n dcli route
ip netns exec dcli ping -c1 10.81.0.1
```

Read the four messages: **Discover** (from 0.0.0.0 to 255.255.255.255 —
the client has no address), **Offer** (server proposes `yiaddr`), **Request**
(broadcast, naming the chosen server in option 54 — so other servers know
they lost), **ACK**. Then the options: 1 (subnet mask), 3 (router), 6 (DNS),
51 (lease time), 54 (server identifier).

```bash
cat /var/tmp/dsrv.leases; tail -8 /var/tmp/dsrv.log
```

### 2.2 Renewal

The lease is 2 minutes, so renewal (T1) happens at ~1 minute:

```bash
ip netns exec dcli busybox udhcpc -i eth0 -s $PWD/udhcpc-script.sh -f -t 1 &     # keep running this time
sleep 3                                                     # let its own DORA finish first
ip netns exec dsw tcpdump -nnvi br0 -c2 'port 67 or port 68'   # waits ~1 min for T1
kill %1
```

Start the capture after the client has its lease: a fresh `udhcpc`
always begins with a full DORA, and `-c2` would stop on its Discover/Offer.
The renewal is a **unicast** Request/ACK straight to the server — no
broadcast. A client that can't reach its server at T1 keeps trying, then
broadcasts at T2 (87.5 %), and loses the address at expiry.

### 2.3 Across routers

Clients broadcast; routers don't forward broadcasts. A **relay** on the
client's router (`ip helper-address` on Cisco, `dhcrelay`/`dnsmasq --dhcp-relay`
on Linux) converts the broadcast into a unicast to the server, filling in
`giaddr` so the server picks the right pool. Note it; no relay in this drill.

## 3. Verification

| Check | Expected |
|---|---|
| §2.1 | Discover/Offer/Request/ACK; dcli gets 10.80.0.1xx/24 and a default route via 10.80.0.1; pings 10.81.0.1 |
| §2.2 | a unicast Request/ACK pair about a minute in: `10.80.0.1xx.68 > 10.80.0.2.67`, then the ACK back |

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

**Done when** ten runs of the ticket's command all get a lease from
10.80.0.2 and all reach 10.81.0.1.

Solution: [`solution.md`](solution.md).

## 5. Cleanup

```bash
bash topo.sh down
```

## 6. What I should be able to explain after this

- DORA: why Discover and Request are broadcasts, what each message carries, and the options that configure a host (1, 3, 6, 51, 54).
- Lease lifecycle: T1 unicast renew, T2 broadcast rebind, expiry; relays forward client broadcasts across routers using `giaddr`.
- A second DHCP server on the segment wins whenever it answers first; DHCP snooping on switches exists to stop exactly that.
