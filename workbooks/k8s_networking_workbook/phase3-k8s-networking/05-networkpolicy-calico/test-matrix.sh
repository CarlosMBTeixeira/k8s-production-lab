#!/usr/bin/env bash
# test-matrix.sh — who can reach what, as a grid. OK = got an HTTP answer,
# -- = timeout/refused/no DNS. Predict the grid before each run.
set -uo pipefail
API_IP=$(kubectl -n lab-np-back get svc api -o jsonpath='{.spec.clusterIP}')
SRC=(lab-np-front/frontend lab-np-front/stranger lab-np-other/outsider)
DST=("api.lab-np-back:80" "$API_IP:80" "db.lab-np-back:5432" "1.1.1.1:80")
LBL=("api (by name)" "api (by IP)" "db (by name)" "1.1.1.1 (egress)")
printf '%-24s' ""; for l in "${LBL[@]}"; do printf '%-18s' "$l"; done; echo
for s in "${SRC[@]}"; do
  ns=${s%/*}; pod=${s#*/}; printf '%-24s' "$s"
  for d in "${DST[@]}"; do
    code=$(kubectl -n "$ns" exec "$pod" -- curl -s -m2 -o /dev/null -w '%{http_code}' "http://$d/" 2>/dev/null)
    case "$code" in 2*|3*|4*) r=OK ;; *) r=-- ;; esac
    printf '%-18s' "$r"
  done; echo
done
