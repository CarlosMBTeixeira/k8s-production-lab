#!/bin/bash
# ============================================================================
# 04_cert_manager.sh — Install cert-manager via Helm from Artifact Hub
# (ADR-030, ADR-033), then configure a ClusterIssuer for Let's Encrypt via
# Cloudflare DNS-01. Cluster infra, not gated behind the app-choice prompt:
# every application's real TLS cert depends on it.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CHART_VERSION="v1.21.0"
NAMESPACE="cert-manager"
DOMAIN="entraid-study.uk"
ACME_EMAIL="cmbt1984@gmail.com"
TOKEN_FILE="${REPO_ROOT}/secrets/cloudflare-api-token"
CLUSTER_ISSUER="${REPO_ROOT}/kubernetes/manifests/cert_manager/clusterissuer.yaml"

section() {
    echo ""
    echo "|---------------------------------------------------------------------------"
    echo "| $1"
    echo "|---------------------------------------------------------------------------"
}

fetch_kubeconfig() {
    section "Fetching kubeconfig"
    scp -o StrictHostKeyChecking=no cp-1:~/.kube/config "${REPO_ROOT}/kubernetes/admin.conf"
    export KUBECONFIG="${REPO_ROOT}/kubernetes/admin.conf"
}

add_helm_repo() {
    section "Adding jetstack Helm repo"
    helm repo add jetstack https://charts.jetstack.io --force-update
    helm repo update jetstack
}

install_cert_manager() {
    section "Installing cert-manager ${CHART_VERSION}"
    helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace "${NAMESPACE}" \
        --create-namespace \
        --version "${CHART_VERSION}" \
        --set crds.enabled=true \
        --set resources.requests.cpu=10m \
        --set resources.requests.memory=32Mi \
        --set resources.limits.memory=64Mi \
        --set webhook.resources.requests.cpu=10m \
        --set webhook.resources.requests.memory=32Mi \
        --set webhook.resources.limits.memory=64Mi \
        --set cainjector.resources.requests.cpu=10m \
        --set cainjector.resources.requests.memory=32Mi \
        --set cainjector.resources.limits.memory=128Mi \
        --timeout 300s \
        --wait
}

load_cloudflare_token() {
    section "Loading Cloudflare API token"
    if [ ! -f "${TOKEN_FILE}" ]; then
        echo "  ERROR: ${TOKEN_FILE} not found."
        echo "  Create a Cloudflare API token scoped to ${DOMAIN} (Zone:Read + DNS:Edit),"
        echo "  then save it with:"
        echo "    mkdir -p secrets && chmod 700 secrets"
        echo "    read -r -s -p 'Cloudflare API token: ' CF_TOKEN && printf '%s' \"\$CF_TOKEN\" > ${TOKEN_FILE} && unset CF_TOKEN"
        echo "    chmod 600 ${TOKEN_FILE}"
        exit 1
    fi
    CLOUDFLARE_API_TOKEN="$(cat "${TOKEN_FILE}")"
}

create_cloudflare_secret() {
    section "Creating Cloudflare API token secret"
    kubectl create secret generic cloudflare-api-token-secret \
        -n "${NAMESPACE}" \
        --from-literal=api-token="${CLOUDFLARE_API_TOKEN}" \
        --dry-run=client -o yaml | kubectl apply -f -
}

apply_cluster_issuer() {
    section "Applying ClusterIssuer letsencrypt-k8slab"
    kubectl apply -f "${CLUSTER_ISSUER}"
}

verify() {
    section "Verifying"
    kubectl get pods -n "${NAMESPACE}"
    echo ""
    kubectl wait --for=condition=Ready clusterissuer/letsencrypt-k8slab --timeout=60s
    kubectl get clusterissuer letsencrypt-k8slab
}

fetch_kubeconfig
add_helm_repo
install_cert_manager
load_cloudflare_token
create_cloudflare_secret
apply_cluster_issuer
verify
