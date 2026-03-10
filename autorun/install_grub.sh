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