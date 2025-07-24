#!/bin/bash
set -e

export HOME=/root
export LC_ALL=C

echo "ubuntu-live" > /etc/hostname

cat << EOT > /etc/apt/sources.list
deb http://us.archive.ubuntu.com/ubuntu/ noble main restricted universe multiverse
deb http://us.archive.ubuntu.com/ubuntu/ noble-updates main restricted universe multiverse
deb http://us.archive.ubuntu.com/ubuntu/ noble-security main restricted universe multiverse
EOT

apt-get update -y
apt-get upgrade -y
apt-get install -y dbus
dbus-uuidgen > /var/lib/dbus/machine-id

# Install kernel, live tools, and necessary packages
DEBIAN_FRONTEND=noninteractive apt-get install -y linux-azure casper console-setup keyboard-configuration coreutils systemd-sysv net-tools iproute2

# Configure systemd-networkd for DHCP on Ethernet
mkdir -p /etc/systemd/network
cat << EON > /etc/systemd/network/10-ethernet.network
[Match]
Name=eth*

[Network]
DHCP=ipv4
EON

# Enable systemd-networkd
systemctl enable systemd-networkd
systemctl enable systemd-networkd-wait-online

# Bootloaders for BIOS/UEFI/Secure Boot
apt-get install -y grub-pc grub-efi-amd64-signed shim-signed

# Packages for autorun script (disk tools)
apt-get install -y partclone gdisk e2fsprogs dosfstools rsync lvm2 efibootmgr os-prober grub2-common util-linux parted psmisc

# User setup for debug
adduser --disabled-password --gecos "" ubuntu
echo "ubuntu:ubuntu" | chpasswd
usermod -aG sudo ubuntu
echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ubuntu
chmod 0440 /etc/sudoers.d/ubuntu

# Create /var/crash to avoid boot error on missing directory
mkdir -p /var/crash

# Set up autorun service
cat << EOU > /etc/systemd/system/autorun.service
[Unit]
Description=Run autorun script on boot
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c "/usr/bin/autorun.sh"
StandardOutput=journal+console
StandardError=file:/var/log/autorun.err
RemainAfterExit=no
OnSuccess=poweroff.target
ExecStartPost=/bin/sh -c '[ $? = 0 ] && /usr/bin/systemctl poweroff'

[Install]
WantedBy=multi-user.target
EOU
ln -s /etc/systemd/system/autorun.service /etc/systemd/system/multi-user.target.wants/autorun.service

# Override getty@tty1 to wait for autorun completion
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat << EOG > /etc/systemd/system/getty@tty1.service.d/wait-for-autorun.conf
[Service]
ExecStartPre=-/bin/sh -c 'while [ ! -f /run/autorun-done ]; do sleep 1; done'
TTYReset=no
TTYVHangup=no
EOG

# Boot to console
systemctl set-default multi-user.target

# Python is always broken
rm /usr/bin/py3clean
rm /usr/bin/py3compile

# Purge unnecessary packages
apt-get purge -y manpages* libllvm18 libicu74

# Limit locales to English only
apt-get purge -y locales
apt-get install -y locales
locale-gen en_US.UTF-8
update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8

# Clean up documentation, manpages, extra locales, and python remnants
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* /usr/lib/python* /usr/bin/python*
#rm -rf /usr/share/locale/!(en|en_US|en_US.UTF-8)

# More cleanup
apt-get autoremove -y
apt-get clean -y
rm -rf /tmp/* /var/tmp/* /var/lib/apt/lists/* /var/cache/apt/archives/* /var/log/* /var/cache/debconf/*

rm -f /var/lib/dbus/machine-id
truncate -s 0 /etc/machine-id

exit
