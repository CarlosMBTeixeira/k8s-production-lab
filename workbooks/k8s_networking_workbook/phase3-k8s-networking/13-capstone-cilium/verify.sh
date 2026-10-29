#!/usr/bin/env bash
# ============================================================================
# verify.sh — capstone 3.13 done-criteria as 14 checks. Run from the WSL host
# with `cilium hubble port-forward &` running. Uses context kind-lab-cilium.
# ============================================================================
set -uo pipefail
export KUBECONFIG="$HOME/.kube/config"
K="kubectl --context kind-lab-cilium"
pass=0; fail=0
ok()  { echo "  PASS  $*"; pass=$((pass+1)); }
bad() { echo "  FAIL  $*"; fail=$((fail+1)); }
code() { $K -n "$1" exec "$2" -- curl -s -m4 -o /dev/null -w '%{http_code}' "${@:3}" 2>/dev/null; }
expect() { local want=$1 desc=$2; shift 2; local got; got=$(code "$@"); [ "$got" = "$want" ] && ok "$desc ($got)" || bad "$desc (got $got, want $want)"; }

echo "| Capstone 3.13"
[ "$($K get nodes --no-headers | grep -cw Ready)" -ge 3 ] && ok "3 nodes Ready" || bad "3 nodes Ready"
cilium --context kind-lab-cilium config view 2>/dev/null | grep -qE '^kube-proxy-replacement +true' && ok "kube-proxy replacement on" || bad "kube-proxy replacement on"
$K -n kube-system get ds kube-proxy >/dev/null 2>&1 && bad "no kube-proxy" || ok "no kube-proxy"

GW=$($K -n lab-cap get gateway app -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)
[ -n "$GW" ] && ok "Gateway lab-cap/app has an address ($GW)" || bad "Gateway lab-cap/app has an address"
r=$(curl -s -m4 -H 'Host: app.lab.local' "http://$GW/" 2>/dev/null)
echo "$r" | grep -q '^Hostname: frontend' && ok "app.lab.local → frontend from outside" || bad "app.lab.local → frontend from outside"
c=$(curl -s -m4 -o /dev/null -w '%{http_code}' -H 'Host: api.lab.local' "http://$GW/" 2>/dev/null)
[ "$c" = 404 ] && ok "api not exposed on the Gateway (404)" || bad "api not exposed on the Gateway (got $c)"

expect 200 "frontend tier → api GET"            lab-cap probe-frontend http://api.lab-cap/
expect 403 "frontend tier → api POST (L7 deny)" lab-cap probe-frontend -X POST http://api.lab-cap/
expect 000 "frontend tier → db denied"          lab-cap probe-frontend http://db.lab-cap:5432/
expect 200 "api tier → db"                      lab-cap probe-api      http://db.lab-cap:5432/
expect 000 "other namespace → api denied"       lab-cap-other probe-other http://api.lab-cap/
expect 200 "api tier → example.com"             lab-cap probe-api      http://example.com/
expect 000 "api tier → example.org denied"      lab-cap probe-api      http://example.org/

# Timed in bash: netshoot's /bin/sh is busybox, whose date has no %N.
slow=0
for i in $(seq 10); do
  t=$($K -n lab-cap exec probe-frontend -- bash -c 'S=${EPOCHREALTIME/./}; dig +short +time=2 +tries=1 api.lab-cap.svc.cluster.local >/dev/null; E=${EPOCHREALTIME/./}; echo $(( (E-S)/1000 ))' 2>/dev/null)
  [ "${t:-9999}" -gt 1000 ] && slow=$((slow+1))
done
[ "$slow" -eq 0 ] && ok "10/10 DNS lookups under 1 s" || bad "DNS: $slow/10 lookups over 1 s"

n=$(hubble observe -n lab-cap --verdict DROPPED --last 50 -o compact 2>/dev/null | wc -l)
[ "$n" -gt 0 ] && echo "  info  Hubble sees $n recent DROPPED flows in lab-cap (from the deny checks)" || echo "  info  Hubble: no DROPPED flows seen (is 'cilium hubble port-forward' running?)"
echo "| $pass passed, $fail failed"
[ "$fail" -eq 0 ]
