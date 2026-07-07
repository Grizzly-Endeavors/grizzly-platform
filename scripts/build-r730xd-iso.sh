#!/usr/bin/env bash
#
# Build a preseeded Debian 13 ISO for the Dell R730xd and flash it to USB
#
# Creates a custom Debian netinst ISO with an embedded preseed configuration
# for fully unattended installation. Optionally writes it to a USB drive.
#
# Prerequisites:
#   - xorriso (apt install xorriso)
#   - sshpass (apt install sshpass)
#   - SSH access to r730xd-idrac (configured in ~/.ssh/config)
#   - An SSH public key at ~/.ssh/id_ed25519.pub (or set SSH_PUBLIC_KEY env var)
#
# Environment variables:
#   R730XD_PASSWORD    - Install user password (prompted if not set)
#   SSH_PUBLIC_KEY     - SSH public key string (defaults to ~/.ssh/id_ed25519.pub)
#   IDRAC_PASSWORD     - iDRAC password (prompted if not set)
#
# Usage:
#   ./scripts/build-r730xd-iso.sh <debian-netinst.iso> [usb-device]
#
# Examples:
#   ./scripts/build-r730xd-iso.sh ~/Downloads/debian-13.2.0-amd64-netinst.iso
#   sudo ./scripts/build-r730xd-iso.sh ~/Downloads/debian-13.2.0-amd64-netinst.iso /dev/sdc

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PRESEED_TEMPLATE="${REPO_ROOT}/configs/r730xd/preseed.cfg"
BUILD_DIR="${REPO_ROOT}/build"
WORK_DIR="${BUILD_DIR}/iso-work"
OUTPUT_ISO="${BUILD_DIR}/debian-13-r730xd.iso"

# Source lab network config (see ansible/group_vars/all/network.yml)
# shellcheck source=lab-network.env
[[ -f "${SCRIPT_DIR}/lab-network.env" ]] && . "${SCRIPT_DIR}/lab-network.env"

# Network config — substituted into preseed at build time
STATIC_IP="${R730XD_IP:-10.0.0.200}"
GATEWAY="${LAB_GATEWAY:-10.0.0.1}"
DNS="${LAB_DNS:-8.8.8.8 8.8.4.4}"

# iDRAC config — bay 12 is the designated boot drive slot
IDRAC_HOST="${IDRAC_HOST:-r730xd-idrac}"
BOOT_DRIVE_BAY="12"

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
    if [[ -d "${WORK_DIR}" ]]; then
        info "Cleaning up work directory..."
        chmod -R u+w "${WORK_DIR}" 2>/dev/null || true
        rm -rf "${WORK_DIR}"
    fi
}

trap cleanup EXIT

# =============================================================================
# Argument parsing
# =============================================================================

if [[ $# -lt 1 ]]; then
    error "Usage: $0 <debian-netinst.iso> [usb-device]"
    echo "  debian-netinst.iso  Path to the official Debian 13 netinst ISO"
    echo "  usb-device          (Optional) USB device to flash (e.g., /dev/sdc)"
    exit 1
fi

SOURCE_ISO="$1"
USB_DEVICE="${2:-}"

if [[ ! -f "${SOURCE_ISO}" ]]; then
    error "ISO not found: ${SOURCE_ISO}"
    exit 1
fi

# =============================================================================
# Prerequisites
# =============================================================================

info "Checking prerequisites..."

if ! command -v xorriso &>/dev/null; then
    error "xorriso is not installed. Install it with: sudo apt install xorriso"
    exit 1
fi

if ! command -v sshpass &>/dev/null; then
    error "sshpass is not installed. Install it with: sudo apt install sshpass"
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
if [[ -z "${R730XD_PASSWORD:-}" ]]; then
    echo -n "Enter install password for user 'bearf': "
    read -rs R730XD_PASSWORD
    echo
    if [[ -z "${R730XD_PASSWORD}" ]]; then
        error "Password cannot be empty"
        exit 1
    fi
fi

# iDRAC password
if [[ -z "${IDRAC_PASSWORD:-}" ]]; then
    echo -n "Enter iDRAC password for ${IDRAC_HOST}: "
    read -rs IDRAC_PASSWORD
    echo
    if [[ -z "${IDRAC_PASSWORD}" ]]; then
        error "iDRAC password cannot be empty"
        exit 1
    fi
fi

# =============================================================================
# Query boot drive from iDRAC (bay 12 = designated boot slot)
# =============================================================================

info "Querying iDRAC for boot drive in bay ${BOOT_DRIVE_BAY}..."

IDRAC_SSH="sshpass -p ${IDRAC_PASSWORD} ssh ${IDRAC_HOST}"

# Get the FQDD for the disk in the boot bay
DISK_FQDD="$(${IDRAC_SSH} "racadm storage get pdisks" 2>/dev/null | grep "Disk.Bay.${BOOT_DRIVE_BAY}:" || true)"
if [[ -z "${DISK_FQDD}" ]]; then
    error "No disk found in bay ${BOOT_DRIVE_BAY}. Install a boot drive and try again."
    exit 1
fi

# Get disk details
DISK_INFO="$(${IDRAC_SSH} "racadm storage get pdisks -o" 2>/dev/null)"
DISK_SERIAL="$(echo "${DISK_INFO}" | grep "SerialNumber" | awk -F'=' '{print $2}' | xargs)"
DISK_MODEL="$(echo "${DISK_INFO}" | grep "ProductId" | awk -F'=' '{print $2}' | xargs)"
DISK_SIZE="$(echo "${DISK_INFO}" | grep "^   Size " | awk -F'=' '{print $2}' | xargs)"
DISK_MEDIA="$(echo "${DISK_INFO}" | grep "MediaType" | awk -F'=' '{print $2}' | xargs)"

if [[ -z "${DISK_SERIAL}" ]]; then
    error "Could not read serial number for disk in bay ${BOOT_DRIVE_BAY}"
    exit 1
fi

# Build the /dev/disk/by-id/ path
# Linux uses ata-<Model>_<Serial> format; spaces in model become underscores
DISK_MODEL_CLEAN="${DISK_MODEL// /_}"
BOOT_DISK_BY_ID="ata-${DISK_MODEL_CLEAN}_${DISK_SERIAL}"

info "Boot drive (bay ${BOOT_DRIVE_BAY}): ${DISK_MODEL} ${DISK_SIZE} (${DISK_MEDIA})"
info "Serial: ${DISK_SERIAL}"
info "Disk ID: /dev/disk/by-id/${BOOT_DISK_BY_ID}"

# USB device validation (if specified)
if [[ -n "${USB_DEVICE}" ]]; then
    if [[ ! -b "${USB_DEVICE}" ]]; then
        error "Not a block device: ${USB_DEVICE}"
        exit 1
    fi

    # Safety: verify it's a removable device
    DEVICE_NAME="$(basename "${USB_DEVICE}")"
    REMOVABLE="$(cat "/sys/block/${DEVICE_NAME}/removable" 2>/dev/null || echo "0")"
    if [[ "${REMOVABLE}" != "1" ]]; then
        error "${USB_DEVICE} is not a removable device. Refusing to flash."
        exit 1
    fi

    # Check we're running as root for dd
    if [[ ${EUID} -ne 0 ]]; then
        error "Must run as root to flash USB. Use: sudo $0 $*"
        exit 1
    fi
fi

info "Prerequisites OK"

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

# Extract MBR for hybrid boot (needed to rebuild a bootable ISO)
dd if="${SOURCE_ISO}" bs=1 count=432 of="${WORK_DIR}/isohdpfx.bin" status=none

# Make extracted files writable so we can modify them
chmod -R u+w "${WORK_DIR}/iso"

# =============================================================================
# Build preseed from template
# =============================================================================

info "Building preseed configuration..."

# Escape special characters for sed
ESCAPED_PASSWORD="$(printf '%s\n' "${R730XD_PASSWORD}" | sed 's/[&/\]/\\&/g')"
ESCAPED_PUBKEY="$(printf '%s\n' "${PUBKEY}" | sed 's/[&/\]/\\&/g')"

cp "${PRESEED_TEMPLATE}" "${WORK_DIR}/preseed.cfg"
sed -i "s/__SSH_PASSWORD__/${ESCAPED_PASSWORD}/g" "${WORK_DIR}/preseed.cfg"
sed -i "s|__SSH_PUBLIC_KEY__|${ESCAPED_PUBKEY}|g" "${WORK_DIR}/preseed.cfg"
sed -i "s|__BOOT_DISK_BY_ID__|${BOOT_DISK_BY_ID}|g" "${WORK_DIR}/preseed.cfg"
sed -i "s|__STATIC_IP__|${STATIC_IP}|g" "${WORK_DIR}/preseed.cfg"
sed -i "s|__GATEWAY__|${GATEWAY}|g" "${WORK_DIR}/preseed.cfg"
sed -i "s|__DNS__|${DNS}|g" "${WORK_DIR}/preseed.cfg"

# Inject preseed into ISO root
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
    # Auto-select "install" entry after 1 second instead of showing menu
    sed -i 's/timeout 0/timeout 10/' "${WORK_DIR}/iso/isolinux/isolinux.cfg"
    sed -i 's/default vesamenu.c32/default install/' "${WORK_DIR}/iso/isolinux/isolinux.cfg"
fi

# UEFI boot: modify GRUB config
if [[ -f "${WORK_DIR}/iso/boot/grub/grub.cfg" ]]; then
    # Match vmlinuz lines with flexible whitespace
    sed -i "s|linux\(.*\)/install.amd/vmlinuz vga=788 ---|linux\1/install.amd/vmlinuz vga=788 ${PRESEED_ARGS} ---|" \
        "${WORK_DIR}/iso/boot/grub/grub.cfg"
    # Set short timeout for GRUB
    sed -i 's/set timeout=.*/set timeout=3/' "${WORK_DIR}/iso/boot/grub/grub.cfg"
fi

# =============================================================================
# Rebuild ISO
# =============================================================================

info "Rebuilding ISO..."

# Regenerate md5sum (installer checks this)
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

    info "Flashing ISO to ${USB_DEVICE}..."
    dd if="${OUTPUT_ISO}" of="${USB_DEVICE}" bs=4M status=progress oflag=sync

    info "USB flash complete. Safely remove ${USB_DEVICE} and plug into R730xd."
else
    info "No USB device specified. Flash manually with:"
    echo "  sudo dd if=${OUTPUT_ISO} of=/dev/sdX bs=4M status=progress oflag=sync"
fi

# =============================================================================
# Next steps
# =============================================================================

echo ""
info "Next steps:"
echo "  1. Plug USB into R730xd front panel"
echo "  2. Boot from USB (F11 boot menu or iDRAC)"
echo "  3. Install runs unattended (~10-15 min)"
echo "  4. After reboot, SSH to bearf@${STATIC_IP}"
echo "  5. Run: ansible-playbook -i ansible/inventory/r730xd.yml ansible/playbooks/setup-r730xd.yml -v"
