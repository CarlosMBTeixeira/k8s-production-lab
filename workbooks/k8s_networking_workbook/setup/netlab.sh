#!/usr/bin/env bash
# ============================================================================
# netlab.sh — plain Ubuntu VMs for Phase 1, Phase 2 and Containerlab.
# ----------------------------------------------------------------------------
#   setup/netlab.sh up [a|b|c|ab|all]  create (default ab), install tools,
#                                      mount the workbook at /workbook
#   setup/netlab.sh down               delete netlab-a/b/c (only those)
#   setup/netlab.sh status
#   setup/netlab.sh env                write setup/netlab.env (A_IP, B_IP, C_IP),
#                                      read by the two-host labs; runs after up
#   setup/netlab.sh shell a|b|c        open a shell (same as multipass shell)
#
# Why VMs and not the WSL host: the host's iptables rules on the Multipass
# bridge keep every VM reachable (repo ADR-009/010). A lab that flushes
# FORWARD or adds a MASQUERADE in the wrong place would cut off the lab.
# Inside a netlab VM the worst case is `netlab.sh down && netlab.sh up`.
#
# netlab-a and netlab-b stay Docker-free on purpose: Docker sets the
# FORWARD policy to DROP, which silently breaks hand-built routers, and
# hand-built bridges too once br_netfilter is loaded. netlab-c is the Docker + Containerlab VM
# (Phase 1 drills, Phase 4 labs 01 and 05).
# Do not run netlab and k8slab at the same time: the k8slab VMs take ~16 GB
# of the host's 19 GiB.
# ============================================================================
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WB="$(cd "$DIR/.." && pwd)"
CI="$DIR/netlab-cloud-init.yaml"

# name cpus mem disk
SPEC_a=(netlab-a 2 1536M 10G)
SPEC_b=(netlab-b 2 1536M 10G)
SPEC_c=(netlab-c 2 3G 15G)

FRR_IMAGE="${FRR_IMAGE:-quay.io/frrouting/frr:10.2.1}"
NETSHOOT_IMAGE="${NETSHOOT_IMAGE:-nicolaka/netshoot:v0.13}"

say() { printf '\n| %s\n' "$*"; }

exists() { multipass info "$1" >/dev/null 2>&1; }

up_one() {
    local -n s="SPEC_$1"
    local name="${s[0]}"
    if exists "$name"; then
        say "$name already exists — skipping create"
    else
        say "Launching $name (${s[1]} CPU, ${s[2]}, ${s[3]})"
        multipass launch 24.04 --name "$name" --cpus "${s[1]}" --memory "${s[2]}" \
            --disk "${s[3]}" --cloud-init "$CI"
    fi
    say "Waiting for cloud-init on $name"
    multipass exec "$name" -- cloud-init status --wait >/dev/null || true
    multipass exec "$name" -- test -f /var/tmp/netlab-ready \
        || echo "  WARNING: cloud-init did not finish cleanly; check: multipass exec $name -- cloud-init status --long"

    say "Mounting the workbook at $name:/workbook"
    if ! multipass info "$name" | grep -q '/workbook'; then
        multipass mount "$WB" "$name:/workbook" || {
            echo "  mount failed — copy instead:"
            echo "    multipass transfer --recursive \"$WB\" $name:/home/ubuntu/workbook"
        }
    fi

    if [ "$1" = c ]; then
        say "Docker + Containerlab on $name"
        if ! multipass exec "$name" -- command -v containerlab >/dev/null 2>&1; then
            # Official quick setup: installs Docker CE and Containerlab.
            multipass exec "$name" -- bash -c 'curl -sL https://containerlab.dev/setup | sudo -E bash -s "all"'
        fi
        multipass exec "$name" -- sudo usermod -aG docker ubuntu
        multipass exec "$name" -- sudo docker pull -q "$FRR_IMAGE"
        multipass exec "$name" -- sudo docker pull -q "$NETSHOOT_IMAGE"
    fi
    multipass info "$name" | grep -E 'State|IPv4'
}

write_env() {
    local f="$DIR/netlab.env" n ip
    : > "$f"
    for n in a b c; do
        ip="$(multipass info "netlab-$n" 2>/dev/null | awk '/IPv4/{print $2; exit}')"
        [ -n "$ip" ] && echo "${n^^}_IP=$ip" >> "$f"
    done
    say "Wrote $f"; cat "$f"
}

case "${1:-}" in
    env) write_env ;;
    up)
        case "${2:-ab}" in
            a|b|c) up_one "$2" ;;
            ab)  up_one a; up_one b ;;
            all) up_one a; up_one b; up_one c ;;
            *) echo "usage: $0 up [a|b|c|ab|all]"; exit 1 ;;
        esac
        write_env
        say "Done. Enter with: multipass shell netlab-a   (workbook at /workbook)" ;;
    down)
        for n in netlab-a netlab-b netlab-c; do
            if exists "$n"; then say "Deleting $n"; multipass delete --purge "$n"; fi
        done ;;
    status)
        multipass list | grep -E '^Name|^netlab-' || echo "no netlab VMs" ;;
    shell)
        case "${2:-}" in a|b|c) exec multipass shell "netlab-$2" ;; *) echo "usage: $0 shell a|b|c"; exit 1 ;; esac ;;
    *)
        sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
