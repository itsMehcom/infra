#!/usr/bin/env bash
set -euo pipefail

# Interactive Ubuntu LUKS + TPM + Clevis auto-unlock setup
# For Proxmox VMs with:
# - OVMF (UEFI)
# - q35 machine type
# - vTPM 2.0 attached
#
# This script:
# 1. Detects LUKS devices
# 2. Verifies TPM visibility
# 3. Installs required packages
# 4. Enrolls TPM2 token using systemd-cryptenroll
# 5. Binds Clevis to TPM2 (recommended for Ubuntu)
# 6. Rebuilds initramfs
#
# IMPORTANT:
# - Keep your manual LUKS passphrase
# - Do NOT remove password slots
# - Test reboot after completion

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo bash $0"
  exit 1
fi

info() {
  echo
  echo "=================================================="
  echo "$1"
  echo "=================================================="
}

pause() {
  read -rp "Press Enter to continue..."
}

info "Step 1: Detecting LUKS devices"
lsblk -f

echo
read -rp "Enter your LUKS partition (example: /dev/sda3): " LUKS_DEVICE

if [[ ! -b "$LUKS_DEVICE" ]]; then
  echo "Invalid block device: $LUKS_DEVICE"
  exit 1
fi

info "Step 2: Checking TPM visibility"
apt update
apt install -y tpm2-tools >/dev/null 2>&1 || true

if ! systemd-cryptenroll --tpm2-device=list; then
  echo
  echo "TPM not detected."
  echo "Check Proxmox VM settings:"
  echo "- BIOS: OVMF (UEFI)"
  echo "- Machine: q35"
  echo "- TPM State: v2.0 added"
  exit 1
fi

pause

info "Step 3: Installing required packages"
apt update
apt install -y \
  systemd \
  cryptsetup-initramfs \
  tpm2-tools \
  clevis \
  clevis-luks \
  clevis-tpm2 \
  clevis-initramfs

info "Step 4: Current LUKS slots"
systemd-cryptenroll "$LUKS_DEVICE" || true

pause

info "Step 5: Enrolling TPM2 token (systemd-cryptenroll)"
echo "You may be asked for your current LUKS passphrase."
systemd-cryptenroll --tpm2-device=auto "$LUKS_DEVICE"

info "Step 6: Binding Clevis to TPM2 (recommended on Ubuntu)"
echo "You may be asked again for your current LUKS passphrase."
clevis luks bind -d "$LUKS_DEVICE" tpm2 '{}'

info "Step 7: Verifying Clevis binding"
clevis luks list -d "$LUKS_DEVICE" || true

info "Step 8: Showing /etc/crypttab"
cat /etc/crypttab || true

echo
cat <<EOF
Expected crypttab should look similar to:

<name> UUID=<uuid> none luks

Do NOT add: tpm2-device=auto
Ubuntu initramfs-tools often ignores that option.
EOF

pause

info "Step 9: Rebuilding initramfs"
update-initramfs -u -k all

info "Completed"
cat <<EOF

Setup finished.

Next steps:
1. Reboot the VM
2. Confirm it boots without asking for passphrase
3. Keep your manual recovery password forever
4. Test reboot again after kernel updates

Recommended test:
sudo reboot

EOF
