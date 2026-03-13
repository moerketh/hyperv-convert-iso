#!/bin/bash
set -e

# Source os-release to get $ID and $ID_LIKE inside chroot
. /etc/os-release

new_disk="$1"

# Determine the package manager family
is_arch() { [ "$ID" = "arch" ] || [[ "${ID_LIKE:-}" =~ arch ]]; }
is_debian() { [ "$ID" = "debian" ] || [ "$ID" = "ubuntu" ] || [[ "${ID_LIKE:-}" =~ debian ]]; }
is_fedora() { [ "$ID" = "fedora" ] || [[ "${ID_LIKE:-}" =~ fedora ]]; }
is_suse() { [ "$ID" = "opensuse-tumbleweed" ] || [ "$ID" = "opensuse-leap" ] || [[ "${ID_LIKE:-}" =~ suse ]]; }

if is_arch; then
  # Remove deprecated repositories with a single sed command
  sed -i '/^\[\(community\|community-testing\|testing\|testing-debug\|staging\|staging-debug\)\]$/,/^\[/ { /^\[/!d; /^\[\(community\|community-testing\|testing\|testing-debug\|staging\|staging-debug\)\]$/d }' /etc/pacman.conf
  echo 'Pacman update'
  pacman -Syy --noconfirm
  #Update and install grub
  echo 'Pacman update keyring'
  pacman -S --noconfirm archlinux-keyring blackarch-keyring
  echo 'Pacman update glibc'
  pacman -S --noconfirm --overwrite '/usr/lib/initcpio/*' mkinitcpio #required for lvm2
  pacman -S --noconfirm --needed glibc lib32-glibc lvm2 device-mapper
  pacman -S --noconfirm linux-lts hyperv
  echo 'Pacman install grub'
  pacman -S --noconfirm grub efibootmgr os-prober
  export PATH=$PATH:/usr/sbin:/sbin
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --removable "$new_disk"
  grub-mkconfig -o /boot/grub/grub.cfg
elif is_debian; then
  apt-get update --allow-releaseinfo-change -y || apt-get update -y
  apt-get install -y grub-efi-amd64 efibootmgr os-prober
  export PATH=$PATH:/usr/sbin:/sbin
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --removable "$new_disk"
  update-grub
elif is_fedora; then
  dnf install -y grub2-efi-x64 grub2-efi-x64-modules efibootmgr shim-x64
  export PATH=$PATH:/usr/sbin:/sbin
  grub2-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --removable "$new_disk"
  grub2-mkconfig -o /boot/grub2/grub.cfg
elif is_suse; then
  zypper install -y grub2-x86_64-efi efibootmgr shim
  export PATH=$PATH:/usr/sbin:/sbin
  grub2-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --removable "$new_disk"
  grub2-mkconfig -o /boot/grub2/grub.cfg
else
  echo "Unknown distribution: $ID (ID_LIKE: ${ID_LIKE:-none})"
  exit 1
fi

# ── Determine GRUB directory ─────────────────────────────────────────
if [ -d /boot/grub2 ]; then
    grub_dir="/boot/grub2"
else
    grub_dir="/boot/grub"
fi

# ── Verify grub.cfg was generated on root partition ──────────────────
echo "--- GRUB verification ---"
if [ ! -f "$grub_dir/grub.cfg" ]; then
    echo "WARNING: $grub_dir/grub.cfg not found after grub install!"
elif ! grep -q 'menuentry\|linux' "$grub_dir/grub.cfg" 2>/dev/null; then
    echo "WARNING: $grub_dir/grub.cfg exists but has no boot entries"
else
    echo "OK: $grub_dir/grub.cfg has boot entries"
fi

# ── Verify EFI binary was installed ──────────────────────────────────
efi_binary=""
for candidate in /boot/efi/EFI/BOOT/BOOTX64.EFI /boot/efi/EFI/BOOT/bootx64.efi \
                 /boot/efi/EFI/BOOT/grubx64.efi /boot/efi/EFI/GRUB/grubx64.efi; do
    if [ -f "$candidate" ]; then
        efi_binary="$candidate"
        break
    fi
done
if [ -n "$efi_binary" ]; then
    echo "OK: EFI binary found at $efi_binary"
else
    echo "ERROR: No EFI binary found on ESP after grub-install!"
    ls -laR /boot/efi/ 2>&1 || true
    exit 1
fi

echo "--- ESP contents after grub-install ---"
find /boot/efi -type f 2>&1 || true
echo "---"