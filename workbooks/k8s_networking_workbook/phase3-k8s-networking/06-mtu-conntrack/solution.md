# Lab 3.06 — solution

## What was injected

<!--FAULT-->
```bash
export KUBECONFIG="$WB_DIR/../../kubernetes/admin.conf"
kubectl apply -f "$LAB_DIR/apps.yaml" >/dev/null
kubectl -n lab-mtu wait --for=condition=Ready pod/client pod/server --timeout=120s >/dev/null
ip_of() { kubectl get node "$1" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'; }
W1=$(ip_of worker-1); W2=$(ip_of worker-2)
# --- the fault ---
for pair in "w-1 $W2" "w-2 $W1"; do
  set -- $pair
  ssh "$1" "sudo nft delete table inet lab-underlay 2>/dev/null; \
    sudo nft add table inet lab-underlay && \
    sudo nft add chain inet lab-underlay pre '{ type filter hook prerouting priority -300; policy accept; }' && \
    sudo nft add rule inet lab-underlay pre ip saddr $2 ip protocol 4 meta length gt 1400 drop"
  # GRO would merge wire packets into big skbs before netfilter sees them, and
  # the 1400 rule would then drop even correctly sized traffic. Off, so the
  # rule judges real wire packets, like a real link would.
  ssh "$1" 'sudo ethtool -K $(ip -o route show default | awk "{print \$5}") gro off'
done
cat <<'T'

TICKET  The network team moved the link between worker-1 and worker-2 onto a
        new encrypted underlay. Effective MTU is 1400 and that is final
        (nft table "inet lab-underlay" on both workers emulates it — leave it).
        Since then, between pods on those two nodes, small requests work but
        large responses hang:
          kubectl -n lab-mtu exec client -- curl -m10 -o /dev/null "http://<server pod IP>/data?size=5&unit=MB"
        Make it work without touching the underlay.
T
```
<!--/FAULT-->

Each worker drops IP-in-IP packets **from the other worker** whose IP length
exceeds 1400 bytes — a link that can't carry 1500 and doesn't send ICMP.
Pods use 1480, so a full-size pod packet becomes a 1500-byte IPIP packet
and vanishes. Small packets and same-node traffic are fine. The script also
turns GRO off on both uplinks, so the rule sees real wire-sized packets
instead of merged ones — a lab detail, not part of the fault.

## Diagnosis path

| Beat | Answer |
|---|---|
| Hypothesis | Small works, large hangs, cross-node only, no ICMP → path MTU between the two workers is below what the pods assume. |
| Tool | `$C ping -c1 -W1 -M do -s <N> $SRV` for N = 1452, 1400, 1380, 1352, 1353 |
| Expected if right | 1352 works, 1353 doesn't: inner 1352 + 28 = 1380, outer 1380 + 20 = 1400. Silence, not "Frag needed". |
| Tool 2 | `ssh w-1 sudo tcpdump -nni <uplink> ip proto 4 and greater 1400` on both workers during a download |
| Expected if right | big IPIP packets leave worker-2, arrive on worker-1's NIC (tap before netfilter), and are never answered. |
| Tool 3 | `ssh w-1 sudo nft list table inet lab-underlay` |
| Expected if right | the emulated link. It stays (the ticket says so): fix the overlay, not the underlay. |
| What would have told me sooner | A synthetic large-packet probe between nodes (`ping -M do -s <podMTU-28>` pod to pod, or blackbox ICMP with size) on every node pair. Calico's docs on MTU: the pod MTU must fit the **smallest** underlay path, and auto-detection only sees the local NIC. |

## Fix (RISKY — cluster-wide)

Pod MTU must be ≤ 1400 − 20 (IPIP) = 1380.

```bash
kubectl -n kube-system patch cm calico-config --type merge -p '{"data":{"veth_mtu":"1380"}}'
kubectl -n kube-system rollout restart ds/calico-node && kubectl -n kube-system rollout status ds/calico-node
ssh w-1 "ip -o link show tunl0 | grep -o 'mtu [0-9]*'"          # 1380 (FELIX_IPINIPMTU reads veth_mtu)
kubectl -n lab-mtu delete pod client server && kubectl apply -f apps.yaml
kubectl -n lab-mtu wait --for=condition=Ready pod/client pod/server
SRV=$(kubectl -n lab-mtu get pod server -o jsonpath='{.status.podIP}')
kubectl -n lab-mtu exec client -- ip link show eth0 | grep -o 'mtu [0-9]*'    # 1380
kubectl -n lab-mtu exec client -- curl -s -m10 -o /dev/null -w '%{http_code} %{size_download}\n' "http://$SRV/data?size=5&unit=MB"
```

Every existing pod keeps 1480 until it's recreated — a mixed-MTU cluster.
In production you'd roll every workload. Here, recreating the lab pods is enough.

## Full rollback (do this before the next lab)

```bash
for n in w-1 w-2; do
  ssh $n sudo nft delete table inet lab-underlay
  ssh $n 'sudo ethtool -K $(ip -o route show default | awk "{print \$5}") gro on'   # break.sh turned GRO off
done
kubectl -n kube-system patch cm calico-config --type merge -p '{"data":{"veth_mtu":"0"}}'
kubectl -n kube-system rollout restart ds/calico-node && kubectl -n kube-system rollout status ds/calico-node
kubectl delete ns lab-mtu
```

Pods created while the MTU was 1380 (if any outside `lab-mtu`) still have
it; the next full rebuild resets everything anyway.

## Why it matters later

On OpenShift this is `network.operator/cluster` → `spec.defaultNetwork.ovnKubernetesConfig.mtu`
with a documented MTU migration procedure, because changing it live is
exactly this mixed-MTU problem at scale.
