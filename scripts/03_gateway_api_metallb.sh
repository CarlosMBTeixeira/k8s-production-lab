#!/bin/bash
# ============================================================================
# 03_gateway_api_metallb.sh — Gateway API smoke test stack (MetalLB + Envoy
# Gateway), replacing a plain nginx+NodePort smoke test.
# ----------------------------------------------------------------------------
# Why: ingress-nginx (the Ingress controller) reached EOL 2026-03-31.
# Gateway API is the recommended path forward. This validates external
# reachability + DNS on a freshly bootstrapped cluster using MetalLB
# (LoadBalancer support, since bare-metal has none by default) + Envoy
# Gateway (Gateway API reference implementation).
#
# Idempotent: safe to re-run after any cluster rebuild. Requires kubectl
# pointed at a Ready cluster (run on cp-1, or wherever kubeconfig lives).
#
# All hand-authored CRs live in kubernetes/manifests/ already
# (metallb-ipaddresspool.yaml, metallb-l2advertisement.yaml). The
# GatewayClass/Gateway/HTTPRoute/backend app are the real upstream
# quickstart.yaml, downloaded fresh and split into one file per resource
# on every run — so kubernetes/manifests/ always reflects the exact
# upstream content, not a hand-typed copy.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
NAMESPACE_DIR="${REPO_ROOT}/kubernetes/manifests/namespaces"
API_GATEWAY_DIR="${REPO_ROOT}/kubernetes/manifests/gateway_api_metallb"
METALLB_VERSION="v0.16.1"
ENVOY_GATEWAY_VERSION="v1.8.2"
NAMESPACE_GATEWAY_API="gateway-api"
KUBECONFIG_LOCAL="${REPO_ROOT}/kubernetes/admin.conf"

mkdir -p "${API_GATEWAY_DIR}"

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

manage_namespace() {
    section "Creating namespace ${NAMESPACE_GATEWAY_API}"
    kubectl apply -f "${NAMESPACE_DIR}/gateway_api.yaml"
}    

# ----------------------------------------------------------------------------
# Step 1: MetalLB (upstream bundle, not vendored — same convention as
# Calico's cni_calico_manifest_url in the ansible role).
# ----------------------------------------------------------------------------
install_metallb() {
    section "Step 1/5: Installing MetalLB ${METALLB_VERSION}"
    kubectl apply -f "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"
    kubectl wait --for=condition=Available --timeout=180s -n metallb-system deployment/controller
    kubectl wait --for=condition=Ready --timeout=180s -n metallb-system pod -l component=speaker
}

# ----------------------------------------------------------------------------
# Step 2: Our own IPAddressPool + L2Advertisement (hand-authored, already
# saved locally).
# ----------------------------------------------------------------------------
configure_metallb_pool() {
    section "Step 2/5: Configuring MetalLB IP pool"
    kubectl apply -f "${API_GATEWAY_DIR}/metallb-ipaddresspool.yaml"
    kubectl apply -f "${API_GATEWAY_DIR}/metallb-l2advertisement.yaml"
}

# ----------------------------------------------------------------------------
# Step 3: Envoy Gateway (Gateway API CRDs bundled in this Helm chart).
# ----------------------------------------------------------------------------
install_envoy_gateway() {
    section "Step 3/5: Installing Envoy Gateway ${ENVOY_GATEWAY_VERSION}"
    helm upgrade --install eg "oci://docker.io/envoyproxy/gateway-helm" \
        --version "${ENVOY_GATEWAY_VERSION}" -n envoy-gateway-system --create-namespace
    kubectl wait --timeout=5m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available
}

# ----------------------------------------------------------------------------
# Step 4: Download the real upstream quickstart.yaml and split it into one
# file per resource under kubernetes/manifests/ — content is always the
# genuine upstream bytes, never hand-typed.
# ----------------------------------------------------------------------------
fetch_and_split_quickstart() {
    section "Step 4/5: Fetching + splitting Envoy Gateway quickstart.yaml"

    local tmpfile
    tmpfile="$(mktemp)"
    curl -sL "https://github.com/envoyproxy/gateway/releases/download/${ENVOY_GATEWAY_VERSION}/quickstart.yaml" -o "${tmpfile}"

    python3 - "${tmpfile}" "${API_GATEWAY_DIR}" <<'PYEOF'
import re
import sys

src, out_dir = sys.argv[1], sys.argv[2]
content = open(src).read()

docs = [d.strip() for d in re.split(r'^---\s*$', content, flags=re.MULTILINE) if d.strip()]

for doc in docs:
    kind_match = re.search(r'^kind:\s*(\S+)', doc, re.MULTILINE)
    name_match = re.search(r'^\s*name:\s*(\S+)', doc, re.MULTILINE)
    if not kind_match or not name_match:
        continue
    kind = kind_match.group(1).lower()
    name = name_match.group(1)
    filename = f"{kind}-{name}.yaml"
    with open(f"{out_dir}/{filename}", "w") as f:
        f.write(doc.strip() + "\n")
    print(f"  wrote {filename}")
PYEOF

    rm -f "${tmpfile}"
}

# ----------------------------------------------------------------------------
# Step 5: Apply everything and verify.
# ----------------------------------------------------------------------------
apply_and_verify() {
    section "Step 5/5: Applying Gateway API resources + verifying"

    kubectl apply -f "${API_GATEWAY_DIR}/serviceaccount-backend.yaml" -n ${NAMESPACE_GATEWAY_API}
    kubectl apply -f "${API_GATEWAY_DIR}/service-backend.yaml" -n ${NAMESPACE_GATEWAY_API}
    kubectl apply -f "${API_GATEWAY_DIR}/deployment-backend.yaml" -n ${NAMESPACE_GATEWAY_API}
    kubectl apply -f "${API_GATEWAY_DIR}/gatewayclass-eg.yaml" -n ${NAMESPACE_GATEWAY_API}
    kubectl apply -f "${API_GATEWAY_DIR}/gateway-eg.yaml" -n ${NAMESPACE_GATEWAY_API}
    kubectl apply -f "${API_GATEWAY_DIR}/httproute-backend.yaml" -n ${NAMESPACE_GATEWAY_API}

    echo "  Waiting for backend deployment..."
    kubectl wait --for=condition=Available --timeout=120s -n ${NAMESPACE_GATEWAY_API} deployment/backend

    echo "  Waiting for Gateway to be programmed (needs a MetalLB IP)..."
    for i in $(seq 1 30); do
        ADDR=$(kubectl get gateway/eg -n ${NAMESPACE_GATEWAY_API} -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
        [ -n "${ADDR}" ] && break
        sleep 2
    done

    if [ -z "${ADDR:-}" ]; then
        echo "  ERROR: Gateway never got an address from MetalLB. Check 'kubectl describe gateway/eg -n ${NAMESPACE_GATEWAY_API}'."
        exit 1
    fi

    echo "  Gateway address: ${ADDR}"
    echo
    echo "  Waiting for MetalLB to finish announcing the IP (ARP convergence)..."
    # The Gateway gets .status.addresses as soon as MetalLB's controller
    # assigns the IP, but the speaker still needs to win its own
    # per-service election and broadcast ARP for it. These two are not
    # synchronized, so retry the actual HTTP request instead of trusting
    # the address being set to mean "reachable".
    HTTP_OK=false
    for i in $(seq 1 15); do
        if curl --silent --fail --max-time 3 --header "Host: www.example.com" "http://${ADDR}/get" > /tmp/gateway-test-response.json 2>/dev/null; then
            HTTP_OK=true
            break
        fi
        sleep 2
    done

    if [ "${HTTP_OK}" = "false" ]; then
        echo "  ERROR: Gateway address never became reachable after 30s. Check:"
        echo "    kubectl logs -n metallb-system -l component=speaker --tail=30"
        exit 1
    fi

    echo "  Gateway reachable. Response:"
    cat /tmp/gateway-test-response.json
    echo
}

fetch_kubeconfig
manage_namespace
install_metallb
configure_metallb_pool
install_envoy_gateway
fetch_and_split_quickstart
apply_and_verify

echo
echo "============================================================"
echo "  Gateway API smoke test stack ready. Gateway IP: ${ADDR:-unknown}"
echo "============================================================"
