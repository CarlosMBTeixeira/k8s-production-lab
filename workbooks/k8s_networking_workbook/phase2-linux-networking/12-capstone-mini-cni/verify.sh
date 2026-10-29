#!/usr/bin/env bash
# ============================================================================
# verify.sh — capstone 2.12 done-criteria, as checks.
#   netlab-b:  bash verify.sh b    ensure pod2 exists, start the echo server in it
#   netlab-a:  bash verify.sh a    run every check from pod1 (and pod1b) on A
# Assumes each host's first pod got .2: pod1 = 10.244.1.2, pod2 = 10.244.2.2.
# ============================================================================
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RT="bash $DIR/runtime.sh"
pass=0; fail=0
ok()  { echo "  PASS  $*"; pass=$((pass+1)); }
bad() { echo "  FAIL  $*"; fail=$((fail+1)); }
chk() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
has_ns() { ip netns list | grep -qw "$1"; }

case "${1:-}" in
b)
    has_ns pod2 || $RT add pod2
    ip netns pids pod2 | xargs -r kill 2>/dev/null || true
    setsid ip netns exec pod2 python3 "$DIR/echo-server.py" >/dev/null 2>&1 < /dev/null &
    sleep 1
    echo "pod2: $(ip -n pod2 -4 -o addr show dev eth0 | awk '{print $4}') — echo server on :8080"
    ;;
a)
    echo "| Capstone 2.12 checks"
    chk "VERSION returns supportedVersions" bash -c "$RT version | jq -e '.supportedVersions | index(\"1.0.0\")'"
    has_ns pod1  || $RT add pod1  >/dev/null
    has_ns pod1b || $RT add pod1b >/dev/null
    P1=$(ip -n pod1  -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    P1B=$(ip -n pod1b -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    [ -n "$P1" ] && [ -n "$P1B" ] && [ "$P1" != "$P1B" ] && ok "two pods, distinct IPs ($P1, $P1B)" || bad "two pods with distinct IPs"
    chk "CHECK passes on pod1" $RT check pod1
    chk "pod1 → gateway 10.244.1.1"   ip netns exec pod1 ping -c1 -W1 10.244.1.1
    chk "pod1 → pod1b (same node)"    ip netns exec pod1 ping -c1 -W1 "$P1B"
    chk "pod1 → 1.1.1.1 (egress NAT)" ip netns exec pod1 ping -c1 -W2 1.1.1.1
    chk "pod1 → DNS name (resolv.conf)" ip netns exec pod1 getent hosts example.com
    chk "pod1 → pod2 10.244.2.2 (cross node)" ip netns exec pod1 ping -c1 -W1 10.244.2.2
    seen=$(ip netns exec pod1 curl -s -m3 10.244.2.2:8080)
    [ "$seen" = "$P1" ] && ok "pod2 sees pod1's own IP ($seen) — no SNAT inside the cluster" \
                        || bad "pod2 sees '$seen', expected $P1"
    big=$(ip netns exec pod1 ping -c1 -W1 -M do -s $(( $(ip -n pod1 -j link show eth0 | jq '.[0].mtu') - 28 )) 10.244.2.2 >/dev/null 2>&1 && echo y)
    [ "$big" = y ] && ok "full-MTU ping with DF to pod2" || bad "full-MTU ping with DF to pod2 (pod MTU vs path MTU?)"
    HIF=veth$(printf %s pod1b | sha256sum | cut -c1-8)
    $RT del pod1b >/dev/null 2>&1
    ! ip link show "$HIF" >/dev/null 2>&1 && ok "DEL removed the host veth" || bad "DEL left $HIF behind"
    ! grep -rqx "$(printf %s pod1b | sha256sum | cut -c1-16)" /var/lib/lab-cni 2>/dev/null && ok "DEL released the IP" || bad "DEL left the IP allocated"
    chk "DEL is idempotent (second DEL exits 0)" env CNI_COMMAND=DEL CNI_CONTAINERID="$(printf %s pod1b | sha256sum | cut -c1-16)" \
        CNI_NETNS=/run/netns/pod1b CNI_IFNAME=eth0 CNI_PATH=/opt/cni/bin bash -c '/opt/cni/bin/lab-cni < /etc/cni/net.d/10-lab.conf'
    echo "| $pass passed, $fail failed"
    [ "$fail" -eq 0 ]
    ;;
*) echo "usage: $0 a|b"; exit 1 ;;
esac
