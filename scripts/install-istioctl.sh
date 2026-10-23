#!/bin/bash
# ============================================================================
# install-istioctl.sh — install istioctl on the WSL2 host, pinned to the
# same version as the control plane 09_istio_kiali.sh installs, so the
# client never drifts from the mesh it inspects (workbooks/istio_svc_mesh_workbook).
# ----------------------------------------------------------------------------
# Downloads the official release tarball from GitHub, verifies its
# published SHA-256, installs to ~/.local/bin. Idempotent: does nothing if
# the right version is already there.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="$(sed -n 's/^ISTIO_CHART_VERSION="\(.*\)"/\1/p' "${SCRIPT_DIR}/pipeline/09_istio_kiali.sh")"
DEST="${HOME}/.local/bin"
ARCH="linux-amd64"

if command -v istioctl >/dev/null 2>&1 && istioctl version --remote=false 2>/dev/null | grep -q " ${VERSION}$"; then
    echo "istioctl ${VERSION} already installed: $(command -v istioctl)"
    exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
url="https://github.com/istio/istio/releases/download/${VERSION}/istioctl-${VERSION}-${ARCH}.tar.gz"

echo "Downloading istioctl ${VERSION}..."
curl -fsSL -o "${tmp}/istioctl.tgz" "${url}"
curl -fsSL -o "${tmp}/istioctl.tgz.sha256" "${url}.sha256"
(cd "${tmp}" && echo "$(awk '{print $1}' istioctl.tgz.sha256)  istioctl.tgz" | sha256sum -c - >/dev/null)
echo "  checksum OK"

tar -xzf "${tmp}/istioctl.tgz" -C "${tmp}"
mkdir -p "${DEST}"
install -m 0755 "${tmp}/istioctl" "${DEST}/istioctl"
echo "Installed ${DEST}/istioctl ($("${DEST}/istioctl" version --remote=false))"

case ":${PATH}:" in
    *":${DEST}:"*) ;;
    *) echo "NOTE: ${DEST} is not on PATH. Add: export PATH=\"\${HOME}/.local/bin:\${PATH}\"" ;;
esac
