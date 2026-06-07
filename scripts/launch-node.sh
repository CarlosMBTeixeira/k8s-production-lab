#!/bin/bash
# ============================================================================
# launch-node.sh — Provision a Multipass VM for the Kubernetes lab.
# ----------------------------------------------------------------------------
# Renders the cloud-init template with the given hostname and launches a new
# Ubuntu 24.04 VM via Multipass. All other VM parameters (CPU, RAM, disk)
# have sensible defaults that can be overridden via positional arguments.
#
# Usage:    ./scripts/launch-node.sh <hostname> [cpus] [memory] [disk]
# Example:  ./scripts/launch-node.sh controlplane-1 2 4G 20G
# ============================================================================

# Enable strict mode for safer scripting:
#   -e            : exit immediately if any command fails
#   -u            : treat unset variables as an error and exit
#   -o pipefail   : a pipeline fails if any command in it fails (not just the last)
set -euo pipefail

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------

# Required argument: hostname for the new VM.
# The ${1:?msg} syntax exits with an error if $1 is unset or empty.
# Exported so that envsubst (a child process) can pick it up from the environment.
export HOSTNAME="${1:?Usage: $0 <hostname> [cpus] [memory] [disk]}"

# Optional arguments with defaults.
# The ${N:-default} syntax uses 'default' if $N is unset or empty.
CPUS="${2:-2}"        # Number of vCPUs assigned to the VM
MEMORY="${3:-4G}"     # RAM allocated to the VM
DISK="${4:-20G}"      # Disk size for the VM

# ----------------------------------------------------------------------------
# Template rendering
# ----------------------------------------------------------------------------

# Resolve the path to the cloud-init template relative to this script's location.
# $0 is the script's invocation path; dirname extracts its parent directory.
# This ensures the script works regardless of the caller's current directory.
TEMPLATE="$(dirname "$0")/../cloud-init/node.yaml"

# Create a unique temporary file to hold the rendered template.
# mktemp generates a random filename in /tmp with safe permissions (0600).
# The --suffix flag makes the file end in .yaml for clarity if inspected.
RENDERED_DIR="$(dirname "$0")/../cloud-init/.rendered"
mkdir -p "$RENDERED_DIR"
RENDERED="${RENDERED_DIR}/${HOSTNAME}.yaml"

# Register a cleanup hook: delete the temporary file when the script exits,
# regardless of exit reason (success, error, Ctrl+C, signal).
# Prevents accumulation of leftover files in /tmp over many runs.
trap "rm -f $RENDERED" EXIT

# Render the template: envsubst reads from stdin, replaces ${VAR} placeholders
# with values from the environment, and writes the result to stdout.
# Input is the template; output is the temp file. The original template is untouched.
envsubst < "$TEMPLATE" > "$RENDERED"

# ----------------------------------------------------------------------------
# Launch the VM
# ----------------------------------------------------------------------------

# Visual section divider for clearer log output during execution.
echo "|---------------------------------------------------------------------------"
echo "| Launching ${HOSTNAME} (${CPUS} CPU, ${MEMORY} RAM, ${DISK} disk)..."
echo "|---------------------------------------------------------------------------"

# Run multipass to create the VM.
# Backslashes at line ends continue the command across multiple lines for readability.
# Quoting variables protects against arguments containing spaces or special chars.
multipass launch 24.04 \
    --name "$HOSTNAME" \
    --cpus "$CPUS" \
    --memory "$MEMORY" \
    --disk "$DISK" \
    --cloud-init "$RENDERED"

# ----------------------------------------------------------------------------
# Post-launch confirmation
# ----------------------------------------------------------------------------

# Visual section divider before showing the final VM status.
echo "|---------------------------------------------------------------------------"
echo "| Done. VM '${HOSTNAME}' status:"
echo "|---------------------------------------------------------------------------"

# Show only the most relevant info from `multipass info` output:
#   - State (Running, Stopped, etc.)
#   - IPv4 address (needed for SSH access)
# grep -E enables extended regex for the alternation pattern.
multipass info "$HOSTNAME" | grep -E "(State|IPv4)"
