#!/usr/bin/env bash
#
# Build a preseeded Debian 13 ISO for laptops
#
# Creates a custom Debian netinst ISO with an embedded preseed configuration
# for fully unattended installation. DHCP networking, swap, SSH key auth.
#
# Prerequisites:
#   - xorriso (apt install xorriso)
#   - An SSH public key at ~/.ssh/id_ed25519.pub (or set SSH_PUBLIC_KEY env var)
#
# Environment variables:
#   LAPTOP_PASSWORD    - Install user password (prompted if not set)
#   SSH_PUBLIC_KEY     - SSH public key string (defaults to ~/.ssh/id_ed25519.pub)
#
# Usage:
#   ./scripts/build-laptop-iso.sh <debian-netinst.iso> --hostname lab-laptop
#   sudo ./scripts/build-laptop-iso.sh <debian-netinst.iso> --hostname lab-laptop --usb /dev/sdc

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PRESEED_TEMPLATE="${REPO_ROOT}/configs/laptop/preseed.cfg"
BUILD_DIR="${REPO_ROOT}/build"

# Defaults
HOSTNAME=""
USB_DEVICE=""

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

cleanup() {
    if [[ -d "${WORK_DIR:-}" ]]; then
        chmod -R u+w "${WORK_DIR}" 2>/dev/null || true
        rm -rf "${WORK_DIR}"
    fi
}

trap cleanup EXIT

usage() {
    cat <<'EOF'
Usage: build-laptop-iso.sh <debian-netinst.iso> --hostname <name> [options]

Required:
  <debian-netinst.iso>    Path to official Debian 13 netinst ISO
  --hostname <name>       Hostname (e.g., lab-laptop)

Options:
  --usb <device>          Flash ISO to USB device after building
  --help                  Show this help
EOF
    exit 0
}

# =============================================================================
# Argument parsing
# =============================================================================

if [[ $# -lt 1 ]]; then
    usage
fi

SOURCE_ISO="$1"
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --hostname)  HOSTNAME="$2"; shift 2 ;;
        --usb)       USB_DEVICE="$2"; shift 2 ;;
        --help)      usage ;;
        *)
            error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required args
if [[ -z "${HOSTNAME}" ]]; then
    error "--hostname is required"
    usage
fi

if [[ ! -f "${SOURCE_ISO}" ]]; then
    error "ISO not found: ${SOURCE_ISO}"
    exit 1
fi

# Derived paths
WORK_DIR="${BUILD_DIR}/iso-work-${HOSTNAME}"
OUTPUT_ISO="${BUILD_DIR}/debian-13-${HOSTNAME}.iso"

# =============================================================================
# Prerequisites
# =============================================================================

info "Building install ISO for ${HOSTNAME}"

if ! command -v xorriso &>/dev/null; then
    error "xorriso is not installed. Install it with: sudo apt install xorriso"
    exit 1
fi

# SSH public key
if [[ -n "${SSH_PUBLIC_KEY:-}" ]]; then
    PUBKEY="${SSH_PUBLIC_KEY}"
elif [[ -f "${HOME}/.ssh/id_ed25519.pub" ]]; then
    PUBKEY="$(cat "${HOME}/.ssh/id_ed25519.pub")"
else
    error "No SSH public key found. Set SSH_PUBLIC_KEY or create ~/.ssh/id_ed25519.pub"
    exit 1
fi

# Install password
if [[ -z "${LAPTOP_PASSWORD:-}" ]]; then
    echo -n "Enter install password for user 'bearf': "
    read -rs LAPTOP_PASSWORD
    echo
    if [[ -z "${LAPTOP_PASSWORD}" ]]; then
        error "Password cannot be empty"
        exit 1
    fi
fi

# USB device validation
if [[ -n "${USB_DEVICE}" ]]; then
    if [[ ! -b "${USB_DEVICE}" ]]; then
        error "Not a block device: ${USB_DEVICE}"
        exit 1
    fi

    DEVICE_NAME="$(basename "${USB_DEVICE}")"
    REMOVABLE="$(cat "/sys/block/${DEVICE_NAME}/removable" 2>/dev/null || echo "0")"
    if [[ "${REMOVABLE}" != "1" ]]; then
        error "${USB_DEVICE} is not a removable device. Refusing to flash."
        exit 1
    fi

    if [[ ${EUID} -ne 0 ]]; then
        error "Must run as root to flash USB. Use: sudo $0 $*"
        exit 1
    fi
fi

# =============================================================================
# Prepare build directory
# =============================================================================

info "Preparing build directory..."
mkdir -p "${BUILD_DIR}"
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

# =============================================================================
# Extract original ISO
# =============================================================================

info "Extracting original ISO..."
xorriso -osirrox on -indev "${SOURCE_ISO}" -extract / "${WORK_DIR}/iso" 2>/dev/null

# Extract MBR for hybrid boot
dd if="${SOURCE_ISO}" bs=1 count=432 of="${WORK_DIR}/isohdpfx.bin" status=none

chmod -R u+w "${WORK_DIR}/iso"

# =============================================================================
# Build preseed from template
# =============================================================================

info "Building preseed configuration..."
info "  Hostname:  ${HOSTNAME}"
info "  Boot disk: auto-detect (first non-removable, non-USB)"

ESCAPED_PASSWORD="$(printf '%s\n' "${LAPTOP_PASSWORD}" | sed 's/[&/\]/\\&/g')"
ESCAPED_PUBKEY="$(printf '%s\n' "${PUBKEY}" | sed 's/[&/\]/\\&/g')"

cp "${PRESEED_TEMPLATE}" "${WORK_DIR}/preseed.cfg"
sed -i "s/__HOSTNAME__/${HOSTNAME}/g" "${WORK_DIR}/preseed.cfg"
sed -i "s/__SSH_PASSWORD__/${ESCAPED_PASSWORD}/g" "${WORK_DIR}/preseed.cfg"
sed -i "s|__SSH_PUBLIC_KEY__|${ESCAPED_PUBKEY}|g" "${WORK_DIR}/preseed.cfg"

cp "${WORK_DIR}/preseed.cfg" "${WORK_DIR}/iso/preseed.cfg"

# =============================================================================
# Modify boot configuration
# =============================================================================

info "Configuring automated boot..."

PRESEED_ARGS="auto=true priority=critical preseed/file=/cdrom/preseed.cfg"

# BIOS boot: modify isolinux config
if [[ -f "${WORK_DIR}/iso/isolinux/txt.cfg" ]]; then
    sed -i "s|append vga=788 initrd=/install.amd/initrd.gz ---|append vga=788 initrd=/install.amd/initrd.gz ${PRESEED_ARGS} ---|" \
        "${WORK_DIR}/iso/isolinux/txt.cfg"
fi
if [[ -f "${WORK_DIR}/iso/isolinux/isolinux.cfg" ]]; then
    sed -i 's/timeout 0/timeout 10/' "${WORK_DIR}/iso/isolinux/isolinux.cfg"
    sed -i 's/default vesamenu.c32/default install/' "${WORK_DIR}/iso/isolinux/isolinux.cfg"
fi

# UEFI boot: modify GRUB config
if [[ -f "${WORK_DIR}/iso/boot/grub/grub.cfg" ]]; then
    sed -i "s|linux\(.*\)/install.amd/vmlinuz vga=788 ---|linux\1/install.amd/vmlinuz vga=788 ${PRESEED_ARGS} ---|" \
        "${WORK_DIR}/iso/boot/grub/grub.cfg"
    sed -i 's/set timeout=.*/set timeout=3/' "${WORK_DIR}/iso/boot/grub/grub.cfg"
fi

# =============================================================================
# Rebuild ISO
# =============================================================================

info "Rebuilding ISO..."

cd "${WORK_DIR}/iso"
find . -follow -type f ! -name md5sum.txt -print0 | xargs -0 md5sum > md5sum.txt.new 2>/dev/null || true
mv md5sum.txt.new md5sum.txt
cd "${REPO_ROOT}"

xorriso -as mkisofs \
    -o "${OUTPUT_ISO}" \
    -isohybrid-mbr "${WORK_DIR}/isohdpfx.bin" \
    -c isolinux/boot.cat \
    -b isolinux/isolinux.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -eltorito-alt-boot \
    -e boot/grub/efi.img \
    -no-emul-boot -isohybrid-gpt-basdat \
    "${WORK_DIR}/iso" 2>/dev/null

ISO_SIZE="$(du -h "${OUTPUT_ISO}" | cut -f1)"
info "ISO built: ${OUTPUT_ISO} (${ISO_SIZE})"

# =============================================================================
# Flash to USB (optional)
# =============================================================================

if [[ -n "${USB_DEVICE}" ]]; then
    DEVICE_MODEL="$(lsblk -no MODEL "${USB_DEVICE}" 2>/dev/null | xargs)"
    DEVICE_SIZE="$(lsblk -no SIZE "${USB_DEVICE}" 2>/dev/null | head -1 | xargs)"

    warn "About to write to ${USB_DEVICE} (${DEVICE_MODEL}, ${DEVICE_SIZE})"
    warn "ALL DATA ON ${USB_DEVICE} WILL BE DESTROYED"
    echo -n "Type 'yes' to continue: "
    read -r CONFIRM
    if [[ "${CONFIRM}" != "yes" ]]; then
        info "Aborted. ISO is still available at: ${OUTPUT_ISO}"
        exit 0
    fi

    info "Unmounting ${USB_DEVICE} partitions..."
    umount "${USB_DEVICE}"* 2>/dev/null || true

    info "Flashing ISO to ${USB_DEVICE} (${ISO_SIZE})..."
    dd if="${OUTPUT_ISO}" of="${USB_DEVICE}" bs=4M status=none oflag=sync
    info "Flash complete (${ISO_SIZE} written)"

    info "USB flash complete."
else
    info "No USB device specified. Flash manually with:"
    echo "  sudo dd if=${OUTPUT_ISO} of=/dev/sdX bs=4M status=progress oflag=sync"
fi

# =============================================================================
# Next steps
# =============================================================================

echo ""
info "Next steps:"
echo "  1. Boot ${HOSTNAME} from the USB"
echo "  2. Install runs unattended (~10-15 min)"
echo "  3. After reboot, run bootstrap-ssh-sudo.sh if needed"
echo "  4. Set up the rest of the environment (Hyprland, NVIDIA, toolchain, etc.)"
