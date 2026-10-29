# Troubleshooting playbook — Kubernetes networking incidents

A layer-by-layer checklist. Start at **0**, then go **down** the layers from
the symptom until one check fails. The first failing check is where you
dig; everything above it has been proven good.

Rewritten from memory in week 25 and diffed against this file. Every new
check comes from a runbook row — cite the lab in brackets.

---

## 0. Frame it (2 minutes, before touching anything)

- [ ] **Who → what → where.** Source (pod/node/external), destination
  (name, ClusterIP, pod IP, external IP), port, protocol. Write it down.
- [ ] **Scope.** One pod, one node, one namespace, everything? Same-node
  vs cross-node? Only new connections, or established ones too?
- [ ] **Shape of failure.** It decides the layer:

  | Symptom | Usually means | Go to |
  |---|---|---|
  | `could not resolve host` / NXDOMAIN / 5 s delays | DNS | 1 |
  | `connection refused` (RST) | something answered: no listener, no endpoints (kube-proxy REJECT), wrong port | 2 |
  | timeout, no RST | dropped: policy, route, firewall, MTU, conntrack | 3–6 |
  | small requests work, large ones hang | MTU / PMTUD | 5 |
  | intermittent, ~1 in N | one bad backend, one bad node, conntrack race, ECMP | 2, 6 |
  | works from node, fails from pod | policy, pod route, SNAT, rp_filter | 3, 4 |
  | works in cluster, fails from outside | LB / BGP / ARP / `externalTrafficPolicy` / Gateway | 7 |
  | TLS / HTTP errors (503, `upstream connect error`, handshake) | L7, mesh, certs, SNI | 9 |

- [ ] **What changed?** Deploys, policy changes, node adds, CNI/kube-proxy
  upgrades, MTU of the underlay, cloud firewall. `kubectl get events -A --sort-by=.lastTimestamp | tail -30`.
- [ ] **Reproduce from inside**, with the exact client: a netshoot pod in the
  source namespace, same labels if policies select on them.

```bash
kubectl -n <ns> run dbg --rm -it --image=nicolaka/netshoot:v0.13 --labels=<same-as-client> -- bash
```

---

## 1. Name resolution

- [ ] `dig +search +short <name>` from the pod. Then `dig @<coredns-pod-ip> <fqdn>` — bypasses the Service.
- [ ] `cat /etc/resolv.conf` in the pod: `nameserver` = kube-dns ClusterIP? `search` list and **`ndots:5`** → a name with < 5 dots tries every search domain first. [3.04]
- [ ] CoreDNS pods Ready, logs clean: `kubectl -n kube-system logs -l k8s-app=kube-dns --tail=50` (look for `loop`, `i/o timeout`, `SERVFAIL`).
- [ ] Policy allows **UDP and TCP 53** egress to kube-dns from the client namespace. [3.05]
- [ ] Upstream: Corefile `forward` target reachable from the CoreDNS pod; no loop back to itself via the node's `/etc/resolv.conf` (systemd-resolved `127.0.0.53`). [3.04]
- [ ] Intermittent 5 s delays on A+AAAA → conntrack race on parallel UDP queries (`insert_failed` counter). [2.06, 3.04]

## 2. Service → endpoints

- [ ] `kubectl get endpointslices -l kubernetes.io/service-name=<svc>` — empty = selector mismatch or no Ready pods.
- [ ] `port` vs `targetPort` vs container's listening port (`ss -ltnp` in the pod).
- [ ] Pod-IP direct works but ClusterIP doesn't → the datapath:
  - iptables: `iptables-save -t nat | grep <clusterIP>` → `KUBE-SVC-*` → `KUBE-SEP-*`. [3.02]
  - IPVS: `ipvsadm -Ln -t <clusterIP>:<port>`. [3.03]
  - nftables: `nft list table ip kube-proxy`. [3.03]
  - Cilium: `cilium-dbg service list`, `cilium-dbg bpf lb list`. [3.07]
  - OVN-K: `ovn-nbctl lb-list`. [3.10]
- [ ] kube-proxy / Cilium agent healthy on the **source** node (rules are programmed where the client is).
- [ ] `sessionAffinity`, `internalTrafficPolicy: Local` with no local endpoint, headless Service (no ClusterIP).
- [ ] Long-lived connections (gRPC, HTTP/2, DB pools) pinned to one backend → L4 balances connections, not requests. [4.06]

## 3. Policy

- [ ] `kubectl get networkpolicy -A` — any policy selecting the **destination** pod makes it default-deny for that direction; same for the **source** for egress.
- [ ] Egress policies forgot DNS. [3.05]
- [ ] Calico: `calicoctl get globalnetworkpolicy`, tiers and `order`; `kubectl get networkpolicies.projectcalico.org -A`. [3.05]
- [ ] Cilium: `hubble observe --verdict DROPPED --to-pod <ns>/<pod>` — names the policy verdict. [3.08]
- [ ] OVN-K/OpenShift: AdminNetworkPolicy / BaselineAdminNetworkPolicy evaluated **before** NetworkPolicy. [3.11]
- [ ] Mesh: `AuthorizationPolicy`, STRICT mTLS from a pod without a sidecar. [3.12]

## 4. Pod network on the node

- [ ] In the pod: `ip -br a`, `ip route` (Calico: default via `169.254.1.1`, answered by proxy-ARP on the host veth). [3.01]
- [ ] On the node: host-side veth exists and is UP; route to the pod IP points at it (`ip route get <podIP>`).
- [ ] `ip neigh` on both sides — `FAILED`/`INCOMPLETE` = L2 broken. [2.02]
- [ ] `sysctl net.ipv4.ip_forward` = 1; `rp_filter` not dropping asymmetric returns (`nstat -az | grep -i rpfilter`, `IPReversePathFilter`). [2.03]
- [ ] CNI binary and config present (`/opt/cni/bin`, `/etc/cni/net.d/` — first file wins, chaining order). Pod stuck `ContainerCreating` → `kubectl describe pod` shows the CNI error. [2.12]

## 5. Cross-node

- [ ] Same-node works, cross-node doesn't → overlay or underlay.
- [ ] Capture on the **underlay** NIC of both nodes:
  - IPIP: `tcpdump -ni ens3 ip proto 4` [3.01] · VXLAN: `udp port 4789` (Calico VXLAN, Linux default) / `8472` (Cilium, Flannel) [2.08] · Geneve: `udp port 6081` (OVN-K) [3.10]
  - Leaves node A, never reaches node B → underlay firewall / security group / wrong peer IP.
- [ ] **MTU**: pod MTU ≤ underlay MTU − encap overhead (IPIP 20, VXLAN 50, Geneve ≥ 50, WireGuard 60/80). `ping -M do -s <size>` between pods; large transfers hang after TLS ClientHello = classic. [2.09, 3.06]
- [ ] ICMP "frag needed" filtered somewhere → PMTUD blackhole. [2.09]
- [ ] Routed (BGP) mode: route to the remote pod CIDR present? `ip route | grep bird` / `birdcl show protocols` / `cilium bgp peers`. [4.03]

## 6. Node netfilter and conntrack

- [ ] `conntrack -S` — `insert_failed`, `drop`, `early_drop` rising. `sysctl net.netfilter.nf_conntrack_count net.netfilter.nf_conntrack_max`. `dmesg | grep 'table full'`. [2.06, 3.06]
- [ ] Stale UDP entry after a backend change (DNS to a dead CoreDNS pod IP): `conntrack -L -p udp --dport 53`. [2.06]
- [ ] `INVALID` drops (`iptables -L -v -n | grep INVALID`, `nf_conntrack_tcp_be_liberal`). [2.06]
- [ ] Which rule drops? `nft monitor trace` / `iptables -t raw -j TRACE`, or `pwru 'host <ip>'` for the kernel function that freed the skb. [2.04, 2.11]
- [ ] Someone else's rules: host firewall (ufw, firewalld), cloud agent, security tooling inserting before KUBE-* chains.

## 7. Edge: LoadBalancer, BGP, Gateway

- [ ] Service `EXTERNAL-IP` assigned? `kubectl describe svc` events (MetalLB pool exhausted, wrong `loadBalancerClass`).
- [ ] L2 (MetalLB/kube-vip): who answers ARP? `arping <LB-IP>` from the same L2; speaker logs; client's ARP cache stale after failover. [4.02]
- [ ] BGP: session `Established`? routes advertised/received (`show bgp ipv4 unicast`, `show bgp neighbor <ip> advertised-routes`). [4.01, 4.03]
- [ ] `externalTrafficPolicy: Local` → only nodes with a local endpoint answer; source IP preserved. `Cluster` → SNAT to node IP, extra hop. [3.02]
- [ ] Gateway API: `Gateway` `Programmed`, `HTTPRoute` `Accepted` + `ResolvedRefs` (`kubectl get httproute -o yaml | yq .status`). ReferenceGrant for cross-namespace backends. [3.09]

## 8. Egress to outside

- [ ] SNAT happens? Capture on the node's uplink: source is node IP (masquerade) or pod IP (routed, needs return route). [2.05]
- [ ] Calico `natOutgoing` on the IPPool; Cilium `enable-ipv4-masquerade`; OVN-K EgressIP assigned to which node. [3.11]
- [ ] Egress policy (`toFQDNs`, EgressFirewall) / proxy env vars.
- [ ] Upstream firewall only allows node IPs, but traffic leaves with an EgressIP — or the reverse.

## 9. L7, TLS, mesh

- [ ] `curl -v` / `openssl s_client -connect <host>:443 -servername <sni>` — cert chain, SNI, ALPN (`h2` vs `http/1.1`). [4.06]
- [ ] HTTP 503 with Envoy flags (`UF`, `UH`, `NR`, `URX`) → the flag names the layer. [3.12]
- [ ] Mesh: `istioctl proxy-status`, `istioctl x describe pod <pod>`; app port protocol detection (`appProtocol` / port name).
- [ ] HTTP/2 or gRPC: `GOAWAY`, max concurrent streams, idle timeouts on the LB shorter than the client keepalive.

---

## After the fix

- [ ] Prove it with the same command that showed the failure.
- [ ] Write the runbook row, especially **what would have told me this first**.
- [ ] If an alert could have caught it, write the PromQL. [4.07]
