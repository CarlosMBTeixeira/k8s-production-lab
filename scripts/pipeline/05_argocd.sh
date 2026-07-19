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
# Admin password is set at install time via a bcrypt hash, generated
# on the fly and passed through a temp values file (never written to git,
# never passed as a --set with an escaped $ — same reproducibility
# principle as ADR-006). Setting this reliably requires a FRESH install:
# the chart can ignore password changes on an in-place `helm upgrade`
# over an existing release (argo-helm issue #1407) — this script's
# idempotency assumes the usual destroy/rebuild workflow, not a live
# password change on a running release.
#
# Idempotent (on a fresh cluster): safe to re-run after a cluster rebuild.
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
    section "Step 0/6: Fetching fresh kubeconfig from cp-1"
    scp -o StrictHostKeyChecking=no cp-1:~/.kube/config "${KUBECONFIG_LOCAL}"
    export KUBECONFIG="${KUBECONFIG_LOCAL}"
    kubectl get nodes
}

prepare_admin_password() {
    section "Step 1/6: Setting a custom admin password"
    if ! command -v htpasswd >/dev/null 2>&1; then
        echo "  htpasswd not found, installing apache2-utils..."
        sudo apt-get update -qq && sudo apt-get install -y apache2-utils
    fi

    read -r -s -p "  Choose an ArgoCD admin password (min 8 chars, not stored anywhere): " ARGOCD_PASSWORD
    echo
    local hash
    hash="$(htpasswd -nbBC 10 "" "${ARGOCD_PASSWORD}" | tr -d ':\n' | sed 's/\$2y/\$2a/')"

    PASSWORD_VALUES_FILE="$(mktemp)"
    cat > "${PASSWORD_VALUES_FILE}" << YAMLEOF
configs:
  secret:
    argocdServerAdminPassword: "${hash}"
    argocdServerAdminPasswordMtime: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
YAMLEOF
}

install_argocd() {
    section "Step 2/6: Installing ArgoCD ${ARGOCD_CHART_VERSION} (argo-helm, Artifact Hub)"
    helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
    helm repo update
    helm upgrade --install argocd argo/argo-cd \
        --version "${ARGOCD_CHART_VERSION}" \
        --namespace "${ARGOCD_NAMESPACE}" --create-namespace \
        -f "${ARGOCD_DIR}/values.yaml" \
        -f "${PASSWORD_VALUES_FILE}"
    rm -f "${PASSWORD_VALUES_FILE}"
    kubectl wait --for=condition=Available --timeout=300s -n "${ARGOCD_NAMESPACE}" deployment/argocd-server
}

generate_tls_secret() {
    section "Step 3/6: Generating self-signed TLS cert"
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
    section "Step 4/6: Applying Gateway + HTTPRoute"
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

verify() {
    section "Step 5/6: Verifying"
    kubectl get pods -n "${ARGOCD_NAMESPACE}"
    kubectl get gateway,httproute -n "${ARGOCD_NAMESPACE}"
}

print_reminder() {
    section "Step 6/6: Access"
    echo "  Username: admin"
    echo "  Password: the one you just typed in"
    echo "  Run ./scripts/tunnels/argocd-tunnel.sh, then https://localhost:8444/"
}

fetch_kubeconfig
prepare_admin_password
install_argocd
generate_tls_secret
apply_gateway_and_route
verify
print_reminder
