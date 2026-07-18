#!/bin/bash
# ============================================================================
# 04_rancher.sh — Install Rancher 2.14.3, exposed via a dedicated Gateway
# API resource (Gateway/rancher + HTTPRoute/rancher, kubernetes/manifests/rancher/).
# ----------------------------------------------------------------------------
# See ADR-026 for why Rancher gets its own Gateway instead of reusing
# Gateway/eg from 03_gateway_api_metallb.sh.
#
# TLS: self-signed cert generated fresh in a temp dir on every run, loaded
# into Secret/rancher-tls, never written to git. Same principle as
# ADR-024 (never trust/persist generated credentials).
#
# Idempotent: safe to re-run after a cluster rebuild.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RANCHER_DIR="${REPO_ROOT}/kubernetes/manifests/rancher"
KUBECONFIG_LOCAL="${REPO_ROOT}/kubernetes/admin.conf"

RANCHER_NAMESPACE="cattle-system"
RANCHER_HOSTNAME="rancher.lab"
RANCHER_CHART_VERSION="2.14.3"

section() {
    echo
    echo "============================================================"
    echo "  $1"
    echo "============================================================"
}

fetch_kubeconfig() {
    section "Step 0/6: Fetching fresh kubeconfig from cp-1"
    scp -o StrictHostKeyChecking=no cp-1:~/.kube/config "${KUBECONFIG_LOCAL}"
    export KUBECONFIG="${KUBECONFIG_LOCAL}"
    kubectl get nodes
}

create_namespace() {
    section "Step 1/6: Creating namespace ${RANCHER_NAMESPACE}"
    kubectl create namespace "${RANCHER_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
}

generate_tls_secret() {
    section "Step 2/6: Generating self-signed TLS cert for ${RANCHER_HOSTNAME}"
    local tmpdir
    tmpdir="$(mktemp -d)"
    openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
        -keyout "${tmpdir}/tls.key" -out "${tmpdir}/tls.crt" \
        -subj "/CN=${RANCHER_HOSTNAME}" \
        -addext "subjectAltName=DNS:${RANCHER_HOSTNAME}"

    kubectl create secret tls rancher-tls \
        -n "${RANCHER_NAMESPACE}" \
        --cert="${tmpdir}/tls.crt" --key="${tmpdir}/tls.key" \
        --dry-run=client -o yaml | kubectl apply -f -

    rm -rf "${tmpdir}"
    echo "  Cert generated and loaded into Secret/rancher-tls (not written to git)"
}

apply_gateway_and_route() {
    section "Step 3/6: Applying Gateway + HTTPRoute"
    kubectl apply -f "${RANCHER_DIR}/gateway-rancher.yaml"
    kubectl apply -f "${RANCHER_DIR}/httproute-rancher.yaml"

    echo "  Waiting for Gateway/rancher to get a MetalLB address..."
    for i in $(seq 1 30); do
        ADDR=$(kubectl get gateway/rancher -n "${RANCHER_NAMESPACE}" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
        [ -n "${ADDR}" ] && break
        sleep 2
    done

    if [ -z "${ADDR:-}" ]; then
        echo "  ERROR: Gateway never got an address. Check 'kubectl describe gateway/rancher -n ${RANCHER_NAMESPACE}'."
        exit 1
    fi
    echo "  Gateway address: ${ADDR}"
}

install_rancher() {
    section "Step 4/6: Installing Rancher ${RANCHER_CHART_VERSION} via Helm"
    helm repo add rancher-stable https://releases.rancher.com/server-charts/stable >/dev/null 2>&1 || true
    helm repo update

    read -r -s -p "  Choose a Rancher bootstrap password (min 12 chars, not stored anywhere): " BOOTSTRAP_PASSWORD
    echo

    helm upgrade --install rancher rancher-stable/rancher \
        --version "${RANCHER_CHART_VERSION}" \
        --namespace "${RANCHER_NAMESPACE}" \
        --set hostname="${RANCHER_HOSTNAME}" \
        --set networkExposure.type=none \
        --set tls=ingress \
        --set ingress.tls.source=secret \
        --set bootstrapPassword="${BOOTSTRAP_PASSWORD}"

    echo "  Waiting for Rancher deployment to become Available (can take a few minutes on first pull)..."
    kubectl wait --for=condition=Available --timeout=300s -n "${RANCHER_NAMESPACE}" deployment/rancher
}

verify() {
    section "Step 5/6: Verifying"
    kubectl get pods -n "${RANCHER_NAMESPACE}"
    kubectl get gateway,httproute -n "${RANCHER_NAMESPACE}"
}

print_access_instructions() {
    section "Step 6/6: Access instructions"
    echo "  Add this to /etc/hosts (WSL2) AND C:\\Windows\\System32\\drivers\\etc\\hosts (Windows, run as Admin):"
    echo "    ${ADDR}  ${RANCHER_HOSTNAME}"
    echo
    echo "  Then open: https://${RANCHER_HOSTNAME}"
    echo "  Browser will warn about the self-signed cert — expected, accept/continue."
    echo "  Log in with the bootstrap password you just set."
}

fetch_kubeconfig
create_namespace
generate_tls_secret
apply_gateway_and_route
install_rancher
verify
print_access_instructions
