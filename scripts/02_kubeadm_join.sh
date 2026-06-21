#!/bin/bash
# ============================================================================
# 02_kubeadm_join.sh — Join workers to the K8s cluster.
# ----------------------------------------------------------------------------
# Prerequisite: 01_initial_cluster_setup.sh must have already run and left
# the cluster in a Ready state on controlplane-1.
#
# Sequence (4 steps, ~2-4 min):
#   1. Verify cluster is reachable and cp-1 is Ready
#   2. Generate a fresh bootstrap join token on cp-1
#      (avoids relying on the saved one which expires after 24h)
#   3. Run 'kubeadm join' on each worker, wait for it to become Ready
#   4. Print the final cluster state
#
# Run from anywhere; the script anchors to its own directory.
# Fails fast — any step's failure aborts the rest.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

# Workers to join. If the lab grows, add their SSH aliases here.
WORKERS=(w-1 w-2)

# Worker -> kubectl node name mapping (so we can 'kubectl wait' on the
# right object after each join). Multipass names diverge from SSH aliases.
declare -A WORKER_NODE_NAME=(
    [w-1]=worker-1
    [w-2]=worker-2
)

# ----------------------------------------------------------------------------
# Pretty section header so the operator can follow along in long output.
# ----------------------------------------------------------------------------
section() {
    echo
    echo "============================================================"
    echo "  $1"
    echo "============================================================"
}

# ----------------------------------------------------------------------------
# Step 1: Verify the cluster is up and cp-1 is Ready.
# Fails fast with a clear message if 01_initial_cluster_setup.sh
# was not run first.
# ----------------------------------------------------------------------------
verify_cluster_is_ready() {
    section "Step 1/4: Verifying cluster is reachable"

    if ! ssh -o ConnectTimeout=5 cp-1 "kubectl get nodes" >/dev/null 2>&1; then
        echo "ERROR: kubectl on cp-1 does not respond."
        echo "Did you run 01_initial_cluster_setup.sh first?"
        exit 1
    fi

    local cp_status
    cp_status="$(ssh cp-1 "kubectl get node controlplane-1 -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}'")"

    if [ "${cp_status}" != "True" ]; then
        echo "ERROR: controlplane-1 is not Ready (status: ${cp_status})."
        echo "Investigate cluster state before joining workers."
        exit 1
    fi

    echo "  ✅ cp-1 reachable, controlplane-1 is Ready"
}

# ----------------------------------------------------------------------------
# Step 2: Generate a fresh join token on cp-1.
# Tokens expire 24h after creation; generating a new one every run means
# this script works regardless of when the cluster was bootstrapped.
# ----------------------------------------------------------------------------
generate_fresh_join_command() {
    section "Step 2/4: Generating fresh join token on cp-1"

    JOIN_CMD="$(ssh cp-1 'sudo kubeadm token create --print-join-command')"

    if [[ "${JOIN_CMD}" != *"kubeadm join"* ]]; then
        echo "ERROR: did not get a valid join command from cp-1."
        echo "Got: ${JOIN_CMD}"
        exit 1
    fi

    echo "  ✅ Fresh token generated"
    echo "  Command: ${JOIN_CMD}"
}

# ----------------------------------------------------------------------------
# Step 3: Join each worker and wait for it to reach Ready.
# Sequential rather than parallel: easier to debug if one fails, and
# 2 workers don't make parallel worth the complexity.
# ----------------------------------------------------------------------------
join_each_worker() {
    section "Step 3/4: Joining workers"

    for worker in "${WORKERS[@]}"; do
        local node_name="${WORKER_NODE_NAME[${worker}]}"

        echo
        echo "  --- ${worker} (${node_name}) ---"

        # kubeadm join needs sudo on the worker. Wrap with sudo here so the
        # command produced by 'kubeadm token create --print-join-command'
        # (which has no sudo prefix) runs with the right privileges.
        ssh "${worker}" "sudo ${JOIN_CMD}"

        echo "  Waiting for ${node_name} to become Ready..."
        ssh cp-1 "kubectl wait --for=condition=Ready node/${node_name} --timeout=120s"
    done

    echo
    echo "  ✅ All workers joined and Ready"
}

# ----------------------------------------------------------------------------
# Step 4: Print the final cluster state for the operator to verify.
# ----------------------------------------------------------------------------
check_final_state() {
    section "Step 4/4: Final cluster state"

    ssh cp-1 "kubectl get nodes -o wide"
    echo
    ssh cp-1 "kubectl get pods -A -o wide"
}

# ============================================================================
# Pipeline.
# ============================================================================
verify_cluster_is_ready
generate_fresh_join_command
join_each_worker
check_final_state

echo
echo "============================================================"
echo "  Workers joined. Cluster has $(ssh cp-1 'kubectl get nodes --no-headers | wc -l') nodes Ready."
echo "============================================================"
