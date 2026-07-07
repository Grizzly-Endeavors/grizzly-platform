#!/usr/bin/env bash
#
# Bootstrap a new device with SSH-key auth and passwordless sudo
#
# Connects to a remote host via password auth, deploys an SSH public key,
# installs sudo if missing, configures passwordless sudo, then verifies both.
#
# Prerequisites:
#   - Password-based SSH access to the target (will be used once)
#   - The target user must be able to escalate to root (su or existing sudo)
#
# Usage:
#   ./scripts/bootstrap-ssh-sudo.sh --host 10.0.0.100
#   ./scripts/bootstrap-ssh-sudo.sh --host 10.0.0.100 --user admin --port 2222
#   ./scripts/bootstrap-ssh-sudo.sh --host 10.0.0.100 --key ~/.ssh/id_rsa.pub
#   ./scripts/bootstrap-ssh-sudo.sh --host 10.0.0.100 --skip-sudo

set -euo pipefail

# Prevent SSH from trying gui askpass — force terminal prompts
unset SSH_ASKPASS
export SSH_ASKPASS_REQUIRE=never

# =============================================================================
# Configuration
# =============================================================================

HOST=""
USER="${USER:-$(whoami)}"
PORT="22"
SSH_KEY=""
SKIP_SUDO=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# =============================================================================
# Helper functions
# =============================================================================

info()  { echo -e "${GREEN}==> $*${NC}"; }
warn()  { echo -e "${YELLOW}==> WARNING: $*${NC}"; }
error() { echo -e "${RED}==> ERROR: $*${NC}" >&2; }

usage() {
    cat <<'EOF'
Usage: bootstrap-ssh-sudo.sh --host <host> [options]

Options:
  --host <host>       Target hostname or IP (required)
  --user <user>       Remote username (default: current user)
  --port <port>       SSH port (default: 22)
  --key <path>        SSH public key to deploy (default: auto-detect)
  --skip-sudo         Only deploy SSH key, skip sudo setup
  --help              Show this help
EOF
    exit 0
}

# =============================================================================
# Argument parsing
# =============================================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)  HOST="$2"; shift 2 ;;
        --user)  USER="$2"; shift 2 ;;
        --port)  PORT="$2"; shift 2 ;;
        --key)   SSH_KEY="$2"; shift 2 ;;
        --skip-sudo) SKIP_SUDO=true; shift ;;
        --help)  usage ;;
        *)
            error "Unknown option: $1"
            usage
            ;;
    esac
done

if [[ -z "${HOST}" ]]; then
    error "--host is required"
    usage
fi

# =============================================================================
# Detect SSH public key
# =============================================================================

detect_ssh_key() {
    if [[ -n "${SSH_KEY}" ]]; then
        if [[ ! -f "${SSH_KEY}" ]]; then
            error "SSH key not found: ${SSH_KEY}"
            exit 1
        fi
        return
    fi

    # Prefer ed25519, fall back to rsa
    for candidate in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub ~/.ssh/id_ecdsa.pub; do
        if [[ -f "${candidate}" ]]; then
            SSH_KEY="${candidate}"
            return
        fi
    done

    error "No SSH public key found. Generate one with: ssh-keygen -t ed25519"
    exit 1
}

# =============================================================================
# Remote script: install sudo + configure sudoers (runs as root)
# =============================================================================

build_root_script() {
    local target_user="$1"
    cat <<'OUTER_EOF'
set -euo pipefail

install_sudo() {
    if command -v sudo >/dev/null 2>&1; then
        echo "SUDO_PRESENT"
        return
    fi
    echo "SUDO_MISSING — installing..."
    if [ -f /etc/debian_version ]; then
        apt-get update -qq && apt-get install -y -qq sudo
    elif [ -f /etc/redhat-release ]; then
        if command -v dnf >/dev/null 2>&1; then
            dnf install -y -q sudo
        else
            yum install -y -q sudo
        fi
    elif [ -f /etc/arch-release ]; then
        pacman -Sy --noconfirm sudo
    elif [ -f /etc/alpine-release ]; then
        apk add --quiet sudo
    elif [ -f /etc/SuSE-release ] || [ -f /etc/SUSE-brand ]; then
        zypper install -y sudo
    else
        echo "SUDO_INSTALL_FAILED: unknown distro"
        exit 1
    fi
    if command -v sudo >/dev/null 2>&1; then
        echo "SUDO_INSTALLED"
    else
        echo "SUDO_INSTALL_FAILED"
        exit 1
    fi
}

configure_sudoers() {
OUTER_EOF

    # Inject the target username into the heredoc
    echo "    local sudoers_file=\"/etc/sudoers.d/${target_user}\""
    echo "    echo '${target_user} ALL=(ALL) NOPASSWD: ALL' > \"\${sudoers_file}\""

    cat <<'OUTER_EOF'
    chmod 0440 "${sudoers_file}"
    if command -v visudo >/dev/null 2>&1; then
        if visudo -c -f "${sudoers_file}" >/dev/null 2>&1; then
            echo "SUDOERS_OK"
        else
            rm -f "${sudoers_file}"
            echo "SUDOERS_INVALID"
            exit 1
        fi
    else
        echo "SUDOERS_OK_NO_VISUDO"
    fi
}

install_sudo
configure_sudoers
OUTER_EOF
}

# =============================================================================
# Main
# =============================================================================

info "Bootstrap SSH + sudo: ${USER}@${HOST}:${PORT}"
echo ""

detect_ssh_key
info "Using SSH key: ${SSH_KEY}"

SSH_OPTS=(-p "${PORT}" -o StrictHostKeyChecking=accept-new)

# --- Step 1: Deploy SSH key ---
info "Deploying SSH public key (you will be prompted for a password)..."
if ssh-copy-id -i "${SSH_KEY}" -p "${PORT}" -o StrictHostKeyChecking=accept-new "${USER}@${HOST}"; then
    info "SSH key deployed"
else
    error "ssh-copy-id failed"
    exit 1
fi

# Verify key auth works
info "Verifying key-based SSH..."
if ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${USER}@${HOST}" "echo ok" >/dev/null 2>&1; then
    info "SSH key auth works"
else
    error "SSH key auth verification failed"
    exit 1
fi

# --- Step 2: Install sudo + passwordless sudoers ---
if [[ "${SKIP_SUDO}" == true ]]; then
    info "Skipping sudo setup (--skip-sudo)"
    echo ""
    info "Done! Connect with: ssh ${USER}@${HOST} -p ${PORT}"
    exit 0
fi

info "Configuring sudo (will install if missing)..."

REMOTE_SCRIPT="$(build_root_script "${USER}")"

# Upload the root script to the remote machine first
info "Uploading setup script..."
REMOTE_TMP="/tmp/bootstrap-sudo-$$.sh"
ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${USER}@${HOST}" "cat > '${REMOTE_TMP}' && chmod +x '${REMOTE_TMP}'" < <(echo "${REMOTE_SCRIPT}")

# Check if sudo exists on the remote
HAS_SUDO=$(ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${USER}@${HOST}" \
    "command -v sudo >/dev/null 2>&1 && echo yes || echo no")

SUCCEEDED=false

if [[ "${HAS_SUDO}" == "yes" ]]; then
    # Try non-interactive sudo first (in case user has NOPASSWD already)
    info "Trying passwordless sudo..."
    if ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${USER}@${HOST}" \
        "sudo -n bash '${REMOTE_TMP}'" 2>/dev/null | grep -q "SUDOERS_OK"; then
        SUCCEEDED=true
        info "Sudo configured (had passwordless sudo)"
    else
        # Try sudo with password — needs TTY for the password prompt
        info "Trying sudo with password..."
        if ssh "${SSH_OPTS[@]}" -tt "${USER}@${HOST}" \
            "sudo bash '${REMOTE_TMP}'" 2>&1 | grep -q "SUDOERS_OK"; then
            SUCCEEDED=true
            info "Sudo configured via sudo"
        fi
    fi
fi

if [[ "${SUCCEEDED}" != true ]]; then
    # Fall back to su (needs root password)
    if [[ "${HAS_SUDO}" == "yes" ]]; then
        warn "sudo failed, falling back to su"
    else
        info "No sudo on target, using su"
    fi
    info "You will be prompted for the ROOT password..."

    # Run su interactively — no pipe so the TTY stays attached for the
    # password prompt. The script writes a marker file on success; we
    # check for that file afterwards instead of grepping output.
    ssh "${SSH_OPTS[@]}" -tt "${USER}@${HOST}" \
        "su -c 'bash ${REMOTE_TMP} && touch ${REMOTE_TMP}.ok' root" || true

    if ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${USER}@${HOST}" \
        "test -f '${REMOTE_TMP}.ok'" 2>/dev/null; then
        SUCCEEDED=true
        info "Sudo configured via su"
    fi
fi

# Clean up remote temp file
ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${USER}@${HOST}" "rm -f '${REMOTE_TMP}' '${REMOTE_TMP}.ok'" 2>/dev/null || true

if [[ "${SUCCEEDED}" != true ]]; then
    error "Failed to configure sudo (neither sudo nor su worked)"
    exit 1
fi

# Verify passwordless sudo
info "Verifying passwordless sudo..."
if ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${USER}@${HOST}" "sudo -n whoami" 2>/dev/null | grep -q "root"; then
    info "Passwordless sudo works"
else
    error "Passwordless sudo verification failed"
    exit 1
fi

echo ""
info "Done! Connect with: ssh ${USER}@${HOST} -p ${PORT}"
