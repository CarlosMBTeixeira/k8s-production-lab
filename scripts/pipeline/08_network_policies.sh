#!/bin/bash
# ============================================================================
# 08_network_policies.sh — Apply default-deny + explicit-allow Network
# Policies for the monitoring namespace (ADR-034). Requires the
# observability stack (07_observability.sh) to already be installed --
# the `monitoring` namespace must exist.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
POLICY_FILE="${REPO_ROOT}/kubernetes/manifests/network_policies/monitoring.yaml"
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

check_namespace() {
    section "Checking namespace ${NAMESPACE}"
    if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
        echo "  ERROR: namespace '${NAMESPACE}' does not exist."
        echo "  Install the observability stack first: ./scripts/pipeline/07_observability.sh"
        exit 1
    fi
}

apply_policies() {
    section "Applying Network Policies"
    kubectl apply -f "${POLICY_FILE}"
}

verify() {
    section "Verifying"
    kubectl get networkpolicy -n "${NAMESPACE}"
}

fetch_kubeconfig
check_namespace
apply_policies
verify
