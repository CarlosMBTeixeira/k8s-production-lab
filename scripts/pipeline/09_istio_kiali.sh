#!/bin/bash
# ============================================================================
# 09_istio_kiali.sh — Install Istio (sidecar mode + istio-cni) and Kiali via
# Helm from Artifact Hub (ADR-030), plus Bookinfo and a traffic generator so
# the mesh has something to show (ADR-038).
# ----------------------------------------------------------------------------
# Requires the observability stack (07_observability.sh): Kiali's traffic
# graph is built entirely from PromQL queries against the istio_* metrics in
# kube-prometheus-stack's Prometheus. Istio itself needs nothing; Kiali
# without Prometheus shows config but an empty graph. Grafana is not used.
#
# Same pattern as 06_argocd.sh / 07_observability.sh: pinned charts, values
# in kubernetes/manifests/<app>/, Kiali on its own Envoy Gateway (eg) with a
# self-signed cert generated at install time, tunnel script for Windows
# access. Kiali login is a short-lived ServiceAccount token printed at the
# end, never stored.
#
# Two Gateway API controllers coexist after this: Envoy Gateway (class eg,
# every lab UI including Kiali) and Istio (class istio, mesh ingress for
# Bookinfo only). Both use the Gateway API CRDs Envoy Gateway installed in
# 03_gateway_api_metallb.sh; Istio's base chart does not install them.
#
# Idempotent: safe to re-run.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ISTIO_DIR="${REPO_ROOT}/kubernetes/manifests/istio"
KIALI_DIR="${REPO_ROOT}/kubernetes/manifests/kiali"
BOOKINFO_DIR="${REPO_ROOT}/kubernetes/manifests/bookinfo"
NETPOL_FILE="${REPO_ROOT}/kubernetes/manifests/network_policies/monitoring-istio.yaml"
KUBECONFIG_LOCAL="${REPO_ROOT}/kubernetes/admin.conf"

ISTIO_CHART_VERSION="1.30.7"
KIALI_CHART_VERSION="2.33.0"      # Istio 1.30 needs Kiali >= 2.26 (kiali.io prerequisites)
ISTIO_NAMESPACE="istio-system"
BOOKINFO_NAMESPACE="bookinfo"
MONITORING_NAMESPACE="monitoring"
# Upstream Bookinfo at the same tag as the control plane (not vendored --
# same convention as MetalLB's bundle in 03_gateway_api_metallb.sh).
ISTIO_SAMPLES_URL="https://raw.githubusercontent.com/istio/istio/${ISTIO_CHART_VERSION}/samples"

source "${SCRIPT_DIR}/../lab-config.sh"

section() {
    echo ""
    echo "|---------------------------------------------------------------------------"
    echo "| $1"
    echo "|---------------------------------------------------------------------------"
}

fetch_kubeconfig() {
    section "Step 0/9: Fetching fresh kubeconfig from cp-1"
    scp -o StrictHostKeyChecking=no cp-1:~/.kube/config "${KUBECONFIG_LOCAL}"
    export KUBECONFIG="${KUBECONFIG_LOCAL}"
    kubectl get nodes
}

check_prerequisites() {
    section "Step 1/9: Checking prerequisites"
    local missing=false
    kubectl get namespace "${MONITORING_NAMESPACE}" >/dev/null 2>&1 \
        || { echo "  MISSING: namespace ${MONITORING_NAMESPACE}"; missing=true; }
    kubectl get crd podmonitors.monitoring.coreos.com >/dev/null 2>&1 \
        || { echo "  MISSING: PodMonitor CRD (Prometheus Operator)"; missing=true; }
    kubectl get service kube-prometheus-stack-prometheus -n "${MONITORING_NAMESPACE}" >/dev/null 2>&1 \
        || { echo "  MISSING: Service kube-prometheus-stack-prometheus"; missing=true; }
    kubectl get gatewayclass eg >/dev/null 2>&1 \
        || { echo "  MISSING: GatewayClass eg (03_gateway_api_metallb.sh)"; missing=true; }
    if [ "${missing}" = "true" ]; then
        echo "  ERROR: Kiali needs kube-prometheus-stack's Prometheus."
        echo "  Install the observability stack first: ./scripts/pipeline/07_observability.sh"
        exit 1
    fi
    echo "  Observability stack and Envoy Gateway present."

    # main.sh guards options 5 and 6 itself; this covers a standalone run.
    if [ "$(lab_workers)" -ne 1 ]; then
        echo "  NOTE: $(lab_topology_line)."
        echo "  Observability + mesh + Bookinfo is sized for one 8G worker (ADR-038)."
        echo "  Expect Pending pods on 2 x 4G; check 'kubectl get pods -A | grep -v Running'."
    fi
}

add_helm_repos() {
    section "Step 2/9: Adding Helm repos"
    helm repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null 2>&1 || true
    helm repo add kiali https://kiali.org/helm-charts >/dev/null 2>&1 || true
    helm repo update istio kiali
}

install_istio() {
    section "Step 3/9: Installing Istio ${ISTIO_CHART_VERSION} (base -> cni -> istiod)"
    # base: Istio CRDs + the default-revision validating webhook.
    helm upgrade --install istio-base istio/base \
        --version "${ISTIO_CHART_VERSION}" \
        -n "${ISTIO_NAMESPACE}" --create-namespace \
        --wait
    # cni before istiod, so the node agent is ready on every node before
    # the injector starts producing pods that rely on it.
    helm upgrade --install istio-cni istio/cni \
        --version "${ISTIO_CHART_VERSION}" \
        -n "${ISTIO_NAMESPACE}" \
        -f "${ISTIO_DIR}/cni-values.yaml" \
        --timeout 300s --wait
    helm upgrade --install istiod istio/istiod \
        --version "${ISTIO_CHART_VERSION}" \
        -n "${ISTIO_NAMESPACE}" \
        -f "${ISTIO_DIR}/istiod-values.yaml" \
        --timeout 300s --wait
    kubectl get gatewayclass
}

apply_monitors() {
    section "Step 4/9: Prometheus monitors for istiod and the sidecars"
    kubectl apply -f "${ISTIO_DIR}/monitors.yaml"
}

apply_network_policies() {
    section "Step 5/9: Network Policies (only if monitoring is default-deny)"
    if kubectl get networkpolicy default-deny-all -n "${MONITORING_NAMESPACE}" >/dev/null 2>&1; then
        kubectl apply -f "${NETPOL_FILE}"
    else
        echo "  No default-deny-all in ${MONITORING_NAMESPACE} (08 not applied) -- nothing to open, skipping."
    fi
}

install_kiali() {
    section "Step 6/9: Installing Kiali ${KIALI_CHART_VERSION}"
    helm upgrade --install kiali kiali/kiali-server \
        --version "${KIALI_CHART_VERSION}" \
        -n "${ISTIO_NAMESPACE}" \
        -f "${KIALI_DIR}/values.yaml" \
        --timeout 300s --wait
    kubectl apply -f "${KIALI_DIR}/kiali-login.yaml"
}

expose_kiali() {
    section "Step 7/9: Self-signed TLS + Gateway + HTTPRoute for Kiali"
    local tmpdir
    tmpdir="$(mktemp -d)"
    openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
        -keyout "${tmpdir}/tls.key" -out "${tmpdir}/tls.crt" \
        -subj "/CN=kiali.lab" -addext "subjectAltName=DNS:kiali.lab" >/dev/null 2>&1
    kubectl create secret tls kiali-tls -n "${ISTIO_NAMESPACE}" \
        --cert="${tmpdir}/tls.crt" --key="${tmpdir}/tls.key" \
        --dry-run=client -o yaml | kubectl apply -f -
    rm -rf "${tmpdir}"

    kubectl apply -f "${KIALI_DIR}/gateway-kiali.yaml"
    kubectl apply -f "${KIALI_DIR}/httproute-kiali.yaml"

    # Same clock-skew self-heal as 05/06: Envoy Gateway can latch the
    # listener as InvalidCertificateRef if it validates kiali-tls before
    # the VM clock reaches the cert's notBefore, and only re-checks on a
    # Secret change event. Nudge the Secret halfway through the wait.
    local addr=""
    for i in $(seq 1 30); do
        addr=$(kubectl get gateway/kiali -n "${ISTIO_NAMESPACE}" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
        [ -n "${addr}" ] && break
        if [ "${i}" -eq 15 ]; then
            echo "  Still no address -- nudging Secret/kiali-tls in case Envoy Gateway validated it before its notBefore time..."
            kubectl annotate secret kiali-tls -n "${ISTIO_NAMESPACE}" "reconcile-nudge=$(date -u +%s)" --overwrite >/dev/null
        fi
        sleep 2
    done
    if [ -z "${addr}" ]; then
        echo "  ERROR: Gateway never got an address. Check 'kubectl describe gateway/kiali -n ${ISTIO_NAMESPACE}'."
        exit 1
    fi
    echo "  Gateway/kiali address: ${addr}"
}

deploy_bookinfo() {
    section "Step 8/9: Bookinfo (injected) + Istio ingress Gateway + traffic generator"
    kubectl create namespace "${BOOKINFO_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
    kubectl label namespace "${BOOKINFO_NAMESPACE}" istio-injection=enabled --overwrite

    kubectl apply -n "${BOOKINFO_NAMESPACE}" -f "${ISTIO_SAMPLES_URL}/bookinfo/platform/kube/bookinfo.yaml"
    # Gateway (class istio) + HTTPRoute. istiod deploys
    # bookinfo-gateway-istio (Deployment + LoadBalancer Service) for it,
    # which takes a MetalLB address like any other Gateway.
    kubectl apply -n "${BOOKINFO_NAMESPACE}" -f "${ISTIO_SAMPLES_URL}/bookinfo/gateway-api/bookinfo-gateway.yaml"
    kubectl apply -f "${BOOKINFO_DIR}/traffic-generator.yaml"

    echo "  Waiting for Bookinfo deployments (first image pull is slow; reviews-* are Java)..."
    kubectl wait --for=condition=Available --timeout=600s -n "${BOOKINFO_NAMESPACE}" deployment --all

    echo "  Waiting for Gateway/bookinfo-gateway to be programmed..."
    kubectl wait --for=condition=Programmed --timeout=180s -n "${BOOKINFO_NAMESPACE}" gateway/bookinfo-gateway
    BOOKINFO_ADDR=$(kubectl get gateway/bookinfo-gateway -n "${BOOKINFO_NAMESPACE}" -o jsonpath='{.status.addresses[0].value}')
    echo "  Gateway/bookinfo-gateway address: ${BOOKINFO_ADDR}"
}

verify() {
    section "Step 9/9: Verifying"
    kubectl get pods -n "${ISTIO_NAMESPACE}"
    kubectl get pods -n "${BOOKINFO_NAMESPACE}"

    # Every Bookinfo pod must carry istio-proxy. With native sidecars it is
    # a restartable initContainer, otherwise a regular container -- check both.
    local unmeshed
    unmeshed=$(kubectl get pods -n "${BOOKINFO_NAMESPACE}" -l 'app in (productpage,details,ratings,reviews)' \
        -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.initContainers[*].name}{" "}{.spec.containers[*].name}{"\n"}{end}' \
        | grep -v 'istio-proxy' || true)
    if [ -n "${unmeshed}" ]; then
        echo "  ERROR: pods without a sidecar (injection did not happen):"
        echo "${unmeshed}" | sed 's/^/    /'
        exit 1
    fi
    echo "  All Bookinfo pods have an istio-proxy sidecar."

    # The chain Kiali depends on, end to end: generator -> mesh -> sidecar
    # metrics -> PodMonitor -> Prometheus. Non-fatal: a fresh scrape can
    # take a couple of intervals.
    echo "  Waiting for istio_requests_total to reach Prometheus (up to ~90s)..."
    # Through the API server's service proxy, not `kubectl exec ... wget`:
    # the Prometheus 3.x image ships no wget/curl (found 2026-10-23).
    local result=""
    for i in $(seq 1 18); do
        result=$(kubectl get --raw \
            "/api/v1/namespaces/${MONITORING_NAMESPACE}/services/kube-prometheus-stack-prometheus:http-web/proxy/api/v1/query?query=sum(istio_requests_total)" \
            2>/dev/null || true)
        echo "${result}" | grep -q '"value"' && break
        result=""
        sleep 5
    done
    if [ -n "${result}" ]; then
        echo "  Prometheus has mesh metrics: Kiali's graph will populate."
    else
        echo "  WARNING: no istio_requests_total in Prometheus yet. Check, in order:"
        echo "    kubectl logs -n ${BOOKINFO_NAMESPACE} deploy/traffic-generator --tail=5   (expect 200s)"
        echo "    Prometheus -> Status -> Targets -> podMonitor/istio-system/envoy-stats-monitor"
        echo "    kubectl get podmonitor -n ${ISTIO_NAMESPACE} --show-labels   (release=kube-prometheus-stack)"
    fi
}

print_access_instructions() {
    section "Done"
    echo "  Kiali:     ./scripts/tunnels/kiali-tunnel.sh     -> https://localhost:8446/"
    echo "  Login:     token from"
    echo "               kubectl -n ${ISTIO_NAMESPACE} create token kiali-login --duration 8h"
    echo "             (read-only, kiali-viewer ClusterRole)"
    echo "  Bookinfo:  ./scripts/tunnels/bookinfo-tunnel.sh  -> http://localhost:8447/productpage"
    echo "  Graph:     Kiali -> Traffic Graph -> namespace ${BOOKINFO_NAMESPACE}"
    echo "  Logs:      Grafana -> Explore -> Loki: {namespace=\"${BOOKINFO_NAMESPACE}\", container=\"istio-proxy\"}"
}

fetch_kubeconfig
check_prerequisites
add_helm_repos
install_istio
apply_monitors
apply_network_policies
install_kiali
expose_kiali
deploy_bookinfo
verify
print_access_instructions
