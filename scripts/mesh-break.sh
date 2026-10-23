#!/bin/bash
# ============================================================================
# mesh-break.sh — break the Istio mesh on purpose, for the troubleshooting
# session (workbooks/istio_svc_mesh_workbook/06-troubleshooting-lab.md).
# ----------------------------------------------------------------------------
# Each scenario prints only the SYMPTOM a user would report. Diagnose it
# from the cluster, not from this file: reading the scenario bodies below is
# reading the answer. Hints and solutions live in
# workbooks/istio_svc_mesh_workbook/06-troubleshooting-solutions.md.
#
#   mesh-break.sh list             symptoms for every scenario
#   mesh-break.sh break <n>        apply scenario n (1-10)
#   mesh-break.sh restore <n>      undo scenario n
#   mesh-break.sh restore all      undo everything this script can apply
#   mesh-break.sh check            is Bookinfo healthy right now?
#
# Every object this script creates carries the label mesh-break=<n>, so
# "restore all" can find them. Patches to existing objects are reverted
# explicitly. Requires the 09_istio_kiali.sh install (Bookinfo in
# namespace bookinfo, istiod in istio-system).
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-${REPO_ROOT}/kubernetes/admin.conf}"
NS=bookinfo
ISTIO_NS=istio-system

symptom() {
    case "$1" in
        1)  echo "About a third of product page loads say \"Ratings service is currently unavailable\". The rest look normal." ;;
        2)  echo "Every product page load says \"Error fetching product reviews\". Nobody changed the reviews code." ;;
        3)  echo "Product pages show reviews but never any stars: \"Ratings service is currently unavailable\" on every load." ;;
        4)  echo "Every product page load says \"Error fetching product details\"." ;;
        5)  echo "The page works, but Kiali shows the reviews edges as TCP and the reviews request-rate panels went flat." ;;
        6)  echo "The product page is unreachable from outside the mesh. Inside the cluster everything looks fine." ;;
        7)  echo "The site works perfectly, but nobody can change routing: 'kubectl apply' of any VirtualService fails, and a ratings rollout has been stuck for ages." ;;
        8)  echo "Reviews with stars have disappeared: \"Ratings service is currently unavailable\" on every page that should show them." ;;
        9)  echo "Kiali's traffic graph for bookinfo is empty, yet the generator logs show 200s every second." ;;
        10) echo "After a routine rollout, the new details pod never becomes Ready. The old pods were fine." ;;
        *)  echo "unknown scenario: $1" >&2; exit 1 ;;
    esac
}

apply() { kubectl apply -f - >/dev/null; }

break_scenario() {
    case "$1" in
        1)
            apply <<EOF
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata: {name: mesh-break-1, namespace: ${NS}, labels: {mesh-break: "1"}}
spec: {mtls: {mode: STRICT}}
EOF
            kubectl -n "${NS}" patch deploy reviews-v3 --type merge \
                -p '{"spec":{"template":{"metadata":{"labels":{"sidecar.istio.io/inject":"false"}}}}}' >/dev/null
            kubectl -n "${NS}" rollout status deploy/reviews-v3 --timeout=180s >/dev/null ;;
        2)
            apply <<EOF
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata: {name: mesh-break-2, namespace: ${NS}, labels: {mesh-break: "2"}}
spec:
  hosts: [reviews]
  http:
  - route:
    - destination: {host: reviews, subset: v2}
      weight: 50
    - destination: {host: reviews, subset: v3}
      weight: 50
EOF
            ;;
        3)
            apply <<EOF
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata: {name: mesh-break-3, namespace: ${NS}, labels: {mesh-break: "3"}}
spec:
  selector: {matchLabels: {app: ratings}}
  mtls: {mode: STRICT}
---
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata: {name: mesh-break-3, namespace: ${NS}, labels: {mesh-break: "3"}}
spec:
  host: ratings
  trafficPolicy: {tls: {mode: DISABLE}}
EOF
            ;;
        4)
            apply <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: {name: mesh-break-4, namespace: ${NS}, labels: {mesh-break: "4"}}
spec:
  selector: {matchLabels: {app: details}}
  action: ALLOW
  rules:
  - from:
    - source: {principals: ["cluster.local/ns/bookinfo/sa/bookinfo-productpge"]}
EOF
            ;;
        5)
            kubectl -n "${NS}" patch svc reviews --type json \
                -p '[{"op":"replace","path":"/spec/ports/0/name","value":"tcp"}]' >/dev/null ;;
        6)
            kubectl -n "${NS}" patch httproute bookinfo --type json \
                -p '[{"op":"replace","path":"/spec/parentRefs/0/name","value":"bookinfo-gw"}]' >/dev/null ;;
        7)
            kubectl -n "${ISTIO_NS}" scale deploy istiod --replicas=0 >/dev/null
            kubectl -n "${ISTIO_NS}" wait --for=delete pod -l app=istiod --timeout=120s >/dev/null 2>&1 || true
            kubectl -n "${NS}" rollout restart deploy/ratings-v1 >/dev/null ;;
        8)
            apply <<EOF
apiVersion: networking.istio.io/v1
kind: Sidecar
metadata: {name: mesh-break-8, namespace: ${NS}, labels: {mesh-break: "8"}}
spec:
  workloadSelector: {labels: {app: reviews}}
  egress:
  - hosts: ["./details.bookinfo.svc.cluster.local", "istio-system/*"]
  outboundTrafficPolicy: {mode: REGISTRY_ONLY}
EOF
            ;;
        9)
            kubectl -n "${ISTIO_NS}" label podmonitor envoy-stats-monitor release- >/dev/null ;;
        10)
            # stderr silenced: kubectl's deprecation warning names the object.
            kubectl -n "${ISTIO_NS}" patch ds istio-cni-node --type merge \
                -p '{"spec":{"template":{"spec":{"nodeSelector":{"mesh-break":"10"}}}}}' >/dev/null 2>&1
            kubectl -n "${ISTIO_NS}" wait --for=delete pod -l k8s-app=istio-cni-node --timeout=120s >/dev/null 2>&1 || true
            kubectl -n "${NS}" rollout restart deploy/details-v1 >/dev/null ;;
    esac
}

restore_scenario() {
    case "$1" in
        1)
            kubectl -n "${NS}" delete peerauthentication -l mesh-break=1 --ignore-not-found >/dev/null
            kubectl -n "${NS}" patch deploy reviews-v3 --type json \
                -p '[{"op":"remove","path":"/spec/template/metadata/labels/sidecar.istio.io~1inject"}]' >/dev/null 2>&1 || true
            kubectl -n "${NS}" rollout status deploy/reviews-v3 --timeout=180s >/dev/null ;;
        2|3|4|8)
            kubectl -n "${NS}" delete virtualservice,destinationrule,peerauthentication,authorizationpolicy,sidecar \
                -l mesh-break="$1" --ignore-not-found >/dev/null ;;
        5)
            kubectl -n "${NS}" patch svc reviews --type json \
                -p '[{"op":"replace","path":"/spec/ports/0/name","value":"http"}]' >/dev/null ;;
        6)
            kubectl -n "${NS}" patch httproute bookinfo --type json \
                -p '[{"op":"replace","path":"/spec/parentRefs/0/name","value":"bookinfo-gateway"}]' >/dev/null ;;
        7)
            kubectl -n "${ISTIO_NS}" scale deploy istiod --replicas=1 >/dev/null
            kubectl -n "${ISTIO_NS}" rollout status deploy/istiod --timeout=180s >/dev/null
            # A pod the webhook rejected while istiod was down never got
            # created; restarting makes the ReplicaSet try again.
            kubectl -n "${NS}" rollout restart deploy/ratings-v1 >/dev/null
            kubectl -n "${NS}" rollout status deploy/ratings-v1 --timeout=180s >/dev/null ;;
        9)
            kubectl -n "${ISTIO_NS}" label podmonitor envoy-stats-monitor release=kube-prometheus-stack --overwrite >/dev/null ;;
        10)
            kubectl -n "${ISTIO_NS}" patch ds istio-cni-node --type json \
                -p '[{"op":"remove","path":"/spec/template/spec/nodeSelector/mesh-break"}]' >/dev/null 2>&1 || true
            kubectl -n "${ISTIO_NS}" rollout status ds/istio-cni-node --timeout=180s >/dev/null
            kubectl -n "${NS}" rollout restart deploy/details-v1 >/dev/null
            kubectl -n "${NS}" rollout status deploy/details-v1 --timeout=180s >/dev/null ;;
    esac
}

# Fetch the product page through the ingress gateway from inside the
# cluster and report what a user would see. 10 loads, because reviews
# rotates between three versions.
check() {
    local gen out
    gen=$(kubectl -n "${NS}" get pod -l app=traffic-generator -o jsonpath='{.items[0].metadata.name}')
    out=$(kubectl -n "${NS}" exec "${gen}" -- sh -c '
        for i in 1 2 3 4 5 6 7 8 9 10; do
          body=$(curl -s -w "\nHTTP:%{http_code}" http://bookinfo-gateway-istio.bookinfo.svc.cluster.local/productpage)
          code=${body##*HTTP:}
          case "$body" in
            *"Error fetching product details"*) d=ERR ;; *) d=ok ;; esac
          case "$body" in
            *"Error fetching product reviews"*) r=ERR ;; *) r=ok ;; esac
          case "$body" in
            *"Ratings service is currently unavailable"*) s=unavailable ;;
            *glyphicon-star*) s=stars ;; *) s=none ;; esac
          echo "http=$code details=$d reviews=$r ratings=$s"
        done' 2>/dev/null)
    echo "${out}" | sort | uniq -c
}

usage() { sed -n '9,15p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

case "${1:-}" in
    list)
        for n in $(seq 1 10); do printf "%2d) %s\n" "$n" "$(symptom "$n")"; done ;;
    break)
        [ -n "${2:-}" ] || usage
        symptom "$2" >/dev/null
        break_scenario "$2"
        echo "Scenario $2 applied. Reported symptom:"
        echo "  $(symptom "$2")"
        echo "Restore with: $0 restore $2" ;;
    restore)
        [ -n "${2:-}" ] || usage
        if [ "$2" = "all" ]; then
            for n in $(seq 1 10); do restore_scenario "$n"; done
            echo "All scenarios restored."
        else
            symptom "$2" >/dev/null
            restore_scenario "$2"
            echo "Scenario $2 restored."
        fi ;;
    check)
        check ;;
    *)
        usage ;;
esac
