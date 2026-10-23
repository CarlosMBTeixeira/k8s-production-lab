#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Node topology is a variable, not a branch difference (ADR-036). Ask here,
# once, before anything is built -- lab-management.sh and every later script
# inherit the answer through the exported LAB_WORKERS and .lab-topology.
# Set LAB_WORKERS in the environment to skip the prompt entirely:
#   LAB_WORKERS=2 bash scripts/pipeline/main.sh
source "${SCRIPT_DIR}/../lab-config.sh"
lab_choose_topology
LAB_WORKER_COUNT="$(lab_workers)"

source "${SCRIPT_DIR}/01_initial_cluster_setup.sh"
source "${SCRIPT_DIR}/02_kubeadm_join.sh"
source "${SCRIPT_DIR}/03_gateway_api_metallb.sh"
source "${SCRIPT_DIR}/04_cert_manager.sh"

echo ""
echo "==========================================================================="
echo "| Installation complete: cluster + Gateway API + cert-manager."
echo "==========================================================================="


# Whether stacks can coexist depends on the topology chosen above
# (ADR-035, ADR-036, ADR-038). They fit reliably in one 8G worker and
# unreliably across two 4G ones, because the scheduler cannot split a pod
# across nodes. The notes below change with the topology so the menu says
# so before you pick, not after an OOMKill.
#
# cert-manager is cluster infra (like Calico/MetalLB), not gated behind
# this choice -- it's small and every app depends on it for TLS (ADR-033).
if [ "${LAB_WORKER_COUNT}" -eq 1 ]; then
    STACK_FIT="this lab has it"
    NOTE_ARGO_OBS="needs 1 x 8G worker -- ${STACK_FIT}"
    NOTE_OBS_MESH="needs 1 x 8G worker -- ${STACK_FIT}"
    NOTE_ALL="needs 1 x 8G worker -- ${STACK_FIT}"
else
    STACK_FIT="this lab has ${LAB_WORKER_COUNT} x $(lab_worker_memory)"
    NOTE_ARGO_OBS="needs 1 x 8G worker -- ${STACK_FIT}: asks to confirm"
    NOTE_OBS_MESH="needs 1 x 8G worker -- ${STACK_FIT}: asks to confirm"
    NOTE_ALL="needs 1 x 8G worker -- ${STACK_FIT}: refused"
fi

echo ""
echo "Application to install"
echo ""
echo "  This lab: $(lab_topology_line)"
echo "  Stacks need their memory on ONE 8G worker: a pod cannot be split across"
echo "  two 4G workers."
if [ "${LAB_WORKER_COUNT}" -ne 1 ]; then
    echo "  To get one: ./scripts/lab-management.sh destroy --force"
    echo "              LAB_WORKERS=1 bash scripts/pipeline/main.sh"
fi
echo ""
echo "  Single applications"
echo "    1) Rancher                                  (alone -- heaviest)"
echo "    2) ArgoCD"
echo "    3) Observability                            (kube-prometheus-stack + Loki + Alloy)"
echo ""
echo "  Stacks"
echo "    4) ArgoCD + Observability                   (${NOTE_ARGO_OBS})"
echo "    5) Observability + Istio + Kiali            (${NOTE_OBS_MESH})"
echo "    6) ArgoCD + Observability + Istio + Kiali   (${NOTE_ALL})"
echo ""
echo "  Add-ons -- on top of an existing Observability install"
echo "    7) Network Policies                         (monitoring namespace)"
echo "    8) Istio + Kiali                            (mesh + Bookinfo)"
echo ""
# "None" is 0 so it stays at the bottom whatever gets added above it.
echo "    0) None -- just the cluster + Gateway API + cert-manager"
echo ""
read -r -p "Choice [0-8]: " APP_CHOICE

# Guard, not a block: two 4G workers can technically hold these stacks, it
# just stops being reliable. Make the operator say so out loud rather than
# discovering it as an OOMKill mid-exercise.
confirm_two_workers() {
    local what="$1" adr="$2"
    if [ "${LAB_WORKER_COUNT}" -ne 1 ]; then
        echo ""
        echo "  WARNING: ${LAB_WORKER_COUNT} workers x $(lab_worker_memory). ${what} needs that"
        echo "  memory in ONE schedulable node (${adr}). Rebuild with LAB_WORKERS=1 for it."
        read -r -p "  Continue anyway? [y/N]: " CONFIRM
        [ "${CONFIRM}" = "y" ] || [ "${CONFIRM}" = "Y" ] || { echo "Aborted."; exit 1; }
    fi
}

done_banner() {
    echo ""
    echo "==========================================================================="
    for line in "$@"; do echo "| ${line}"; done
    echo "==========================================================================="
}

ARGOCD_LINE="ArgoCD:  ./scripts/tunnels/argocd-tunnel.sh    -> https://localhost:8444/"
GRAFANA_LINE="Grafana: ./scripts/tunnels/grafana-tunnel.sh   -> https://localhost:8445/"
KIALI_LINE="Kiali:   ./scripts/tunnels/kiali-tunnel.sh     -> https://localhost:8446/"
KIALI_TOKEN_LINE="Kiali token: kubectl -n istio-system create token kiali-login --duration 8h"
HEADROOM_LINES=("Check headroom with:"
                "  kubectl describe node -l '!node-role.kubernetes.io/control-plane' \\"
                "    | grep -A6 'Allocated resources'")

case "${APP_CHOICE}" in
    1)
        source "${SCRIPT_DIR}/05_rancher.sh"
        done_banner "Installation complete: Rancher." \
                    "Run ./scripts/tunnels/rancher-tunnel.sh to access Rancher in the browser."
        ;;
    2)
        source "${SCRIPT_DIR}/06_argocd.sh"
        done_banner "Installation complete: ArgoCD." "${ARGOCD_LINE}"
        ;;
    3)
        source "${SCRIPT_DIR}/07_observability.sh"
        done_banner "Installation complete: Observability (Prometheus/Grafana/Loki)." "${GRAFANA_LINE}"
        ;;
    4)
        confirm_two_workers "ArgoCD + Observability (~3.5Gi)" "ADR-035"
        # ArgoCD first, so the observability stack can later be handed
        # over to it as an Application (study topic 3) without
        # reinstalling anything. Each script fetches its own kubeconfig
        # (ADR-024) and prompts for its own password: expect two prompts.
        source "${SCRIPT_DIR}/06_argocd.sh"
        source "${SCRIPT_DIR}/07_observability.sh"
        done_banner "Installation complete: ArgoCD + Observability." \
                    "${ARGOCD_LINE}" "${GRAFANA_LINE}" "${HEADROOM_LINES[@]}"
        ;;
    5)
        confirm_two_workers "Observability + Istio + Kiali + Bookinfo" "ADR-038"
        source "${SCRIPT_DIR}/07_observability.sh"
        source "${SCRIPT_DIR}/09_istio_kiali.sh"
        done_banner "Installation complete: Observability + Istio + Kiali." \
                    "${GRAFANA_LINE}" "${KIALI_LINE}" "${KIALI_TOKEN_LINE}"
        ;;
    6)
        # Refused, not confirmed: with ArgoCD on top of the mesh stack the
        # total no longer fits in 4G slices at all (ADR-035, ADR-038).
        if [ "${LAB_WORKER_COUNT}" -ne 1 ]; then
            echo ""
            echo "  REFUSED: option 6 needs ONE 8G worker; this lab has ${LAB_WORKER_COUNT} x $(lab_worker_memory)."
            echo "  ArgoCD + Observability alone is ~2.9Gi of requests (ADR-035); the mesh and"
            echo "  Bookinfo add ~1.5-2Gi more (ADR-038). Pods cannot be split across nodes."
            echo "  Rebuild:  ./scripts/lab-management.sh destroy --force"
            echo "            LAB_WORKERS=1 bash scripts/pipeline/main.sh"
            exit 1
        fi
        # ArgoCD first (same reasoning as 4), then the stack Kiali reads
        # from, then the mesh. Expect two password prompts (ArgoCD, Grafana).
        source "${SCRIPT_DIR}/06_argocd.sh"
        source "${SCRIPT_DIR}/07_observability.sh"
        source "${SCRIPT_DIR}/09_istio_kiali.sh"
        done_banner "Installation complete: ArgoCD + Observability + Istio + Kiali." \
                    "${ARGOCD_LINE}" "${GRAFANA_LINE}" "${KIALI_LINE}" "${KIALI_TOKEN_LINE}" \
                    "${HEADROOM_LINES[@]}"
        ;;
    7)
        # 08 checks for the monitoring namespace itself and exits if missing.
        source "${SCRIPT_DIR}/08_network_policies.sh"
        done_banner "Installation complete: Network Policies (monitoring)."
        ;;
    8)
        # 09 checks for the observability stack itself and exits if missing.
        source "${SCRIPT_DIR}/09_istio_kiali.sh"
        done_banner "Installation complete: Istio + Kiali." "${KIALI_LINE}" "${KIALI_TOKEN_LINE}"
        ;;
    0)
        echo ""
        echo "Skipping application install -- cluster + Gateway API + cert-manager only."
        ;;
    *)
        echo "Unknown choice: ${APP_CHOICE}"
        exit 1
        ;;
esac
