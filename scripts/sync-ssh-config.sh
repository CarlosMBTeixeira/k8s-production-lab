#!/bin/bash
# ============================================================================
# sync-ssh-config.sh — Regenerate ~/.ssh/config block for lab VMs.
# ----------------------------------------------------------------------------
# Reads the current IPs from `multipass list` and rewrites the lab section
# of ~/.ssh/config between managed markers. Any content outside the markers
# is preserved untouched.
#
# Idempotent: running the script multiple times in a row produces the exact
# same file (no accumulation of blank lines or duplicated blocks).
#
# Usage:    ./scripts/sync-ssh-config.sh
# Example:  ./scripts/sync-ssh-config.sh
# ============================================================================

set -euo pipefail

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------

CONFIG_FILE="$HOME/.ssh/config"

# Markers delimit the managed block. Anything between these markers will be
# replaced on each run; anything outside is preserved.
MARKER_START="# === K8S LAB BEGIN (managed by sync-ssh-config.sh) ==="
MARKER_END="# === K8S LAB END ==="

# Alias map: short SSH alias -> Multipass VM name.
# Add new VMs here and to HOSTS_ORDER below.
declare -A ALIASES=(
    ["cp-1"]="controlplane-1"
    ["cp-2"]="controlplane-2"
    ["w-1"]="worker-1"
    ["w-2"]="worker-2"
)

# Explicit order for the generated block (associative arrays in bash are
# unordered, so we iterate this list to keep output deterministic).
HOSTS_ORDER=(cp-1 cp-2 w-1 w-2)

# ----------------------------------------------------------------------------
# Build the new managed block
# ----------------------------------------------------------------------------

NEW_BLOCK="$MARKER_START"$'\n'

for i in "${!HOSTS_ORDER[@]}"; do
    alias="${HOSTS_ORDER[$i]}"
    vm_name="${ALIASES[$alias]}"

    # Extract IP from multipass info CSV output.
    # NR==2 skips the header row; column 3 holds the IPv4 address.
    ip=$(multipass info "$vm_name" --format csv 2>/dev/null | awk -F, 'NR==2 {print $3}')

    # Skip silently if VM is not found or has no IP yet.
    if [ -z "$ip" ]; then
        echo "⚠️  Could not resolve IP for $vm_name — skipping."
        continue
    fi

    # Blank line separator between hosts, but not before the first one.
    [ "$i" -gt 0 ] && NEW_BLOCK+=$'\n'

    NEW_BLOCK+="Host $alias"$'\n'
    NEW_BLOCK+="    HostName $ip"$'\n'
    NEW_BLOCK+="    User ubuntu"$'\n'
    NEW_BLOCK+="    IdentityFile ~/.ssh/k8slab"$'\n'
    NEW_BLOCK+="    StrictHostKeyChecking no"$'\n'
    NEW_BLOCK+="    UserKnownHostsFile /dev/null"$'\n'
    NEW_BLOCK+="    LogLevel ERROR"
done

# Add closing marker on its own line.
NEW_BLOCK+=$'\n'"$MARKER_END"

# ----------------------------------------------------------------------------
# Ensure ~/.ssh exists with correct permissions
# ----------------------------------------------------------------------------

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$CONFIG_FILE"

# ----------------------------------------------------------------------------
# Rewrite the config file
# ----------------------------------------------------------------------------

# Use a temp file to build the new content safely.
# Trap ensures cleanup even if the script fails mid-way.
TMP_FILE=$(mktemp)
trap "rm -f $TMP_FILE" EXIT

# Copy all lines from the existing config EXCEPT any block between the markers.
# This preserves user-added SSH entries outside the managed block.
awk -v start="$MARKER_START" -v end="$MARKER_END" '
    $0 == start { skip = 1; next }
    $0 == end   { skip = 0; next }
    !skip       { print }
' "$CONFIG_FILE" > "$TMP_FILE"

# Strip any trailing blank lines from the preserved content. Prevents blank
# lines from accumulating between user content and the managed block over
# multiple runs.
sed -i -e :a -e '/^$/{$d;N;ba' -e '}' "$TMP_FILE"

# Append the new managed block.
# If the temp file is non-empty, prepend a blank line for visual separation.
if [ -s "$TMP_FILE" ]; then
    printf '\n' >> "$TMP_FILE"
fi
printf '%s\n' "$NEW_BLOCK" >> "$TMP_FILE"

# Atomic replace and restore permissions.
mv "$TMP_FILE" "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

# ----------------------------------------------------------------------------
# Visual confirmation
# ----------------------------------------------------------------------------

echo "|---------------------------------------------------------------------------"
echo "| ~/.ssh/config updated. Current lab hosts:"
echo "|---------------------------------------------------------------------------"
grep -E "^Host |HostName " "$CONFIG_FILE" | sed 's/^/    /'
