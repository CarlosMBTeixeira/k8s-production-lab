#!/bin/bash
# ============================================================================
# lab-management.sh — Manage the Kubernetes lab lifecycle.
# ----------------------------------------------------------------------------
# Provides three operations on the lab VMs:
#   - build    : create the 4 lab VMs (fails if any already exist)
#   - destroy  : remove all lab VMs (requires confirmation)
#   - rebuild  : destroy and then build (requires confirmation)
#
# Can be run interactively (shows a menu when called with no arguments)
# or with a direct action argument. Confirmations can be skipped with
# --force for automation use.
#
# Usage:
#   ./scripts/lab-management.sh                       # interactive menu
#   ./scripts/lab-management.sh build                 # build directly
#   ./scripts/lab-management.sh destroy               # destroy (will ask)
#   ./scripts/lab-management.sh destroy --force       # destroy (no prompt)
#   ./scripts/lab-management.sh rebuild --force       # rebuild (no prompt)
# ============================================================================

set -euo pipefail

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------

# VMs to manage. Order matters: control plane first, workers after.
VMS=(controlplane-1 controlplane-2 worker-1 worker-2)

SCRIPT_DIR="$(dirname "$0")"
LAUNCH_SCRIPT="${SCRIPT_DIR}/launch-node.sh"
SYNC_SCRIPT="${SCRIPT_DIR}/sync-ssh-config.sh"
CHECK_SCRIPT="${SCRIPT_DIR}/morning-check.sh"
FIX_NETWORK_SCRIPT="${SCRIPT_DIR}/fix-network-access.sh"

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------

ACTION=""
FORCE=false

if [ $# -eq 0 ]; then
    ACTION="interactive"
elif [ $# -eq 1 ]; then
    ACTION="$1"
elif [ $# -eq 2 ]; then
    ACTION="$1"
    if [ "$2" = "--force" ]; then
        FORCE=true
    else
        echo "Unknown second argument: $2"
        echo "Usage: $0 [build|destroy|rebuild] [--force]"
        exit 1
    fi
else
    echo "Too many arguments."
    echo "Usage: $0 [build|destroy|rebuild] [--force]"
    exit 1
fi

# ----------------------------------------------------------------------------
# Helper functions
# ----------------------------------------------------------------------------

# Returns the list of currently existing lab VMs (one per line).
# A VM is considered "lab" if its name matches the controlplane-/worker- prefix.
list_existing_lab_vms() {
    multipass list --format csv 2>/dev/null \
        | awk -F, 'NR>1 {print $1}' \
        | grep -E "^(controlplane-|worker-)" \
        || true
}

# Asks the user a yes/no question. Returns 0 (yes) or 1 (no).
# Defaults to "no" if the user just presses Enter.
# If FORCE is true, skips the prompt and returns yes immediately.
confirm() {
    local prompt="$1"
    if [ "$FORCE" = "true" ]; then
        echo "  (--force is set, skipping confirmation)"
        return 0
    fi
    read -r -p "  $prompt [y/N]: " answer
    if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
        return 0
    else
        return 1
    fi
}

# ----------------------------------------------------------------------------
# Interactive menu
# ----------------------------------------------------------------------------

show_menu() {
    echo "|---------------------------------------------------------------------------"
    echo "| Lab management"
    echo "|---------------------------------------------------------------------------"
    echo "What do you want to do?"
    echo "  1) Build    — create lab VMs (fails if any already exist)"
    echo "  2) Destroy  — remove all lab VMs"
    echo "  3) Rebuild  — destroy and re-create from scratch"
    echo "  q) Quit"
    echo ""
    read -r -p "Choice [1/2/3/q]: " choice

    if [ "$choice" = "1" ]; then
        ACTION="build"
    elif [ "$choice" = "2" ]; then
        ACTION="destroy"
    elif [ "$choice" = "3" ]; then
        ACTION="rebuild"
    elif [ "$choice" = "q" ] || [ "$choice" = "Q" ]; then
        echo "Aborted."
        exit 0
    else
        echo "Invalid choice: $choice"
        exit 1
    fi
}

# ----------------------------------------------------------------------------
# Action: build
# ----------------------------------------------------------------------------

do_build() {
    echo ""
    echo "|---------------------------------------------------------------------------"
    echo "| Build — provisioning ${#VMS[@]} lab VMs"
    echo "|---------------------------------------------------------------------------"

    # Refuse to build if any lab VM already exists.
    EXISTING=$(list_existing_lab_vms)
    if [ -n "$EXISTING" ]; then
        echo ""
        echo "|---------------------------------------------------------------------------"
        echo "| ERROR: Lab VMs already exist. Build aborted."
        echo "|---------------------------------------------------------------------------"
        echo "Existing VMs:"
        echo "$EXISTING" | sed 's/^/    /'
        echo ""
        echo "To start over, use:"
        echo "    $0 rebuild"
        echo ""
        echo "To remove the existing VMs first, use:"
        echo "    $0 destroy"
        exit 1
    fi

    # Provision each VM sequentially.
    # Ensure the WSL2 host allows traffic into the Multipass bridge
    # before any VM boots, so cloud-init (and later Ansible) always
    # has working internet from the very first boot.
    "$FIX_NETWORK_SCRIPT"

    for vm in "${VMS[@]}"; do
        echo ""
        echo "  --- Launching $vm ---"
        "$LAUNCH_SCRIPT" "$vm"
    done

    # Synchronize ~/.ssh/config with the new IPs.
    echo ""
    echo "|---------------------------------------------------------------------------"
    echo "| Synchronizing ~/.ssh/config"
    echo "|---------------------------------------------------------------------------"
    "$SYNC_SCRIPT"

    # Brief pause for cloud-init to finalize before health check.
    echo ""
    echo "|---------------------------------------------------------------------------"
    echo "| Running health check"
    echo "|---------------------------------------------------------------------------"
    echo "  Waiting 15 seconds for cloud-init to finalize..."
    sleep 15
    "$CHECK_SCRIPT"
}

# ----------------------------------------------------------------------------
# Action: destroy
# ----------------------------------------------------------------------------

do_destroy() {
    EXISTING=$(list_existing_lab_vms)

    if [ -z "$EXISTING" ]; then
        echo ""
        echo "|---------------------------------------------------------------------------"
        echo "| No lab VMs found. Nothing to destroy."
        echo "|---------------------------------------------------------------------------"
        return 0
    fi

    echo ""
    echo "|---------------------------------------------------------------------------"
    echo "| Destroy — will remove the following lab VMs:"
    echo "|---------------------------------------------------------------------------"
    echo "$EXISTING" | sed 's/^/    /'
    echo ""

    if ! confirm "Are you sure?"; then
        echo "Aborted."
        exit 0
    fi

    echo ""
    echo "  Deleting VMs..."
    for vm in $EXISTING; do
        echo "    Deleting $vm..."
        multipass delete "$vm"
    done
    echo "  Purging..."
    multipass purge

    echo ""
    echo "|---------------------------------------------------------------------------"
    echo "| Destroy complete."
    echo "|---------------------------------------------------------------------------"
}

# ----------------------------------------------------------------------------
# Action: rebuild
# ----------------------------------------------------------------------------

do_rebuild() {
    EXISTING=$(list_existing_lab_vms)

    echo ""
    echo "|---------------------------------------------------------------------------"
    echo "| Rebuild — will destroy any existing lab VMs and create them again"
    echo "|---------------------------------------------------------------------------"
    if [ -n "$EXISTING" ]; then
        echo "Currently existing:"
        echo "$EXISTING" | sed 's/^/    /'
    else
        echo "  (no existing lab VMs found; will only build)"
    fi
    echo ""

    if ! confirm "Continue with rebuild?"; then
        echo "Aborted."
        exit 0
    fi

    # Destroy (forcing internally — we already confirmed once at the rebuild level).
    if [ -n "$EXISTING" ]; then
        echo ""
        echo "  Deleting existing VMs..."
        for vm in $EXISTING; do
            echo "    Deleting $vm..."
            multipass delete "$vm"
        done
        echo "  Purging..."
        multipass purge
    fi

    # Build (same logic as do_build, but we skip the existing-VMs check
    # because we just destroyed them).
    START_TIME=$(date +%s)

    # Ensure the WSL2 host allows traffic into the Multipass bridge
    # before any VM boots, so cloud-init (and later Ansible) always
    # has working internet from the very first boot.
    "$FIX_NETWORK_SCRIPT"

    for vm in "${VMS[@]}"; do
        echo ""
        echo "  --- Launching $vm ---"
        "$LAUNCH_SCRIPT" "$vm"
    done

    echo ""
    echo "|---------------------------------------------------------------------------"
    echo "| Synchronizing ~/.ssh/config"
    echo "|---------------------------------------------------------------------------"
    "$SYNC_SCRIPT"

    echo ""
    echo "|---------------------------------------------------------------------------"
    echo "| Running health check"
    echo "|---------------------------------------------------------------------------"
    echo "  Waiting 15 seconds for cloud-init to finalize..."
    sleep 15
    "$CHECK_SCRIPT"

    END_TIME=$(date +%s)
    ELAPSED=$((END_TIME - START_TIME))
    MINUTES=$((ELAPSED / 60))
    SECONDS=$((ELAPSED % 60))

    echo ""
    echo "|---------------------------------------------------------------------------"
    echo "| Rebuild complete in ${MINUTES}m ${SECONDS}s"
    echo "|---------------------------------------------------------------------------"
}

# ----------------------------------------------------------------------------
# Main flow
# ----------------------------------------------------------------------------

# If running interactively, show menu and capture the choice.
if [ "$ACTION" = "interactive" ]; then
    show_menu
fi

# Dispatch to the chosen action.
if [ "$ACTION" = "build" ]; then
    do_build
elif [ "$ACTION" = "destroy" ]; then
    do_destroy
elif [ "$ACTION" = "rebuild" ]; then
    do_rebuild
else
    echo "Unknown action: $ACTION"
    echo "Valid actions: build, destroy, rebuild"
    exit 1
fi
