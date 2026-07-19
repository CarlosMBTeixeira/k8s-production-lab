#!/bin/bash
# ============================================================================
# 05_argocd.sh — Install ArgoCD via the argo-helm chart (Artifact Hub),
# exposed via a dedicated Gateway API resource, same pattern as Rancher
# (ADR-026, ADR-029, ADR-030).
# ----------------------------------------------------------------------------
# server.insecure=true (kubernetes/manifests/argocd/values.yaml): TLS
# terminates at the Gateway, backend serves plain HTTP — same principle as
# Rancher's ingress.tls.source=secret (ADR-027).
#
# Idempotent: safe to re-run after a cluster rebuild.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ARGOCD_DIR="${REPO_ROOT}/kubernetes/manifests/argocd"
KUBECONFIG_LOCAL="${REPO_ROOT}/kubernetes/admin.conf"

ARGOCD_NAMESPACE="argocd"
ARGOCD_CHART_VERSION="10.1.4"

section() {
    echo
    echo "============================================================"
    echo "  $1"
    echo "============================================================"
}

fetch_kubeconfig() {
    section "Step 0/5: Fetching fresh kubeconfig from cp-1"
    scp -o StrictHostKeyChecking=no cp-1:~/.kube/config "${KUBECONFIG_LOCAL}"
    export KUBECONFIG="${KUBECONFIG_LOCAL}"
    kubectl get nodes
}

install_argocd() {
    section "Step 1/5: Installing ArgoCD ${ARGOCD_CHART_VERSION} (argo-helm, Artifact Hub)"
    helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
    helm repo update
    helm upgrade --install argocd argo/argo-cd \
        --version "${ARGOCD_CHART_VERSION}" \
        --namespace "${ARGOCD_NAMESPACE}" --create-namespace \
        -f "${ARGOCD_DIR}/values.yaml"
    kubectl wait --for=condition=Available --timeout=300s -n "${ARGOCD_NAMESPACE}" deployment/argocd-server
}

generate_tls_secret() {
    section "Step 2/5: Generating self-signed TLS cert"
    local tmpdir
    tmpdir="$(mktemp -d)"
    openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
        -keyout "${tmpdir}/tls.key" -out "${tmpdir}/tls.crt" \
        -subj "/CN=argocd.lab" -addext "subjectAltName=DNS:argocd.lab"
    kubectl create secret tls argocd-tls -n "${ARGOCD_NAMESPACE}" \
        --cert="${tmpdir}/tls.crt" --key="${tmpdir}/tls.key" \
        --dry-run=client -o yaml | kubectl apply -f -
    rm -rf "${tmpdir}"
}

apply_gateway_and_route() {
    section "Step 3/5: Applying Gateway + HTTPRoute"
    kubectl apply -f "${ARGOCD_DIR}/gateway-argocd.yaml"
    kubectl apply -f "${ARGOCD_DIR}/httproute-argocd.yaml"

    for i in $(seq 1 30); do
        ADDR=$(kubectl get gateway/argocd -n "${ARGOCD_NAMESPACE}" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
        [ -n "${ADDR}" ] && break
        sleep 2
    done
    if [ -z "${ADDR:-}" ]; then
        echo "  ERROR: Gateway never got an address."
        exit 1
    fi
    echo "  Gateway address: ${ADDR}"
}

print_credentials() {
    section "Step 4/5: Initial admin credentials"
    local password
    password=$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-initial-admin-secret \
        -o jsonpath='{.data.password}' | base64 -d)
    echo "  Username: admin"
    echo "  Password: ${password}"
    echo "  (Delete this secret after first login, per ArgoCD's own docs.)"
}

verify() {
    section "Step 5/5: Verifying"
    kubectl get pods -n "${ARGOCD_NAMESPACE}"
    kubectl get gateway,httproute -n "${ARGOCD_NAMESPACE}"
}

fetch_kubeconfig
install_argocd
generate_tls_secret
apply_gateway_and_route
print_credentials
verify
