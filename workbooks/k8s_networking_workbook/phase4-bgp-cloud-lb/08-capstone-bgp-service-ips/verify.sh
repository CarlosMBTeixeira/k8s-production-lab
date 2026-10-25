#!/usr/bin/env bash
# ============================================================================
# verify.sh — capstone 4.08 done-criteria as 10 checks. WSL host, context
# kind-lab-calico, lab-frr + lab-client running (lib/frr-kind.sh).
# ============================================================================
set -uo pipefail
export KUBECONFIG="$HOME/.kube/config" DATASTORE_TYPE=kubernetes
K="kubectl --context kind-lab-calico"
VIP=10.202.0.20
pass=0; fail=0
ok()  { echo "  PASS  $*"; pass=$((pass+1)); }
bad() { echo "  FAIL  $*"; fail=$((fail+1)); }
frr() { docker exec lab-frr vtysh -c "$1" 2>/dev/null; }

echo "| Capstone 4.08"
[ "$($K get nodes --no-headers | grep -cw Ready)" -eq 3 ] && ok "3 nodes Ready" || bad "3 nodes Ready"
[ "$(kubectl config current-context)" = kind-lab-calico ] || echo "  note  calicoctl reads the CURRENT context: kubectl config use-context kind-lab-calico"
m=$(calicoctl get bgpconfiguration default -o yaml 2>/dev/null | awk '/nodeToNodeMeshEnabled/{print $2}')
[ "$m" = false ] && ok "node-to-node mesh disabled" || bad "node-to-node mesh disabled (got '$m')"
rr=$($K get nodes -l route-reflector=true --no-headers 2>/dev/null | wc -l)
[ "$rr" -ge 1 ] && ok "$rr route reflector node(s)" || bad "a route reflector node"
est=$(frr 'show bgp summary json' | jq '[.ipv4Unicast.peers[] | select(.state=="Established")] | length' 2>/dev/null)
[ "${est:-0}" -eq 3 ] && ok "FRR: 3 Established sessions" || bad "FRR: 3 Established sessions (got ${est:-0})"
frr "show ip route $VIP" | grep -q "$VIP" && ok "FRR has a route to $VIP" || bad "FRR has a route to $VIP"
leak=$(frr 'show ip route bgp' | grep -c '10\.244\.')
[ "$leak" -eq 0 ] && ok "no pod CIDRs leaked into the fabric" || bad "no pod CIDRs in the fabric ($leak routes)"
r=$(docker exec lab-client curl -s -m3 http://$VIP/ 2>/dev/null)
echo "$r" | grep -q '^Hostname: web' && ok "lab-client reaches $VIP" || bad "lab-client reaches $VIP"
echo "$r" | grep -q 'RemoteAddr: 172.30.99.10' && ok "client IP preserved (172.30.99.10)" || bad "client IP preserved (got: $(echo "$r" | grep RemoteAddr))"
want=$($K -n lab-cap4 get pods -l app=web -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | wc -l)
got=$(frr "show ip route $VIP" | grep -c 'via ')
[ "$got" -eq "$want" ] && ok "ECMP paths = nodes with endpoints ($got)" || bad "ECMP paths ($got) = nodes with endpoints ($want)"
hold=$(frr 'show bgp neighbors json' | jq '[.[] | .bgpTimerHoldTimeMsecs] | max' 2>/dev/null)
[ "${hold:-999999}" -le 9000 ] && ok "hold time ≤ 9 s (${hold} ms)" || bad "hold time ≤ 9 s (${hold:-?} ms)"
echo "| $pass passed, $fail failed"
[ "$fail" -eq 0 ]
