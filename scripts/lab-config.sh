#!/bin/bash
# ============================================================================
# lab-config.sh — Single source of truth for the lab's node topology.
# ----------------------------------------------------------------------------
# Sourced by every script that needs to know which VMs exist. Nothing here
# executes on its own; it only defines variables and functions.
#
# The number of workers is a variable, not a branch difference (ADR-036).
# Resolution order, first match wins:
#
#   1. LAB_WORKERS in the environment   — explicit, wins over everything
#   2. .lab-topology in the repo root   — what the running lab was built as
#   3. LAB_DEFAULT_WORKERS below        — 1, the workbook's topology
#
# The state file matters more than it looks: morning-check.sh and
# fix-vm-clocks.sh run in shells that never saw the env var, and checking
# for a worker-2 that was never built is a false alarm. lab-management.sh
# writes the file whenever it builds.
#
# Usage:
#   source "$(dirname "$0")/lab-config.sh"
#   for vm in $(lab_vm_names); do ... done
# ============================================================================

LAB_MAX_WORKERS=2
LAB_DEFAULT_WORKERS=1

# Total RAM given to workers, split evenly between them. Keeping the sum
# fixed is the point: 1x8G and 2x4G cost the WSL2 host exactly the same,
# so switching topology never changes the host's memory budget, only how
# the scheduler can use it (ADR-035).
LAB_WORKER_MEMORY_BUDGET_G=8
LAB_CONTROLPLANE_MEMORY="4G"
LAB_VM_CPUS=2
LAB_VM_DISK="20G"

# Repo root, resolved from this file rather than the caller's $0 — callers
# live at different depths (scripts/, scripts/pipeline/).
LAB_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_STATE_FILE="${LAB_REPO_ROOT}/.lab-topology"

# ----------------------------------------------------------------------------
# lab_workers — resolved worker count. Always prints a valid number.
# ----------------------------------------------------------------------------
lab_workers() {
    local n=""
    if [ -n "${LAB_WORKERS:-}" ]; then
        n="${LAB_WORKERS}"
    elif [ -f "${LAB_STATE_FILE}" ]; then
        n="$(tr -dc '0-9' < "${LAB_STATE_FILE}")"
    fi
    [ -z "$n" ] && n="${LAB_DEFAULT_WORKERS}"
    case "$n" in ''|*[!0-9]*)
        echo "lab-config: worker count '${n}' is not a number" >&2; return 1 ;;
    esac
    if [ "$n" -lt 1 ] || [ "$n" -gt "${LAB_MAX_WORKERS}" ]; then
        echo "lab-config: worker count '${n}' out of range (1-${LAB_MAX_WORKERS})" >&2
        return 1
    fi
    echo "$n"
}

# ----------------------------------------------------------------------------
# lab_set_workers <n> — validate and persist. Called by lab-management.sh
# after a successful build, so every later shell agrees with reality.
# ----------------------------------------------------------------------------
lab_set_workers() {
    local n="${1:?lab_set_workers needs a count}"
    case "$n" in ''|*[!0-9]*)
        echo "lab-config: refusing non-numeric worker count '${n}'" >&2; return 1 ;;
    esac
    if [ "$n" -lt 1 ] || [ "$n" -gt "${LAB_MAX_WORKERS}" ]; then
        echo "lab-config: refusing to set worker count to '${n}' (expected 1-${LAB_MAX_WORKERS})" >&2
        return 1
    fi
    printf '%s\n' "$n" > "${LAB_STATE_FILE}"
    export LAB_WORKERS="$n"
}

lab_clear_topology() { rm -f "${LAB_STATE_FILE}"; }

# ----------------------------------------------------------------------------
# Derived values
# ----------------------------------------------------------------------------

# Even split of the fixed budget. Integer division is fine for 8/1 and 8/2.
lab_worker_memory() { echo "$(( LAB_WORKER_MEMORY_BUDGET_G / $(lab_workers) ))G"; }

lab_vm_names() {
    local n; n="$(lab_workers)" || return 1
    printf 'controlplane-1 controlplane-2'
    local i; for ((i=1; i<=n; i++)); do printf ' worker-%d' "$i"; done
    printf '\n'
}

lab_ssh_aliases() {
    local n; n="$(lab_workers)" || return 1
    printf 'cp-1 cp-2'
    local i; for ((i=1; i<=n; i++)); do printf ' w-%d' "$i"; done
    printf '\n'
}

lab_worker_aliases() {
    local n; n="$(lab_workers)" || return 1
    local i out=(); for ((i=1; i<=n; i++)); do out+=("w-${i}"); done
    echo "${out[@]}"
}

# cp-1 -> controlplane-1, w-1 -> worker-1
lab_alias_to_vm() {
    case "${1:?}" in
        cp-*) echo "controlplane-${1#cp-}" ;;
        w-*)  echo "worker-${1#w-}" ;;
        *)    echo "lab-config: unknown alias '$1'" >&2; return 1 ;;
    esac
}

# Per-VM resources as "<cpus> <memory> <disk>", for launch-node.sh.
lab_vm_resources() {
    case "${1:?}" in
        worker-*) echo "${LAB_VM_CPUS} $(lab_worker_memory) ${LAB_VM_DISK}" ;;
        *)        echo "${LAB_VM_CPUS} ${LAB_CONTROLPLANE_MEMORY} ${LAB_VM_DISK}" ;;
    esac
}

# ----------------------------------------------------------------------------
# lab_ansible_limit — ansible/inventory/hosts.ini always lists every worker
# the lab *can* have, because an INI inventory cannot conditionally include
# a host. Playbooks are therefore run with --limit so hosts that were never
# built are simply out of scope, rather than unreachable failures.
# ----------------------------------------------------------------------------
lab_ansible_limit() {
    local n; n="$(lab_workers)" || return 1
    if [ "$n" -ge "${LAB_MAX_WORKERS}" ]; then
        echo "k8s_cluster"
    else
        echo "controlplane:$(lab_worker_aliases | tr ' ' ':')"
    fi
}

# ----------------------------------------------------------------------------
# Human-readable summary, used in banners and health checks.
# ----------------------------------------------------------------------------
lab_topology_line() {
    local n; n="$(lab_workers)" || return 1
    if [ "$n" -gt 1 ]; then
        echo "$((2 + n)) nodes — 2 control planes (${LAB_CONTROLPLANE_MEMORY}, tainted) + ${n} workers ($(lab_worker_memory) each)"
    else
        echo "3 nodes — 2 control planes (${LAB_CONTROLPLANE_MEMORY}, tainted) + 1 worker ($(lab_worker_memory))"
    fi
}

lab_topology_source() {
    if [ -n "${LAB_WORKERS:-}" ]; then echo "LAB_WORKERS in the environment"
    elif [ -f "${LAB_STATE_FILE}" ]; then echo ".lab-topology (what the lab was last built as)"
    else echo "default"; fi
}

# ----------------------------------------------------------------------------
# lab_choose_topology — the interactive prompt. Sets LAB_WORKERS for the
# current shell; the caller persists it after a successful build.
#
# Skipped entirely when LAB_WORKERS is already set in the environment, so
# `LAB_WORKERS=2 bash scripts/pipeline/main.sh` stays non-interactive and
# scriptable.
# ----------------------------------------------------------------------------
lab_choose_topology() {
    if [ -n "${LAB_WORKERS:-}" ]; then
        echo "  Topology: $(lab_topology_line)  [LAB_WORKERS=${LAB_WORKERS}]"
        return 0
    fi

    cat <<'BANNER'

|---------------------------------------------------------------------------
| Topology — how many worker nodes?
|---------------------------------------------------------------------------
| The control planes are always 2 x 4G and always tainted NoSchedule, so
| every workload lands on the workers. The worker RAM budget is fixed at
| 8G total either way: the choice is whether the scheduler sees it as one
| pool or two (ADR-035, ADR-036).
|
|  1) ONE worker, 8G      -> 3 nodes
|     Use for: ArgoCD + Observability together, and everything in
|     observability_workbook/ (sessions 1-5). Both stacks are ~3.5Gi and
|     only fit reliably when that memory is in a single schedulable node.
|     Gives up: multi-worker scheduling, worker-level HA.
|
|  2) TWO workers, 4G each -> 4 nodes
|     Use for: pod anti-affinity, topologySpreadConstraints, draining a
|     worker and watching pods move, DaemonSet spread, surviving the loss
|     of a worker, and anything CKA/CKS-flavoured about scheduling.
|     Gives up: running ArgoCD and the observability stack at once --
|     main.sh will make you pick one application.
|
| Rule of thumb: the workbook wants 1. Scheduling practice wants 2.
| Non-interactive:  LAB_WORKERS=2 bash scripts/pipeline/main.sh
|---------------------------------------------------------------------------
BANNER

    local choice
    read -r -p "Choice [1/2] (default 1): " choice
    case "${choice:-1}" in
        1) export LAB_WORKERS=1 ;;
        2) export LAB_WORKERS=2 ;;
        *) echo "Unknown choice: ${choice}"; return 1 ;;
    esac
    echo "  Selected: $(lab_topology_line)"
}
