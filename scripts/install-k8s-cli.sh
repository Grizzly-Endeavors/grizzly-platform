#!/usr/bin/env bash
#
# Install CLI tools for the grizzly-platform K8s cluster
#
# Installs:
#   - cilium    (Cilium CNI status, connectivity tests)
#   - hubble    (Hubble network flow observation)
#
# Usage:
#   ./scripts/install-k8s-cli.sh
#
# Environment variables (override defaults):
#   INSTALL_DIR  (default: /usr/local/bin)

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"

ARCH="$(uname -m)"
case "${ARCH}" in
    x86_64)  ARCH_SUFFIX="amd64" ;;
    aarch64) ARCH_SUFFIX="arm64" ;;
    *)       echo "Unsupported architecture: ${ARCH}"; exit 1 ;;
esac

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# =============================================================================
# Helpers
# =============================================================================

info()  { echo -e "\033[1;34m==>\033[0m $*"; }
ok()    { echo -e "\033[1;32m  ✓\033[0m $*"; }
fail()  { echo -e "\033[1;31m  ✗\033[0m $*"; exit 1; }

need_sudo() {
    if [[ "${INSTALL_DIR}" == /usr/local/bin ]] && [[ ${EUID} -ne 0 ]]; then
        echo "sudo"
    fi
}

fetch_latest_github_tag() {
    local repo="$1"
    curl -sI "https://github.com/${repo}/releases/latest" \
        | grep -i '^location:' \
        | sed 's|.*/||' \
        | tr -d '\r\n'
}

install_binary() {
    local name="$1" src="$2"
    chmod +x "${src}"
    $(need_sudo) install -m 0755 "${src}" "${INSTALL_DIR}/${name}"
    ok "${name} installed to ${INSTALL_DIR}/${name}"
}

# =============================================================================
# cilium CLI
# =============================================================================

install_cilium() {
    info "Installing cilium CLI..."

    local tag
    tag="$(fetch_latest_github_tag cilium/cilium-cli)"
    [[ -z "${tag}" ]] && fail "Could not determine latest cilium-cli release"

    local url="https://github.com/cilium/cilium-cli/releases/download/${tag}/cilium-linux-${ARCH_SUFFIX}.tar.gz"
    info "  Downloading ${tag}..."
    curl -sL "${url}" | tar xz -C "${TMPDIR}"
    install_binary "cilium" "${TMPDIR}/cilium"
}

# =============================================================================
# hubble CLI
# =============================================================================

install_hubble() {
    info "Installing hubble CLI..."

    local tag
    tag="$(fetch_latest_github_tag cilium/hubble)"
    [[ -z "${tag}" ]] && fail "Could not determine latest hubble release"

    local url="https://github.com/cilium/hubble/releases/download/${tag}/hubble-linux-${ARCH_SUFFIX}.tar.gz"
    info "  Downloading ${tag}..."
    curl -sL "${url}" | tar xz -C "${TMPDIR}"
    install_binary "hubble" "${TMPDIR}/hubble"
}

# =============================================================================
# Main
# =============================================================================

echo ""
echo "K8s CLI Installer"
echo "================="
echo "  Target: ${INSTALL_DIR}"
echo "  Arch:   linux/${ARCH_SUFFIX}"
echo ""

install_cilium
install_hubble

echo ""
info "Done! Quick start:"
echo ""
echo "  # Check Cilium health"
echo "  cilium status"
echo ""
echo "  # Run connectivity test"
echo "  cilium connectivity test"
echo ""
echo "  # Observe network flows"
echo "  cilium hubble port-forward &"
echo "  hubble observe --follow"
echo ""
