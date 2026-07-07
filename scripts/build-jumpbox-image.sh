#!/usr/bin/env bash
#
# Build a minimal Debian Trixie jumpbox image on a target drive
#
# Creates a lightweight Sway-based lab command center via debootstrap.
# The drive can then be moved to the target machine and booted.
#
# Prerequisites:
#   - Must be run as root (sudo)
#   - debootstrap installed on the build host
#   - Target drive connected and unmounted
#
# Optional environment variables:
#   NETBIRD_SETUP_KEY  - NetBird setup key for headless enrollment on first boot
#   ANTHROPIC_API_KEY  - API key for Claude Code, written to user's fish config
#
# Usage:
#   sudo ./scripts/build-jumpbox-image.sh
#   sudo NETBIRD_SETUP_KEY=xxx ANTHROPIC_API_KEY=xxx ./scripts/build-jumpbox-image.sh

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

TARGET_DEVICE="${TARGET_DEVICE:-/dev/sda}"
SWAP_SIZE="${SWAP_SIZE:-4G}"
TARGET_HOSTNAME="${TARGET_HOSTNAME:-jumpbox}"
USERNAME="${USERNAME:-bearf}"
TIMEZONE="${TIMEZONE:-America/New_York}"
DEBIAN_RELEASE="${DEBIAN_RELEASE:-trixie}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/jumpbox}"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian}"
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.31.4}"

NETBIRD_SETUP_KEY="${NETBIRD_SETUP_KEY:-}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIGS_DIR="${REPO_ROOT}/configs/jumpbox"

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
    info "Cleaning up mounts..."
    # Unmount in reverse order, ignore errors during cleanup
    for mp in "${MOUNT_POINT}/dev/pts" "${MOUNT_POINT}/dev" "${MOUNT_POINT}/proc" "${MOUNT_POINT}/sys" "${MOUNT_POINT}/sys/firmware/efi/efivars" "${MOUNT_POINT}/boot/efi" "${MOUNT_POINT}"; do
        if mountpoint -q "${mp}" 2>/dev/null; then
            umount -lf "${mp}" 2>/dev/null || true
        fi
    done
}

run_in_chroot() {
    chroot "${MOUNT_POINT}" /bin/bash -c "$1"
}

# =============================================================================
# Prerequisite checks
# =============================================================================

info "Jumpbox Image Builder"
echo ""

if [[ ${EUID} -ne 0 ]]; then
    error "This script must be run as root (sudo)"
    exit 1
fi

command -v debootstrap >/dev/null 2>&1 || { error "debootstrap not found. Install with: apt install debootstrap"; exit 1; }
command -v parted >/dev/null 2>&1 || { error "parted not found. Install with: apt install parted"; exit 1; }
command -v mkfs.vfat >/dev/null 2>&1 || { error "mkfs.vfat not found. Install with: apt install dosfstools"; exit 1; }

if [[ ! -b "${TARGET_DEVICE}" ]]; then
    error "Target device ${TARGET_DEVICE} does not exist or is not a block device"
    exit 1
fi

if [[ ! -d "${CONFIGS_DIR}" ]]; then
    error "Config directory not found at ${CONFIGS_DIR}"
    exit 1
fi

# Show drive info
echo ""
echo "Target device: ${TARGET_DEVICE}"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL "${TARGET_DEVICE}" 2>/dev/null || true
echo ""

# Check for mounted partitions on target device
mounted_parts=$(lsblk -rno NAME,MOUNTPOINT "${TARGET_DEVICE}" | awk '$2 != "" {print "/dev/"$1" on "$2}')
if [[ -n "${mounted_parts}" ]]; then
    warn "The following partitions on ${TARGET_DEVICE} are currently mounted:"
    echo "${mounted_parts}"
    echo ""
fi

echo -e "${RED}WARNING: This will DESTROY ALL DATA on ${TARGET_DEVICE}${NC}"
echo ""
read -r -p "Type 'yes' to proceed: " confirm
if [[ "${confirm}" != "yes" ]]; then
    echo "Aborted."
    exit 0
fi

# Unmount any mounted partitions on target device
info "Unmounting any existing partitions on ${TARGET_DEVICE}..."
for part in $(lsblk -rno NAME "${TARGET_DEVICE}" | tail -n +2); do
    umount "/dev/${part}" 2>/dev/null || true
done

trap cleanup EXIT

# =============================================================================
# Phase 1: Partition & Format
# =============================================================================

info "Phase 1: Partitioning ${TARGET_DEVICE} (GPT + UEFI)"

parted -s "${TARGET_DEVICE}" mklabel gpt
SWAP_SIZE_MIB=$(numfmt --from=iec "${SWAP_SIZE}" | awk '{print int($1/1024/1024)}')
SWAP_END_MIB=$((513 + SWAP_SIZE_MIB))

parted -s "${TARGET_DEVICE}" mkpart "EFI" fat32 1MiB 513MiB
parted -s "${TARGET_DEVICE}" set 1 esp on
parted -s "${TARGET_DEVICE}" mkpart "swap" linux-swap 513MiB "${SWAP_END_MIB}MiB"
parted -s "${TARGET_DEVICE}" mkpart "root" ext4 "${SWAP_END_MIB}MiB" 100%

# Wait for kernel to re-read partition table
partprobe "${TARGET_DEVICE}"
sleep 2

# Determine partition naming (sda1 vs sda-part1 vs nvme0n1p1)
if [[ "${TARGET_DEVICE}" == *nvme* ]] || [[ "${TARGET_DEVICE}" == *mmcblk* ]]; then
    PART_PREFIX="${TARGET_DEVICE}p"
else
    PART_PREFIX="${TARGET_DEVICE}"
fi

EFI_PART="${PART_PREFIX}1"
SWAP_PART="${PART_PREFIX}2"
ROOT_PART="${PART_PREFIX}3"

info "Formatting partitions..."
mkfs.vfat -F 32 -n EFI "${EFI_PART}"
mkswap -L swap "${SWAP_PART}"
mkfs.ext4 -L root "${ROOT_PART}"

# =============================================================================
# Phase 2: Debootstrap
# =============================================================================

info "Phase 2: Debootstrap ${DEBIAN_RELEASE} into ${MOUNT_POINT}"

mkdir -p "${MOUNT_POINT}"
mount "${ROOT_PART}" "${MOUNT_POINT}"
mkdir -p "${MOUNT_POINT}/boot/efi"
mount "${EFI_PART}" "${MOUNT_POINT}/boot/efi"

debootstrap --arch amd64 "${DEBIAN_RELEASE}" "${MOUNT_POINT}" "${DEBIAN_MIRROR}"

# =============================================================================
# Phase 3: Chroot setup
# =============================================================================

info "Phase 3: Configuring system in chroot"

# Mount virtual filesystems for chroot
mount --bind /dev "${MOUNT_POINT}/dev"
mount --bind /dev/pts "${MOUNT_POINT}/dev/pts"
mount -t proc proc "${MOUNT_POINT}/proc"
mount -t sysfs sys "${MOUNT_POINT}/sys"

# --- fstab ---
info "Generating fstab..."
EFI_UUID=$(blkid -s UUID -o value "${EFI_PART}")
SWAP_UUID=$(blkid -s UUID -o value "${SWAP_PART}")
ROOT_UUID=$(blkid -s UUID -o value "${ROOT_PART}")

cat > "${MOUNT_POINT}/etc/fstab" <<EOF
# <filesystem>                          <mount>     <type>  <options>           <dump> <pass>
UUID=${ROOT_UUID}   /           ext4    errors=remount-ro   0      1
UUID=${EFI_UUID}    /boot/efi   vfat    umask=0077          0      2
UUID=${SWAP_UUID}   none        swap    sw                  0      0
EOF

# --- Hostname ---
echo "${TARGET_HOSTNAME}" > "${MOUNT_POINT}/etc/hostname"
cat > "${MOUNT_POINT}/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   ${TARGET_HOSTNAME}

::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

# --- Apt sources ---
cat > "${MOUNT_POINT}/etc/apt/sources.list" <<EOF
deb ${DEBIAN_MIRROR} ${DEBIAN_RELEASE} main contrib non-free non-free-firmware
deb ${DEBIAN_MIRROR} ${DEBIAN_RELEASE}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${DEBIAN_RELEASE}-security main contrib non-free non-free-firmware
EOF

# --- Locale & Timezone ---
info "Setting locale and timezone..."
run_in_chroot "apt-get update -qq"
run_in_chroot "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq locales console-setup"
sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' "${MOUNT_POINT}/etc/locale.gen"
run_in_chroot "locale-gen"
echo 'LANG=en_US.UTF-8' > "${MOUNT_POINT}/etc/default/locale"
run_in_chroot "ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime"
echo "${TIMEZONE}" > "${MOUNT_POINT}/etc/timezone"

# =============================================================================
# Phase 4: Package installation
# =============================================================================

info "Phase 4: Installing packages"

# --- Base system ---
info "Installing base system packages..."
run_in_chroot "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    linux-image-amd64 firmware-linux-free firmware-linux-nonfree \
    grub-efi-amd64 efibootmgr \
    systemd-timesyncd sudo udev dbus"

# --- Networking ---
info "Installing networking packages..."
run_in_chroot "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    network-manager wpasupplicant \
    openssh-client openssh-server \
    ca-certificates gnupg"

# --- Sway desktop ---
info "Installing Sway desktop environment..."
run_in_chroot "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    sway waybar foot mako-notifier \
    swaylock swayidle \
    grim slurp wl-clipboard \
    xwayland wmenu"

# --- Shell & tools ---
info "Installing shell and tools..."
run_in_chroot "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    fish git curl wget htop btop tmux \
    rsync jq unzip w3m \
    python3 python3-venv"

# --- Ansible ---
info "Installing Ansible..."
run_in_chroot "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ansible"

# --- kubectl (static binary) ---
info "Installing kubectl ${KUBECTL_VERSION}..."
curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    -o "${MOUNT_POINT}/usr/local/bin/kubectl"
chmod +x "${MOUNT_POINT}/usr/local/bin/kubectl"

# --- Node.js via NodeSource (for Claude Code) ---
info "Installing Node.js via NodeSource..."
run_in_chroot "curl -fsSL https://deb.nodesource.com/setup_22.x | bash -"
run_in_chroot "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs"

# --- Claude Code ---
info "Installing Claude Code..."
# shellcheck disable=SC2310 # run_in_chroot is a single command; failure here is meant to be non-fatal
run_in_chroot "npm install -g @anthropic-ai/claude-code" || warn "Claude Code install failed — can be installed post-boot"

# --- NetBird ---
info "Installing NetBird..."
run_in_chroot "curl -sSL https://pkgs.netbird.io/debian/public.key | gpg --dearmor -o /usr/share/keyrings/netbird-archive-keyring.gpg"
echo 'deb [signed-by=/usr/share/keyrings/netbird-archive-keyring.gpg] https://pkgs.netbird.io/debian stable main' \
    > "${MOUNT_POINT}/etc/apt/sources.list.d/netbird.list"
run_in_chroot "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq netbird"

# =============================================================================
# Phase 5: User & system configuration
# =============================================================================

info "Phase 5: Configuring user and system"

# --- Create user ---
run_in_chroot "useradd -m -s /usr/bin/fish -G sudo,video,input,netdev ${USERNAME}"
run_in_chroot "echo '${USERNAME} ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/${USERNAME}"
run_in_chroot "chmod 440 /etc/sudoers.d/${USERNAME}"

# Set a temporary password (user should change on first login)
run_in_chroot "echo '${USERNAME}:jumpbox' | chpasswd"
warn "Temporary password set to 'jumpbox' — change on first login with: passwd"

# --- Enable services ---
run_in_chroot "systemctl enable NetworkManager"
run_in_chroot "systemctl enable ssh"
run_in_chroot "systemctl enable systemd-timesyncd"

# --- Bootloader ---
info "Installing GRUB bootloader..."
run_in_chroot "grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --removable"
run_in_chroot "update-grub"

# --- Config files ---
info "Copying Sway/Waybar/Foot configs..."
USER_HOME="${MOUNT_POINT}/home/${USERNAME}"

mkdir -p "${USER_HOME}/.config/sway"
mkdir -p "${USER_HOME}/.config/waybar"
mkdir -p "${USER_HOME}/.config/foot"

cp "${CONFIGS_DIR}/sway/config"         "${USER_HOME}/.config/sway/config"
cp "${CONFIGS_DIR}/waybar/config.jsonc"  "${USER_HOME}/.config/waybar/config.jsonc"
cp "${CONFIGS_DIR}/waybar/style.css"     "${USER_HOME}/.config/waybar/style.css"
cp "${CONFIGS_DIR}/foot/foot.ini"        "${USER_HOME}/.config/foot/foot.ini"

# Auto-start Sway on TTY1 login
mkdir -p "${USER_HOME}/.config/fish/conf.d"
cat > "${USER_HOME}/.config/fish/conf.d/sway-autostart.fish" <<'FISHEOF'
# Start Sway on TTY1 if not already in a graphical session
if test -z "$DISPLAY" -a -z "$WAYLAND_DISPLAY" -a (tty) = "/dev/tty1"
    exec sway
end
FISHEOF

# --- Fix ownership ---
run_in_chroot "chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}"

# --- Auto-login on TTY1 ---
info "Configuring auto-login on TTY1..."
mkdir -p "${MOUNT_POINT}/etc/systemd/system/getty@tty1.service.d"
cat > "${MOUNT_POINT}/etc/systemd/system/getty@tty1.service.d/autologin.conf" <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${USERNAME} --noclear %I \$TERM
EOF

# =============================================================================
# Phase 7: Optional token setup
# =============================================================================

info "Phase 7: Token configuration"

if [[ -n "${ANTHROPIC_API_KEY}" ]]; then
    info "Configuring Claude Code API key..."
    cat > "${USER_HOME}/.config/fish/conf.d/claude.fish" <<FISHEOF
set -gx ANTHROPIC_API_KEY "${ANTHROPIC_API_KEY}"
FISHEOF
    run_in_chroot "chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.config/fish/conf.d/claude.fish"
    chmod 600 "${USER_HOME}/.config/fish/conf.d/claude.fish"
else
    warn "ANTHROPIC_API_KEY not set — Claude Code will need manual configuration"
fi

if [[ -n "${NETBIRD_SETUP_KEY}" ]]; then
    info "Configuring NetBird first-boot enrollment..."
    cat > "${MOUNT_POINT}/etc/systemd/system/jumpbox-netbird-enroll.service" <<EOF
[Unit]
Description=NetBird first-boot enrollment
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/var/lib/netbird/.enrolled

[Service]
Type=oneshot
ExecStart=/usr/bin/netbird up --setup-key ${NETBIRD_SETUP_KEY}
ExecStartPost=/usr/bin/touch /var/lib/netbird/.enrolled
ExecStartPost=/bin/systemctl disable jumpbox-netbird-enroll.service
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    run_in_chroot "systemctl enable jumpbox-netbird-enroll.service"
else
    warn "NETBIRD_SETUP_KEY not set — NetBird enrollment will need to be done manually"
fi

# =============================================================================
# Phase 6: Cleanup
# =============================================================================

info "Phase 6: Cleaning up"

run_in_chroot "apt-get clean"
run_in_chroot "rm -rf /var/lib/apt/lists/*"

# Unmount is handled by the EXIT trap

# =============================================================================
# Done
# =============================================================================

echo ""
info "Jumpbox image built successfully!"
echo ""
echo "  Hostname:   ${TARGET_HOSTNAME}"
echo "  User:       ${USERNAME} (password: jumpbox — CHANGE THIS)"
echo "  Shell:      fish"
echo "  Desktop:    Sway (auto-starts on TTY1)"
echo "  Drive:      ${TARGET_DEVICE}"
echo ""
echo "  Installed:  sway, waybar, foot, fish, git, tmux, htop, btop,"
echo "              ansible, kubectl, claude-code, netbird, w3m"
echo ""
if [[ -n "${NETBIRD_SETUP_KEY}" ]]; then
    echo "  NetBird:    Will auto-enroll on first boot"
else
    echo "  NetBird:    Run 'sudo netbird up' to enroll manually"
fi
if [[ -n "${ANTHROPIC_API_KEY}" ]]; then
    echo "  Claude:     API key configured"
else
    echo "  Claude:     Set ANTHROPIC_API_KEY in ~/.config/fish/conf.d/claude.fish"
fi
echo ""
echo "  Next steps:"
echo "    1. Move the drive to the target machine"
echo "    2. Boot and verify UEFI picks up the drive"
echo "    3. Login and run: passwd"
echo ""
