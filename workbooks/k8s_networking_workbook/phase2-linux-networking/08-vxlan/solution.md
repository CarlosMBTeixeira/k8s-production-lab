# Lab 2.08 — solution

## What was injected

<!--FAULT-->
```bash
SIDE="${1:?usage: break.sh a|b}"
source "$WB_DIR/setup/netlab.env"
UP=$(ip -o route show default | awk '{print $5}')
case "$SIDE" in
  a) ME=$A_IP PEER=$B_IP N=1 ;;
  b) ME=$B_IP PEER=$A_IP N=2 ;;
  *) echo "usage: break.sh a|b"; exit 1 ;;
esac
ip netns del pod 2>/dev/null || true
ip link del vx100 2>/dev/null || true
ip link del br-vx 2>/dev/null || true
if [ "$SIDE" = a ]; then
  ip link add vx100 type vxlan id 100 dstport 4789 local $ME remote $PEER dev $UP
else
  # --- the fault ---
  ip link add vx100 type vxlan id 100 local $ME remote $PEER dev $UP 2>/dev/null
fi
ip link add br-vx type bridge
ip link set vx100 master br-vx mtu 1450
ip link set vx100 up; ip link set br-vx up
ip netns add pod
ip link add vpod type veth peer name eth0 netns pod
ip link set vpod master br-vx up
ip -n pod addr add 10.200.0.$N/24 dev eth0
ip -n pod link set eth0 mtu 1450 up; ip -n pod link set lo up
if [ "$SIDE" = a ]; then
  echo "side A ready (pod 10.200.0.1). Now run 'bash break.sh b' on netlab-b."
else
cat <<'T'

TICKET  netlab-b was re-provisioned by a colleague from "the same runbook".
        Since then, pod 10.200.0.1 (on netlab-a) and pod 10.200.0.2 (on
        netlab-b) can't ping each other. Both VMs reach each other fine
        (ping A_IP <-> B_IP works). The pod config is identical on both.
T
fi
```
<!--/FAULT-->

Side B's VXLAN device was created **without `dstport`**. iproute2 warns and
the kernel uses the Linux default **8472**, not IANA's 4789. A sends to
B:4789, where nothing listens; B sends to A:8472, where nothing listens.
Each host answers the other with ICMP port unreachable.

## Diagnosis path

| Beat | Answer |
|---|---|
| Hypothesis | Pod side is fine on both hosts (same subnet, links up); the tunnel itself doesn't deliver. |
| Tool | On both hosts: `tcpdump -nni $UP 'host <peer> and (udp or icmp)'` while pinging |
| Expected if right | A: out `→ B.4789`, in `B → A.8472` and `ICMP … udp port 4789 unreachable` from B. B: the mirror image. |
| Tool 2 | `ip -d link show vx100` on both; `ss -lun \| grep -E '4789\|8472'` |
| Expected if right | `dstport 4789` on A, `dstport 8472` on B. |
| What would have told me sooner | ICMP port unreachable **about a tunnel port** in an underlay capture. And mixed-CNI or mixed-version clusters: Flannel/Cilium default to 8472, Calico VXLAN and most hardware VTEPs to 4789. Any cloud security group allowing only one of them gives the same one-way picture. |

## Fix (on netlab-b)

```bash
source /workbook/setup/netlab.env; UP=$(ip -o route show default | awk '{print $5}')
ip link del vx100
ip link add vx100 type vxlan id 100 dstport 4789 local $B_IP remote $A_IP dev $UP
ip link set vx100 master br-vx mtu 1450 up
```

## Why it matters later

Lab 3.07 (Cilium) uses 8472 and lab 3.01 (Calico) uses IP-in-IP. A firewall
change that allows "VXLAN" (4789) but not 8472 is a real outage pattern
when someone switches CNI or tunnel mode.
