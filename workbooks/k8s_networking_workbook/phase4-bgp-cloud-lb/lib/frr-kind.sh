#!/usr/bin/env bash
# ============================================================================
# frr-kind.sh up <kind-cluster> <frr.conf.tpl> | down <kind-cluster> | vtysh
#
# The "outside world" for the Phase 4 kind labs, all on the WSL host's Docker:
#
#   lab-client 172.30.99.10 ── [lab-ext 172.30.99.0/24] ── lab-frr ── [kind network] ── kind nodes
#                                                      (AS 65000, routes)        (AS 64512)
#
# - lab-frr: FRR router on both networks. Its frr.conf is rendered from the
#   lab's template with KIND_NET, FRR_IP and EXT_NET (envsubst).
# - lab-client: netshoot on lab-ext only; default route via lab-frr. It can
#   reach anything lab-frr has a route for — i.e. what the cluster advertises.
# - Every kind node gets a static route to lab-ext via lab-frr (the "fabric"
#   return path), so replies don't take the Docker host's default route.
#
# Prints FRR_IP / KIND_NET / node IPs at the end. Idempotent: `up` replaces.
# ============================================================================
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRR_IMAGE=${FRR_IMAGE:-quay.io/frrouting/frr:10.2.1}
NETSHOOT=${NETSHOOT_IMAGE:-nicolaka/netshoot:v0.13}
export EXT_NET=172.30.99.0/24
EXT_FRR=172.30.99.2
EXT_CLIENT=172.30.99.10
STATE=/tmp/lab-frr-kind; mkdir -p "$STATE"

kind_net() { docker network inspect kind | jq -r '.[0].IPAM.Config[] | select(.Subnet | test("\\.")) | .Subnet'; }
ip_on() { docker inspect -f "{{(index .NetworkSettings.Networks \"$2\").IPAddress}}" "$1"; }

down() {
    local cluster=${1:-}
    if [ -n "$cluster" ]; then
        for n in $(kind get nodes --name "$cluster" 2>/dev/null); do
            docker exec "$n" ip route del "$EXT_NET" 2>/dev/null || true
        done
    fi
    docker rm -f lab-frr lab-client >/dev/null 2>&1 || true
    docker network rm lab-ext >/dev/null 2>&1 || true
    echo "frr-kind: down"
}

up() {
    local cluster=${1:?usage: up <kind-cluster> <frr.conf.tpl>} tpl=${2:?usage: up <kind-cluster> <frr.conf.tpl>}
    kind get nodes --name "$cluster" >/dev/null
    docker rm -f lab-frr lab-client >/dev/null 2>&1 || true
    docker network inspect lab-ext >/dev/null 2>&1 || docker network create lab-ext --subnet "$EXT_NET" >/dev/null

    export KIND_NET; KIND_NET=$(kind_net)
    docker run -d --name lab-frr --privileged --network kind \
        --sysctl net.ipv4.ip_forward=1 "$FRR_IMAGE" >/dev/null
    docker network connect --ip "$EXT_FRR" lab-ext lab-frr
    export FRR_IP; FRR_IP=$(ip_on lab-frr kind)

    envsubst < "$tpl" > "$STATE/frr.conf"
    docker cp "$DIR/daemons" lab-frr:/etc/frr/daemons
    docker cp "$STATE/frr.conf" lab-frr:/etc/frr/frr.conf
    docker exec lab-frr sh -c 'touch /etc/frr/vtysh.conf; chown -R frr:frr /etc/frr' >/dev/null
    docker restart lab-frr >/dev/null

    docker run -d --name lab-client --network lab-ext --ip "$EXT_CLIENT" --cap-add NET_ADMIN \
        "$NETSHOOT" sleep infinity >/dev/null
    docker exec lab-client ip route replace default via "$EXT_FRR"

    for n in $(kind get nodes --name "$cluster"); do
        docker exec "$n" ip route replace "$EXT_NET" via "$FRR_IP"
    done

    echo "frr-kind: up"
    echo "  KIND_NET=$KIND_NET  FRR_IP=$FRR_IP (AS 65000)  client=$EXT_CLIENT (lab-client)"
    for n in $(kind get nodes --name "$cluster"); do printf '  %-32s %s\n' "$n" "$(ip_on "$n" kind)"; done
    echo "  vtysh:  docker exec -it lab-frr vtysh"
}

case "${1:-}" in
    up) up "${2:-}" "${3:-}" ;;
    down) down "${2:-}" ;;
    vtysh) exec docker exec -it lab-frr vtysh ;;
    *) sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
