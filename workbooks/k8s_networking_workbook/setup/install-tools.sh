#!/usr/bin/env bash
# ============================================================================
# install-tools.sh — user-level CLIs for the networking workbook (WSL host).
# ----------------------------------------------------------------------------
# Installs into ~/.local/bin, never system-wide, never touches the repo:
#   kind       — disposable clusters (Cilium, kube-proxy modes, OVN-K, BGP)
#   cilium     — cilium-cli: install, status, connectivity test
#   hubble     — Hubble CLI: flow observation
#   calicoctl  — pinned to the cluster's Calico (v3.33.0, ADR-039)
#
# Versions: latest GitHub release unless pinned through the environment,
# e.g. KIND_VERSION=v0.31.0 ./install-tools.sh. Every download is checked
# against the project's published SHA-256 when one exists; when none does,
# the script prints the hash and says so instead of pretending.
#
# Idempotent: a tool already at the wanted version is skipped.
#
# Not installed here (apt, needs sudo, optional on the host):
#   sudo apt-get install -y tshark conntrack
# The netlab VMs get the full toolset from netlab-cloud-init.yaml.
# ============================================================================
set -euo pipefail

BIN="${HOME}/.local/bin"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$BIN"

CALICOCTL_VERSION="${CALICOCTL_VERSION:-v3.33.0}"

log()  { printf '  %s\n' "$*"; }
head_() { printf '\n| %s\n' "$*"; }

# latest <owner/repo> — tag of the latest release, via the redirect (no API
# token, no rate limit).
latest() {
    curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest" \
        | sed -E 's#.*/tag/##'
}

# verify <file> <checksum-url> [name-in-sums-file]
verify() {
    local file="$1" url="$2" name="${3:-}" want
    if ! curl -fsSL -o "$TMP/sums" "$url" 2>/dev/null; then
        log "WARNING: no checksum published at $url"
        log "sha256: $(sha256sum "$file" | cut -d' ' -f1) — not verified"
        return 0
    fi
    if [ -n "$name" ]; then
        want="$(grep -E "[ *]${name}\$" "$TMP/sums" | awk '{print $1}')"
    else
        want="$(awk '{print $1; exit}' "$TMP/sums")"
    fi
    [ -n "$want" ] || { log "ERROR: $name not found in $url"; return 1; }
    echo "${want}  ${file}" | sha256sum -c --quiet - \
        || { log "ERROR: checksum mismatch for $file"; return 1; }
    log "sha256 verified"
}

have() { # have <binary> <version-string>
    command -v "$1" >/dev/null 2>&1 && "$1" version 2>/dev/null | grep -q -- "${2#v}"
}

# ---------------------------------------------------------------- kind
head_ "kind"
V="${KIND_VERSION:-$(latest kubernetes-sigs/kind)}"
if have kind "$V"; then log "kind $V already installed"; else
    U="https://github.com/kubernetes-sigs/kind/releases/download/${V}/kind-linux-amd64"
    curl -fsSL -o "$TMP/kind" "$U"
    verify "$TMP/kind" "${U}.sha256sum"
    install -m 0755 "$TMP/kind" "$BIN/kind"; log "kind $V installed"
fi

# ---------------------------------------------------------------- cilium-cli
head_ "cilium-cli"
V="${CILIUM_CLI_VERSION:-$(latest cilium/cilium-cli)}"
if have cilium "$V"; then log "cilium-cli $V already installed"; else
    U="https://github.com/cilium/cilium-cli/releases/download/${V}/cilium-linux-amd64.tar.gz"
    curl -fsSL -o "$TMP/cilium.tgz" "$U"
    verify "$TMP/cilium.tgz" "${U}.sha256sum"
    tar -xzf "$TMP/cilium.tgz" -C "$TMP" cilium
    install -m 0755 "$TMP/cilium" "$BIN/cilium"; log "cilium-cli $V installed"
fi

# ---------------------------------------------------------------- hubble
head_ "hubble"
V="${HUBBLE_VERSION:-$(latest cilium/hubble)}"
if have hubble "$V"; then log "hubble $V already installed"; else
    U="https://github.com/cilium/hubble/releases/download/${V}/hubble-linux-amd64.tar.gz"
    curl -fsSL -o "$TMP/hubble.tgz" "$U"
    verify "$TMP/hubble.tgz" "${U}.sha256sum"
    tar -xzf "$TMP/hubble.tgz" -C "$TMP" hubble
    install -m 0755 "$TMP/hubble" "$BIN/hubble"; log "hubble $V installed"
fi

# ---------------------------------------------------------------- calicoctl
head_ "calicoctl (pinned ${CALICOCTL_VERSION})"
if have calicoctl "$CALICOCTL_VERSION"; then log "calicoctl already installed"; else
    U="https://github.com/projectcalico/calico/releases/download/${CALICOCTL_VERSION}/calicoctl-linux-amd64"
    curl -fsSL -o "$TMP/calicoctl" "$U"
    verify "$TMP/calicoctl" "https://github.com/projectcalico/calico/releases/download/${CALICOCTL_VERSION}/SHA256SUMS" "calicoctl-linux-amd64"
    install -m 0755 "$TMP/calicoctl" "$BIN/calicoctl"; log "calicoctl installed"
fi

# ---------------------------------------------------------------- summary
head_ "Installed (record these in the README tracker)"
case ":$PATH:" in *":$BIN:"*) ;; *) log "NOTE: add $BIN to PATH";; esac
show() { printf '  %-10s %s\n' "$1" "$(eval "$2" 2>/dev/null | head -1)"; }
show kind      'kind version'
show cilium    'cilium version --client'
show hubble    'hubble version'
show calicoctl 'calicoctl version'
show kubectl   'kubectl version --client'
show helm      'helm version --short'
show docker    'docker --version'
