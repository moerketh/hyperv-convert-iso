#!/bin/bash
set -e

# Source os-release to get $ID inside chroot
. /etc/os-release

if [ "$ID" = "arch" ]; then
  pacman -Syy --noconfirm
  pacman -S --noconfirm xrdp
elif [ "$ID" = "debian" ]; then
  apt-get update -y
  apt install -y xrdp
  adduser xrdp ssl-cert
else
  echo "Unknown distribution: $ID"
  exit 1
fi

# Common XRDP configuration
sed -i '/^\[Globals\]/,/^\[/{s/^port=.*/port=vsock:\/\/-1:3389/}' /etc/xrdp/xrdp.ini
sed -i '/^\[Globals\]/,/^\[/{s/^security_layer=.*/security_layer=rdp/}' /etc/xrdp/xrdp.ini
sed -i '/^\[Globals\]/,/^\[/{s/^crypt_level=.*/crypt_level=none/}' /etc/xrdp/xrdp.ini
sed -i '/^\[Sessions\]/,/^\[/{s/^X11DisplayOffset=.*/X11DisplayOffset=0/}' /etc/xrdp/sesman.ini

# Enable and start services
systemctl enable xrdp
systemctl enable xrdp-sesman
systemctl start xrdp