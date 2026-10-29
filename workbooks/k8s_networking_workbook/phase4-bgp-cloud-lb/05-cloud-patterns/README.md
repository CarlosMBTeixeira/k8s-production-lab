# Lab 4.05 — Cloud networking patterns, simulated

| | |
|---|---|
| **Objective** | Build hub-and-spoke transit, segment it, see why peering isn't transitive, carry traffic to a service through a private endpoint, and make hybrid DNS resolve it to the right address — each mapped to its Azure and AWS name. |
| **Time** | 5 h (week 21) |
| **Where** | netlab-c (Containerlab), root |
| **Risk** | Safe — containers on netlab-c |

You know Azure. The point here isn't the portal; it's the routing and DNS
mechanics underneath, so the next "private endpoint doesn't resolve from
on-prem" ticket is a five-minute one.

## 1. Prerequisites

- Lab 4.01; Phase 1 drill 08 (DNS); lab 3.04.

```bash
sudo -i
cp -r /workbook/phase4-bgp-cloud-lb ~/p4 2>/dev/null; cd ~/p4/05-cloud-patterns
containerlab deploy -t topo.clab.yml && bash post-deploy.sh
v() { docker exec clab-cloud-$1 vtysh -c "$2"; }
x() { docker exec clab-cloud-$1 sh -c "$2"; }
```

`post-deploy.sh` deletes the default route Containerlab gives every router
via its management `eth0`. Without that, a router with no route sends the
traffic into the Docker bridge, and `show ip route <anything>` answers with
`0.0.0.0/0`, which defeats §2.2 and §2.3. The management subnet
`172.20.20.0/24` also sits inside "on-prem" 172.20.0.0/16. It doesn't
collide with anything the lab uses, but don't be surprised by it in
`ip addr`.

## 2. Hands-on

### 2.1 Hub-and-spoke transit

```bash
v hub 'show bgp summary'                      # three spokes, Established
v hub 'show bgp ipv4 unicast'                 # 10.10/16, 10.20/16, 172.20/16
v ra  'show ip route bgp'
x a1 'curl -s -m3 10.20.1.10'                 # VPC-A → VPC-B via the hub: storage-b1
x o1 'traceroute -n -w1 10.10.1.10'           # on-prem → hub → VPC-A
```

Every spoke learns every other spoke through the hub: full transit, like a
Transit Gateway with one route table or a vWAN hub with default routing.

### 2.2 Segmentation: route tables

Production hubs don't let every spoke reach every other. Keep both VPCs
reaching on-prem, but not each other:

```bash
docker exec clab-cloud-hub vtysh -c 'conf t' \
  -c 'ip prefix-list NOT-VPC-B seq 5 deny 10.20.0.0/16' -c 'ip prefix-list NOT-VPC-B seq 10 permit 0.0.0.0/0 le 32' \
  -c 'ip prefix-list NOT-VPC-A seq 5 deny 10.10.0.0/16' -c 'ip prefix-list NOT-VPC-A seq 10 permit 0.0.0.0/0 le 32' \
  -c 'router bgp 65100' -c 'address-family ipv4 unicast' \
  -c 'neighbor 10.255.1.2 prefix-list NOT-VPC-B out' -c 'neighbor 10.255.2.2 prefix-list NOT-VPC-A out'
v hub 'clear bgp * soft out'; sleep 3
x a1 'curl -sS -m3 10.20.1.10 || echo BLOCKED' # curl: (7) Couldn't connect — ra has no route and answers ICMP net-unreachable (traceroute shows !N)
x a1 'ping -c1 -W1 172.20.1.10'                # on-prem still reachable
```

That's a TGW with per-attachment route tables (association/propagation),
or vWAN routing intent/custom route tables: segmentation by **what each
spoke is told**, not by a firewall.

### 2.3 Peering is not transitive

Peering, in cloud, is "each side gets a route to the other side's CIDR,
and that route is never re-advertised". The provider backbone between `pe`
and `rb` behaves the same way here: connected on both ends, announced by
neither.

```bash
v rb 'show ip route 10.99.0.0/30'      # connected on rb
v hub 'show ip route 10.99.0.1'        # no output: FRR prints nothing when no route matches — unknown to the hub
v op 'show ip route 10.99.0.1'         # no output either: unknown on-prem, nobody can transit through it
```

That's why "VPC-A peers with VPC-B and VPC-B peers with on-prem" doesn't
give VPC-A a path to on-prem: you need a hub (2.1) or explicit gateway
transit. Write the one-sentence version of this for your runbook: it's
asked in every cloud networking design review.

### 2.4 A private endpoint

The storage service lives in VPC-B, but VPC-A (still segmented from B!)
gets it at an address **inside its own range**: 10.10.3.10.

```bash
x a1 'curl -s -m3 10.10.3.10'                 # storage-b1 — through pe, not through the hub
x o1 'curl -s -m3 10.10.3.10'                 # on-prem too: 10.10.3.10 is inside VPC-A's aggregate
x pe 'iptables -t nat -S | grep -E "DNAT --to-destination 10.20|MASQUERADE"'   # what Private Link does, in two rules (the rest is Docker's embedded DNS)
docker logs clab-cloud-b1 2>&1 | tail -3      # the endpoint's requests all come from 10.99.0.1; only §2.1's direct curl shows a1 (10.10.1.10)
```

The provider sees every consumer as the endpoint's address: Private Link
hides consumer IPs and needs no routing between the networks at all.

### 2.5 Hybrid DNS

```bash
x a1 'dig +short storage.privatelink.lab'      # 10.10.3.10 — from the private zone linked to VPC-A
x a1 'dig +short app.corp.lab'                 # 172.20.1.10 — cloud resolver forwards corp.lab to on-prem (outbound rule)
x o1 'dig +short storage.privatelink.lab'      # 10.10.3.10 — on-prem forwards privatelink.lab to the inbound endpoint
x o1 'curl -s -m3 http://storage.privatelink.lab'
docker logs clab-cloud-dnsc 2>&1 | tail -5     # see o1's query arrive via the on-prem resolver
```

The only reason o1 gets the **private** answer is the conditional
forwarder on its resolver. Without it, the name resolves through "the
internet" to the public IP (203.0.113.10), which on-prem can't reach (or
reaches over the internet, bypassing the private path) — the most common
private-endpoint incident there is.

### 2.6 Overlap and more-specific hijack

```bash
docker exec clab-cloud-rb vtysh -c 'conf t' -c 'ip route 10.10.1.0/24 blackhole' -c 'router bgp 65102' -c 'address-family ipv4 unicast' -c 'network 10.10.1.0/24'
sleep 3; v op 'show ip route 10.10.1.10'      # longest prefix wins: on-prem now sends a1's traffic to VPC-B
x o1 'ping -c2 -W1 10.10.1.10 || echo HIJACKED'
docker exec clab-cloud-hub vtysh -c 'conf t' -c 'ip prefix-list FROM-VPC-B seq 5 permit 10.20.0.0/16' \
  -c 'router bgp 65100' -c 'address-family ipv4 unicast' -c 'neighbor 10.255.2.2 prefix-list FROM-VPC-B in'
v hub 'clear bgp 10.255.2.2 soft in'; sleep 3
x o1 'ping -c2 -W1 10.10.1.10'                 # fixed: the hub only accepts VPC-B's assigned range from VPC-B
docker exec clab-cloud-rb vtysh -c 'conf t' -c 'router bgp 65102' -c 'address-family ipv4 unicast' -c 'no network 10.10.1.0/24' -c 'exit' -c 'exit' -c 'no ip route 10.10.1.0/24 blackhole'
```

Accept from each attachment only what it owns. On-prem announcing a more
specific of a VNet/VPC range over ExpressRoute/Direct Connect pulls traffic
the same way.

### 2.7 The map

| In this lab | Azure | AWS |
|---|---|---|
| `hub`, its BGP sessions | Virtual WAN hub / hub VNet + Route Server | Transit Gateway |
| prefix-lists out per spoke (§2.2) | vWAN custom route tables / routing intent | TGW route tables: association + propagation |
| the unannounced backbone (§2.3) | VNet peering (non-transitive; "use remote gateways") | VPC peering (non-transitive) |
| `pe` DNAT + backbone (§2.4) | Private Endpoint (Private Link) | Interface VPC endpoint (PrivateLink) |
| `privatelink.lab` zone on dnsc | Private DNS zone `privatelink.*`, VNet link | Route 53 private hosted zone |
| dnsc answering on-prem | Private DNS Resolver **inbound** endpoint | Route 53 Resolver inbound endpoint |
| dnsc forwarding `corp.lab` | DNS forwarding ruleset (**outbound** endpoint) | Resolver outbound endpoint + rule |
| dnso `privatelink.lab` forward | on-prem conditional forwarder → inbound endpoint IP | same |
| prefix-list `FROM-VPC-B` (§2.6) | route maps on the hub / ER route filters | TGW prefix-list references |

## 3. Verification

| Check | Expected |
|---|---|
| §2.1 | a1 → b1 `storage-b1`; o1 traceroute via op, hub, ra |
| §2.2 | a1 → b1 `curl: (7)` + BLOCKED; a1 → o1 works |
| §2.3 | rb: 10.99.0.0/30 connected; hub and op: no output |
| §2.4 | a1 and o1 → 10.10.3.10 → `storage-b1` |
| §2.5 | both resolve `storage.privatelink.lab` to 10.10.3.10; a1 resolves `app.corp.lab` |
| §2.6 | HIJACKED, then fixed by the inbound prefix-list |

## 4. Break/fix

```bash
bash break.sh          # redeploys the lab (in your local copy), then "migrates" a DNS server
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

**Done when** `x o1 'curl -s -m3 http://storage.privatelink.lab'` prints
`storage-b1` and `x o1 'dig +short storage.privatelink.lab'` is 10.10.3.10.

<details><summary>Hint (only after 20 minutes)</summary>

The two clients get different answers for the same name. Ask each resolver
in the chain directly with `dig @<ip>`.
</details>

Solution: [`solution.md`](solution.md).

## 5. Cleanup

```bash
containerlab destroy -t topo.clab.yml --cleanup
rm -rf ~/p4/05-cloud-patterns && cp -r /workbook/phase4-bgp-cloud-lb/05-cloud-patterns ~/p4/   # fresh copy (break.sh edits dnso/Corefile)
```

## 6. What I should be able to explain after this

- Transit hubs (TGW, vWAN) are BGP route distribution with per-attachment route tables; peering is non-transitive because peering routes are never re-advertised; accept from each attachment only its own prefixes.
- A private endpoint is an address in the consumer's network that the provider plumbs to the service out-of-band; the provider sees the endpoint, not the consumer.
- Hybrid DNS for private endpoints: the private zone answers only resolvers linked to it; on-prem must conditionally forward the `privatelink` zone to an inbound endpoint, or it gets the public answer.
