#!/usr/bin/env bash
#
# Wipe Dell R730xd drive bays — removes all RAID metadata, filesystem
# signatures, and partition tables so drives are clean for storage-prep.
#
# Resolves bay numbers to OS block devices via iDRAC, then wipes each
# drive over SSH. Requires explicit confirmation before any destructive
# action.
#
# Prerequisites:
#   - sshpass (apt install sshpass)
#   - Network access to iDRAC and R730xd host
#   - mdadm, wipefs, sgdisk installed on R730xd
#
# Environment variables:
#   IDRAC_PASSWORD  - iDRAC root password (required)
#   IDRAC_HOST      - iDRAC IP/hostname (default: from lab-network.env)
#   R730XD_HOST     - R730xd SSH host (default: from lab-network.env)
#   R730XD_USER     - R730xd SSH user (default: bearf)
#   BOOT_DRIVE_BAY  - Bay to refuse to wipe (default: 12)
#
# Usage:
#   IDRAC_PASSWORD=secret ./scripts/wipe-r730xd-bays.sh [OPTIONS] BAY [BAY...]
#
# Options:
#   --dry-run   Show what would be wiped without doing it
#   --help      Show this help
#
# Examples:
#   ./scripts/wipe-r730xd-bays.sh --dry-run 0 1 2
#   ./scripts/wipe-r730xd-bays.sh 0 1 2

# r730xd_ssh and racadm below are both single-pipeline wrapper functions, so
# invoking them inside `||`/`if` (which check-set-e-suppressed warns about)
# never masks an internal early-exit — there's only ever one statement to run.
# shellcheck disable=SC2310

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Source lab network config (see ansible/group_vars/all/network.yml)
# shellcheck source=lab-network.env
[[ -f "${SCRIPT_DIR}/lab-network.env" ]] && . "${SCRIPT_DIR}/lab-network.env"

IDRAC_HOST="${IDRAC_HOST:-${IDRAC_IP:-10.0.0.203}}"
R730XD_HOST="${R730XD_HOST:-${R730XD_IP:-10.0.0.200}}"
R730XD_USER="${R730XD_USER:-bearf}"
BOOT_DRIVE_BAY="${BOOT_DRIVE_BAY:-12}"

DRY_RUN=false
SKIP_CONFIRM=false
TARGET_BAYS=()

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# =============================================================================
# Helper functions
# =============================================================================

info()  { echo -e "${GREEN}==> $*${NC}"; }
warn()  { echo -e "${YELLOW}==> WARNING: $*${NC}"; }
error() { echo -e "${RED}==> ERROR: $*${NC}" >&2; }

# Run a command on the R730xd via SSH (stdin from /dev/null to avoid consuming script stdin)
r730xd_ssh() {
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR -n "${R730XD_USER}@${R730XD_HOST}" "$@"
}

# Run a racadm command via iDRAC SSH
racadm() {
    sshpass -p "${IDRAC_PASSWORD}" ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR \
        "root@${IDRAC_HOST}" "racadm $*" 2>/dev/null | tr -d '\r'
}

# =============================================================================
# Argument parsing
# =============================================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --yes|-y)
            SKIP_CONFIRM=true
            shift
            ;;
        --help|-h)
            head -33 "$0" | tail -27
            exit 0
            ;;
        -*)
            error "Unknown option: $1"
            error "Run with --help for usage"
            exit 1
            ;;
        *)
            TARGET_BAYS+=("$1")
            shift
            ;;
    esac
done

if [[ ${#TARGET_BAYS[@]} -eq 0 ]]; then
    error "No bay numbers specified."
    error "Usage: $0 [--dry-run] BAY [BAY...]"
    error "Example: $0 0 1 2"
    exit 1
fi

# Refuse boot drive bay
for bay in "${TARGET_BAYS[@]}"; do
    if [[ "${bay}" == "${BOOT_DRIVE_BAY}" ]]; then
        error "Bay ${BOOT_DRIVE_BAY} is the boot drive — refusing to wipe."
        exit 1
    fi
    if ! [[ "${bay}" =~ ^[0-9]+$ ]]; then
        error "Invalid bay number: ${bay}"
        exit 1
    fi
done

# =============================================================================
# Prerequisites
# =============================================================================

if ! command -v sshpass &>/dev/null; then
    error "sshpass is required but not installed. Run: apt install sshpass"
    exit 1
fi

if [[ -z "${IDRAC_PASSWORD:-}" ]]; then
    echo -n "iDRAC password: "
    read -rs IDRAC_PASSWORD
    echo
fi

# =============================================================================
# Resolve bay numbers to OS devices via iDRAC
# =============================================================================

info "Connecting to iDRAC at ${IDRAC_HOST}..."
idrac_output="$(racadm storage get pdisks -o)" || {
    error "Failed to connect to iDRAC or query disks"
    exit 1
}
info "Connected to iDRAC"

# Parse bay → serial mapping from iDRAC output
declare -A BAY_TO_SERIAL=()
declare -A BAY_TO_MODEL=()
declare -A BAY_TO_SIZE=()
current_bay=""
current_serial=""
current_model=""
current_size=""
in_disk=false

while IFS= read -r line; do
    if [[ "${line}" =~ Disk\.Bay\.([0-9]+):Enclosure ]]; then
        if [[ "${in_disk}" == true && -n "${current_bay}" && -n "${current_serial}" ]]; then
            BAY_TO_SERIAL["${current_bay}"]="${current_serial}"
            BAY_TO_MODEL["${current_bay}"]="${current_model}"
            BAY_TO_SIZE["${current_bay}"]="${current_size}"
        fi
        current_bay="${BASH_REMATCH[1]}"
        current_serial=""
        current_model=""
        current_size=""
        in_disk=true
    elif [[ "${in_disk}" == true ]]; then
        if [[ "${line}" =~ ^[[:space:]]*(ProductId|Model)[[:space:]]*=[[:space:]]*(.*) ]]; then
            current_model="$(echo "${BASH_REMATCH[2]}" | xargs)"
        elif [[ "${line}" =~ ^[[:space:]]*SerialNumber[[:space:]]*=[[:space:]]*(.*) ]]; then
            current_serial="$(echo "${BASH_REMATCH[1]}" | xargs)"
        elif [[ "${line}" =~ ^[[:space:]]*Size[[:space:]]*=[[:space:]]*(.*) ]]; then
            current_size="$(echo "${BASH_REMATCH[1]}" | xargs)"
        fi
    fi
done <<< "${idrac_output}"

# Flush last disk
if [[ "${in_disk}" == true && -n "${current_bay}" && -n "${current_serial}" ]]; then
    BAY_TO_SERIAL["${current_bay}"]="${current_serial}"
    BAY_TO_MODEL["${current_bay}"]="${current_model}"
    BAY_TO_SIZE["${current_bay}"]="${current_size}"
fi

# =============================================================================
# Resolve serials to /dev/sdX via R730xd host
# =============================================================================

info "Querying block devices on ${R730XD_HOST}..."
lsblk_json="$(r730xd_ssh 'lsblk -J -b -o NAME,SERIAL,SIZE,TYPE')" || {
    error "Failed to SSH to R730xd at ${R730XD_HOST}"
    exit 1
}

# Build serial → device map
# Normalize serials: strip whitespace, replace spaces/dashes so iDRAC and lsblk formats match
# iDRAC reports "WD WCC4E6JPH3JT", lsblk reports "WD-WCC4E6JPH3JT"
normalize_serial() {
    echo "$1" | tr -d ' -' | tr '[:lower:]' '[:upper:]'
}

declare -A SERIAL_TO_DEV=()
disk_json="$(python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
for dev in data['blockdevices']:
    if dev['type'] == 'disk' and dev.get('serial'):
        print(json.dumps({'name': dev['name'], 'serial': dev['serial'].strip()}))
" <<< "${lsblk_json}")"
while IFS= read -r line; do
    name="$(echo "${line}" | python3 -c "import sys,json; print(json.load(sys.stdin)['name'])")"
    serial="$(echo "${line}" | python3 -c "import sys,json; print(json.load(sys.stdin)['serial'])")"
    normalized="$(normalize_serial "${serial}")"
    SERIAL_TO_DEV["${normalized}"]="${name}"
done <<< "${disk_json}"

# =============================================================================
# Build final bay → device resolution
# =============================================================================

declare -A BAY_TO_DEV=()
resolve_errors=()

for bay in "${TARGET_BAYS[@]}"; do
    serial="${BAY_TO_SERIAL[${bay}]:-}"
    if [[ -z "${serial}" ]]; then
        resolve_errors+=("Bay ${bay}: no disk found in iDRAC (is a drive installed?)")
        continue
    fi

    normalized="$(normalize_serial "${serial}")"
    device="${SERIAL_TO_DEV[${normalized}]:-}"
    if [[ -z "${device}" ]]; then
        resolve_errors+=("Bay ${bay}: serial ${serial} (normalized: ${normalized}) not found on host (drive may not be in JBOD mode)")
        continue
    fi

    BAY_TO_DEV["${bay}"]="${device}"
done

if [[ ${#resolve_errors[@]} -gt 0 ]]; then
    for err in "${resolve_errors[@]}"; do
        error "${err}"
    done
    exit 1
fi

# =============================================================================
# Show current state and what will be wiped
# =============================================================================

echo ""
echo -e "${BOLD}Drives to wipe:${NC}"
echo ""
printf "  %-6s %-8s %-20s %-10s %-15s\n" "Bay" "Device" "Model" "Size" "Serial"
printf "  %-6s %-8s %-20s %-10s %-15s\n" "---" "------" "-----" "----" "------"

for bay in "${TARGET_BAYS[@]}"; do
    device="${BAY_TO_DEV[${bay}]}"
    model="${BAY_TO_MODEL[${bay}]:-unknown}"
    size="${BAY_TO_SIZE[${bay}]:-unknown}"
    serial="${BAY_TO_SERIAL[${bay}]}"
    printf "  %-6s %-8s %-20s %-10s %-15s\n" "${bay}" "/dev/${device}" "${model}" "${size}" "${serial}"
done

echo ""
echo -e "${BOLD}Current signatures on target drives:${NC}"
echo ""

for bay in "${TARGET_BAYS[@]}"; do
    device="${BAY_TO_DEV[${bay}]}"
    echo -e "  ${YELLOW}Bay ${bay} (/dev/${device}):${NC}"

    # Show blkid for the whole device and any partitions
    blkid_output="$(r730xd_ssh "sudo blkid /dev/${device} /dev/${device}[0-9]* 2>/dev/null" || true)"
    if [[ -n "${blkid_output}" ]]; then
        while IFS= read -r line; do
            echo "    ${line}"
        done <<< "${blkid_output}"
    else
        echo "    (no signatures found)"
    fi

    # Show partition table
    part_output="$(r730xd_ssh "sudo fdisk -l /dev/${device} 2>/dev/null | grep -E '^/dev|^Disklabel'" || true)"
    if [[ -n "${part_output}" ]]; then
        while IFS= read -r line; do
            echo "    ${line}"
        done <<< "${part_output}"
    fi
    echo ""
done

# =============================================================================
# Dry-run: stop here
# =============================================================================

if [[ "${DRY_RUN}" == true ]]; then
    echo -e "${BOLD}Dry run — the following operations would be performed on each drive:${NC}"
    echo ""
    echo "  1. Stop any assembled MD arrays containing the device"
    echo "  2. Wipe RAID superblocks (mdadm --zero-superblock)"
    echo "  3. Wipe all filesystem signatures (wipefs --all)"
    echo "  4. Destroy partition table (sgdisk --zap-all)"
    echo ""
    info "Dry run complete. Run without --dry-run to apply."
    exit 0
fi

# =============================================================================
# Confirmation
# =============================================================================

echo -e "${RED}${BOLD}WARNING: This will PERMANENTLY DESTROY all data on the above drives.${NC}"
echo -e "${RED}This operation cannot be undone.${NC}"
echo ""

if [[ "${SKIP_CONFIRM}" == true ]]; then
    warn "Skipping confirmation (--yes flag)"
else
    echo -n "Type 'yes' to proceed: "
    read -r confirm < /dev/tty

    if [[ "${confirm}" != "yes" ]]; then
        info "Aborted."
        exit 0
    fi
fi

echo ""

# =============================================================================
# Wipe each drive
# =============================================================================

for bay in "${TARGET_BAYS[@]}"; do
    device="${BAY_TO_DEV[${bay}]}"
    info "Wiping bay ${bay} (/dev/${device})..."

    # Step 1: Stop any MD arrays that include this device
    info "  Stopping any MD arrays using /dev/${device}..."
    r730xd_ssh "
        for md in \$(grep -l '${device}' /sys/block/md*/slaves/*/uevent 2>/dev/null | grep -oP 'md\d+' | sort -u); do
            echo \"    Stopping /dev/\${md}\"
            sudo mdadm --stop /dev/\${md} 2>/dev/null || true
        done
    " || true

    # Step 2: Wipe RAID superblocks on the whole device and all partitions
    info "  Wiping RAID superblocks..."
    r730xd_ssh "
        sudo mdadm --zero-superblock /dev/${device} 2>/dev/null || true
        for part in /dev/${device}[0-9]*; do
            if [ -e \"\${part}\" ]; then
                echo \"    Wiping superblock on \${part}\"
                sudo mdadm --zero-superblock \"\${part}\" 2>/dev/null || true
            fi
        done
    "

    # Step 3: Wipe all filesystem signatures
    info "  Wiping filesystem signatures..."
    r730xd_ssh "sudo wipefs --all --force /dev/${device} 2>/dev/null || sudo wipefs --all /dev/${device}" || {
        warn "  wipefs had issues on /dev/${device} — continuing"
    }

    # Step 4: Destroy partition table
    info "  Destroying partition table..."
    r730xd_ssh "
        if command -v sgdisk &>/dev/null; then
            sudo sgdisk --zap-all /dev/${device} 2>/dev/null
        else
            # Fallback: zero first and last 1MB
            sudo dd if=/dev/zero of=/dev/${device} bs=1M count=1 2>/dev/null
            size=\$(sudo blockdev --getsize64 /dev/${device})
            sudo dd if=/dev/zero of=/dev/${device} bs=1M count=1 seek=\$(( (size / 1048576) - 1 )) 2>/dev/null
        fi
    "

    # Force kernel to re-read partition table
    r730xd_ssh "sudo partprobe /dev/${device} 2>/dev/null || true"

    info "  Bay ${bay} (/dev/${device}) wiped."
    echo ""
done

# =============================================================================
# Final verification
# =============================================================================

info "Verifying clean state..."
echo ""

all_clean=true
for bay in "${TARGET_BAYS[@]}"; do
    device="${BAY_TO_DEV[${bay}]}"
    blkid_output="$(r730xd_ssh "sudo blkid /dev/${device} /dev/${device}[0-9]* 2>/dev/null" || true)"
    part_count="$(r730xd_ssh "lsblk -n -o TYPE /dev/${device} 2>/dev/null | grep -c part || true")"

    if [[ -n "${blkid_output}" || "${part_count:-0}" -gt 0 ]]; then
        warn "Bay ${bay} (/dev/${device}) may still have residual signatures:"
        echo "  ${blkid_output}"
        all_clean=false
    else
        info "Bay ${bay} (/dev/${device}): clean"
    fi
done

echo ""
if [[ "${all_clean}" == true ]]; then
    info "All target drives are clean and ready for storage-prep."
    info "Run the storage playbook:"
    info "  ansible-playbook -i ansible/inventory/r730xd.yml ansible/playbooks/r730xd-storage.yml \\"
    info "    --vault-password-file .vault_pass -v"
else
    warn "Some drives may have residual data. Inspect manually before running storage-prep."
fi
