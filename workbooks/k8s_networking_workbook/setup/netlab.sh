#!/usr/bin/env bash
# ============================================================================
# netlab.sh — two plain Ubuntu VMs for Phase 1, Phase 2 and Containerlab.
# ----------------------------------------------------------------------------
#   setup/netlab.sh up [a|b|both]   create (default both), install tools,
#                                   mount the workbook at /workbook
#   setup/netlab.sh down            delete netlab-a and netlab-b (only those)
#   setup/netlab.sh status
#   setup/netlab.sh shell a|b       open a shell (same as multipass shell)
#
# Why VMs and not the WSL host: the host's iptables rules on the Multipass
# bridge keep every VM reachable (repo ADR-009/010). A lab that flushes
# FORWARD or adds a MASQUERADE in the wrong place would cut off the lab.
# Inside a netlab VM the worst case is `netlab.sh down && netlab.sh up`.
#
# netlab-a also gets Docker + Containerlab (and the FRR / netshoot images).
# Do not run netlab and k8slab at the same time unless a lab says so: the
# k8slab VMs take ~16 GB of the host's 19 GiB.
# ============================================================================
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WB="$(cd "$DIR/.." && pwd)"
CI="$DIR/netlab-cloud-init.yaml"

# name cpus mem disk
SPEC_a=(netlab-a 2 3G 15G)
SPEC_b=(netlab-b 2 1536M 10G)

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

    if [ "$1" = a ]; then
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

case "${1:-}" in
    up)
        case "${2:-both}" in
            a) up_one a ;; b) up_one b ;; both) up_one a; up_one b ;;
            *) echo "usage: $0 up [a|b|both]"; exit 1 ;;
        esac
        say "Done. Enter with: multipass shell netlab-a   (workbook at /workbook)" ;;
    down)
        for n in netlab-a netlab-b; do
            if exists "$n"; then say "Deleting $n"; multipass delete --purge "$n"; fi
        done ;;
    status)
        multipass list | grep -E '^Name|^netlab-' || echo "no netlab VMs" ;;
    shell)
        case "${2:-}" in a|b) exec multipass shell "netlab-$2" ;; *) echo "usage: $0 shell a|b"; exit 1 ;; esac ;;
    *)
        sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
