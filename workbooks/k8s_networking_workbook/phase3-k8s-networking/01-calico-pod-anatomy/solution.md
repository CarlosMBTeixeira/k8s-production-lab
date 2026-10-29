# Lab 3.01 — solution

## What was injected

<!--FAULT-->
```bash
export KUBECONFIG="$WB_DIR/../../kubernetes/admin.conf"
kubectl apply -f "$LAB_DIR/pods.yaml" >/dev/null
kubectl -n lab-anatomy wait --for=condition=Ready pod --all --timeout=120s >/dev/null
# --- the fault ---
ssh w-2 "sudo nft delete table inet lab-fw 2>/dev/null; \
  sudo nft add table inet lab-fw && \
  sudo nft add chain inet lab-fw pre '{ type filter hook prerouting priority -300; policy accept; }' && \
  sudo nft add rule inet lab-fw pre ip protocol 4 drop"
cat <<'T'

TICKET  Pods on worker-2 stopped answering anything from other nodes after
        "the security team rolled out the node firewall baseline".
          kubectl -n lab-anatomy exec client -- curl -m3 <server-remote IP>   → timeout
        Same-node traffic is fine; worker-1 and worker-2 ping each other;
        every calico-node pod is Running and Ready.
T
```
<!--/FAULT-->

An nftables table on worker-2 drops IP protocol 4 (IP-in-IP) at
prerouting. The routes stay (Felix programs them from the datastore), BGP
(TCP 179) stays Established and calico-node stays Ready; only the
encapsulated data dies. This is what a
cloud security group or an on-prem firewall that allows "TCP/UDP between
nodes" but not protocol 4 looks like.

## Diagnosis path

| Beat | Answer |
|---|---|
| Hypothesis | Same-node works and cross-node to one node fails → overlay or underlay into worker-2, not the pods. |
| Tool | `ssh w-1 sudo tcpdump -nni $UP ip proto 4` and the same on w-2, during a ping from client to server-remote |
| Expected if right | requests leave w-1 encapsulated; they **arrive** on w-2's NIC (the tap is before netfilter); no reply leaves w-2. |
| Tool 2 | `ssh w-2 sudo nft list tables`, then `sudo nft list table <the odd one>` |
| Expected if right | `table inet lab-fw` next to Calico's and iptables-nft's tables; inside it, `ip protocol ipencap drop` (nft names protocol 4 `ipencap`, so grepping for "protocol 4" finds nothing, and "ipencap" also hits Calico's own rules). |
| What would have told me sooner | Calico's own docs list the required underlay openings (BGP TCP 179; IPIP = IP protocol 4; VXLAN UDP 4789). An "Established BGP + no data" state is the signature of a firewall that knows TCP/UDP ports but not IP protocols. A node-to-node pod-ping probe (e.g. a DaemonSet blackbox check) catches it before users do. |

## Fix

```bash
ssh w-2 sudo nft delete table inet lab-fw
kubectl -n lab-anatomy exec client -- curl -s -m3 "$REMOTE" | head -3
```

## Why it matters later

The same check applies to every CNI: Cilium VXLAN (UDP 8472), Geneve for
OVN-K (UDP 6081), WireGuard (UDP 51871 for Cilium, 51820 for Calico).
"Allowed the ports" is not the same as "allowed the protocol".
