#!/bin/bash
set -e

# Source os-release to get $ID inside chroot
. /etc/os-release

new_disk="$1"

if [ "$ID" = "arch" ]; then
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
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB "$new_disk"
  grub-mkconfig -o /boot/grub/grub.cfg
elif [ "$ID" = "debian" ]; then
  apt-get update --allow-releaseinfo-change -y
  apt-get install -y grub-efi-amd64 efibootmgr os-prober
  export PATH=$PATH:/usr/sbin:/sbin
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB "$new_disk"
  update-grub
else
  echo "Unknown distribution: $ID"
  exit 1
fi