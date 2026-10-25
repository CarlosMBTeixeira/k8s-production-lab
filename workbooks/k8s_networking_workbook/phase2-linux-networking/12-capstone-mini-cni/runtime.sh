#!/usr/bin/env bash
# ============================================================================
# runtime.sh — the part of containerd that talks to CNI, in 40 lines.
#
#   runtime.sh add <pod>      create netns /run/netns/<pod>, call the plugin's ADD
#   runtime.sh del <pod>      call DEL, delete the netns
#   runtime.sh check <pod>    call CHECK
#   runtime.sh version        call VERSION
#
# Like containerd: the FIRST config file in /etc/cni/net.d (lexical order)
# wins; its "type" names the binary in /opt/cni/bin; the config goes on stdin;
# everything else is environment variables (CNI spec 1.0, section 3).
# ============================================================================
set -euo pipefail
CONF_DIR=${CONF_DIR:-/etc/cni/net.d}
BIN_DIR=${BIN_DIR:-/opt/cni/bin}

conf=$(ls "$CONF_DIR"/*.conf 2>/dev/null | sort | head -1)
[ -n "$conf" ] || { echo "no config in $CONF_DIR" >&2; exit 1; }
type=$(jq -r .type "$conf")
plugin="$BIN_DIR/$type"
[ -x "$plugin" ] || { echo "plugin $plugin not found or not executable" >&2; exit 1; }

cmd=${1:-}; pod=${2:-}
call() { # COMMAND
    CNI_COMMAND=$1 CNI_CONTAINERID="$(printf %s "$pod" | sha256sum | cut -c1-16)" \
    CNI_NETNS="/run/netns/$pod" CNI_IFNAME=eth0 CNI_PATH="$BIN_DIR" \
        "$plugin" < "$conf"
}

case "$cmd" in
    add)
        [ -n "$pod" ] || { echo "usage: $0 add <pod>"; exit 1; }
        ip netns add "$pod"
        if ! call ADD; then echo "ADD failed; removing netns" >&2; ip netns del "$pod"; exit 1; fi
        # what the runtime does with the result's DNS: write the pod's resolv.conf
        mkdir -p "/etc/netns/$pod"
        echo "nameserver $(resolvectl dns "$(ip -o route show default | awk '{print $5}')" | awk '{print $NF}')" \
            > "/etc/netns/$pod/resolv.conf" ;;
    del)
        [ -n "$pod" ] || { echo "usage: $0 del <pod>"; exit 1; }
        call DEL || echo "DEL returned non-zero" >&2
        ip netns pids "$pod" 2>/dev/null | xargs -r kill 2>/dev/null || true
        ip netns del "$pod" 2>/dev/null || true
        rm -rf "/etc/netns/$pod" ;;
    check) call CHECK && echo "CHECK ok" ;;
    version) CNI_COMMAND=VERSION "$plugin" < "$conf" ;;
    *) sed -n '3,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
