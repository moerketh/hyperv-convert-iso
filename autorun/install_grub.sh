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

# ── Determine distro-specific EFI bootloader ID ─────────────────────
# Kernel postinst hooks (e.g. zz-update-grub) write to EFI/<distro_id>/,
# so we install GRUB there as well as the removable fallback path.
distro_boot_id() {
    case "$ID" in
        ubuntu)                     echo "ubuntu" ;;
        kali)                       echo "kali" ;;
        parrot)                     echo "parrot" ;;
        debian)                     echo "debian" ;;
        fedora)                     echo "fedora" ;;
        opensuse-tumbleweed|opensuse-leap) echo "opensuse" ;;
        arch)                       echo "arch" ;;
        *)
            if [[ "${ID_LIKE:-}" =~ debian ]]; then echo "debian"
            elif [[ "${ID_LIKE:-}" =~ fedora ]]; then echo "fedora"
            elif [[ "${ID_LIKE:-}" =~ arch ]]; then echo "arch"
            elif [[ "${ID_LIKE:-}" =~ suse ]]; then echo "opensuse"
            else echo "GRUB"
            fi
            ;;
    esac
}

DISTRO_BOOT_ID=$(distro_boot_id)

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
  # Primary: distro-standard path (where kernel postinst hooks write)
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="$DISTRO_BOOT_ID" "$new_disk"
  # Fallback: removable media path (Hyper-V firmware always finds this)
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --removable "$new_disk"
  grub-mkconfig -o /boot/grub/grub.cfg
elif is_debian; then
  # Preserve oem-config if present — GRUB package changes can pull it in
  # as a cascade removal, breaking the OEM first-boot wizard.
  oem_held=false
  if dpkg -l oem-config 2>/dev/null | grep -q '^ii'; then
    apt-mark hold oem-config oem-config-gtk 2>/dev/null || true
    oem_held=true
  fi

  apt-get update --allow-releaseinfo-change -y || apt-get update -y

  if ! apt-get install -y grub-efi-amd64 efibootmgr os-prober; then
    # Hold may have caused a conflict — unhold, retry, then reinstall oem-config
    if $oem_held; then
      apt-mark unhold oem-config oem-config-gtk 2>/dev/null || true
      apt-get install -y grub-efi-amd64 efibootmgr os-prober
      apt-get install -y oem-config oem-config-gtk || true
      oem_held=false
    fi
  fi

  if $oem_held; then
    apt-mark unhold oem-config oem-config-gtk 2>/dev/null || true
  fi

  export PATH=$PATH:/usr/sbin:/sbin
  # Primary: distro-standard path (where kernel postinst hooks write)
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="$DISTRO_BOOT_ID" "$new_disk"
  # Fallback: removable media path (Hyper-V firmware always finds this)
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --removable "$new_disk"
  update-grub

  # ── Pin GRUB packages to prevent dpkg triggers from overwriting ESP ──
  apt-mark hold grub-efi-amd64-signed shim-signed 2>/dev/null || true
  echo "Held grub-efi-amd64-signed and shim-signed to prevent trigger overwrites"
elif is_fedora; then
  dnf install -y grub2-efi-x64 grub2-efi-x64-modules efibootmgr shim-x64
  export PATH=$PATH:/usr/sbin:/sbin
  # Primary: distro-standard path
  grub2-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="$DISTRO_BOOT_ID" "$new_disk"
  # Fallback: removable media path
  grub2-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --removable "$new_disk"
  grub2-mkconfig -o /boot/grub2/grub.cfg
elif is_suse; then
  zypper install -y grub2-x86_64-efi efibootmgr shim
  export PATH=$PATH:/usr/sbin:/sbin
  # Primary: distro-standard path
  grub2-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="$DISTRO_BOOT_ID" "$new_disk"
  # Fallback: removable media path
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