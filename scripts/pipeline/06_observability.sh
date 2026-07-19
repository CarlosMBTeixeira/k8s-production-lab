#!/bin/bash
# ============================================================================
# 06_observability.sh — Install kube-prometheus-stack (Prometheus, Grafana,
# Alertmanager) via Helm from Artifact Hub (ADR-030, ADR-031).
# ----------------------------------------------------------------------------
# Same pattern as 04_rancher.sh / 05_argocd.sh: dedicated Gateway (no
# hostname restriction), self-signed TLS at the Gateway, admin password
# prompted at install time, tunnel script for Windows access.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OBSERVABILITY_DIR="${REPO_ROOT}/kubernetes/manifests/observability"
CHART_VERSION="87.17.0"
NAMESPACE="monitoring"

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

create_namespace() {
    section "Creating namespace ${NAMESPACE}"
    kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
}

generate_tls_secret() {
    section "Generating self-signed TLS cert for Grafana"
    if kubectl get secret grafana-tls -n "${NAMESPACE}" >/dev/null 2>&1; then
        echo "  grafana-tls secret already exists, skipping."
        return
    fi
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf ${tmp_dir}" RETURN
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "${tmp_dir}/tls.key" -out "${tmp_dir}/tls.crt" \
        -subj "/CN=grafana.lab" >/dev/null 2>&1
    kubectl create secret tls grafana-tls -n "${NAMESPACE}" \
        --cert="${tmp_dir}/tls.crt" --key="${tmp_dir}/tls.key"
}

apply_gateway_and_route() {
    section "Applying Gateway + HTTPRoute"
    kubectl apply -f "${OBSERVABILITY_DIR}/gateway-observability.yaml"
    kubectl apply -f "${OBSERVABILITY_DIR}/httproute-observability.yaml"
    echo "  Waiting for Gateway address..."
    kubectl wait --for=jsonpath='{.status.addresses[0].value}' \
        gateway/grafana -n "${NAMESPACE}" --timeout=120s
}

add_helm_repo() {
    section "Adding prometheus-community Helm repo"
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo update prometheus-community
}

prepare_admin_password() {
    section "Grafana admin password"
    if ! command -v htpasswd >/dev/null 2>&1; then
        sudo apt-get install -y apache2-utils >/dev/null
    fi
    read -r -s -p "  Set the Grafana admin password: " GRAFANA_PASSWORD
    echo ""
    PASSWORD_VALUES_FILE=$(mktemp)
    cat > "${PASSWORD_VALUES_FILE}" << EOF
grafana:
  adminPassword: "${GRAFANA_PASSWORD}"
EOF
}

install_stack() {
    section "Installing kube-prometheus-stack ${CHART_VERSION}"
    helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
        --version "${CHART_VERSION}" \
        -n "${NAMESPACE}" \
        -f "${OBSERVABILITY_DIR}/values.yaml" \
        -f "${PASSWORD_VALUES_FILE}" \
        --timeout 600s \
        --wait
    rm -f "${PASSWORD_VALUES_FILE}"
}

verify() {
    section "Verifying"
    kubectl get pods -n "${NAMESPACE}"
}

print_access_instructions() {
    section "Done"
    echo "  Tunnel:  ./scripts/tunnels/grafana-tunnel.sh, then https://localhost:8445/"
    echo "  Direct:  kubectl get gateway grafana -n ${NAMESPACE}, then https://<address>/"
    echo "  Login:   admin / (the password you just set)"
}

fetch_kubeconfig
create_namespace
generate_tls_secret
apply_gateway_and_route
add_helm_repo
prepare_admin_password
install_stack
verify
print_access_instructions
