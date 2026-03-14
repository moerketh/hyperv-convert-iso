#!/bin/bash
set -e

export HOME=/root
echo "autorun" > /etc/hostname

cat << EOT > /etc/apt/sources.list
deb http://archive.ubuntu.com/ubuntu/ noble main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ noble-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu/ noble-security main restricted universe multiverse
EOT

apt-get update -y
apt-get upgrade -y
apt-get install -y --no-install-recommends dbus
dbus-uuidgen > /var/lib/dbus/machine-id

# Install kernel, live tools, and necessary packages
# Resolve the specific kernel version from the linux-azure meta-package so we
# can install only the image, modules and cloud-tools — skipping the bulky
# linux-headers and linux-tools that the meta-package pulls in (~150 MB saved).
# linux-azure → linux-image-azure → linux-image-X.Y.Z-N-azure (two hops)
KVER=$(apt-cache depends linux-image-azure 2>/dev/null \
    | grep -o 'linux-image-[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*-[0-9][0-9]*-azure' \
    | sed 's/^linux-image-//' | head -1)
if [ -z "$KVER" ]; then
    echo "ERROR: Could not resolve kernel version from linux-image-azure" >&2
    exit 1
fi
echo "Resolved kernel version: $KVER"
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    linux-image-${KVER} linux-modules-${KVER} linux-cloud-tools-${KVER} \
    casper coreutils systemd-sysv iproute2 zstd

# ── Strip kernel modules not needed for Hyper-V ──────────────────────
# linux-azure ships hundreds of modules for bare-metal Azure hosts.
# The live ISO only needs Hyper-V synthetic drivers, storage, filesystems,
# and basic networking. Removing the rest saves 30-50 MB in the squashfs.
KMOD_DIR=$(find /lib/modules -maxdepth 1 -mindepth 1 -type d | head -n1)
if [ -d "$KMOD_DIR/kernel" ]; then
    echo "Stripping unnecessary kernel modules from $KMOD_DIR ..."
    # Remove large driver subtrees that are irrelevant inside Hyper-V
    rm -rf "$KMOD_DIR/kernel/drivers/gpu"
    rm -rf "$KMOD_DIR/kernel/drivers/net/wireless"
    rm -rf "$KMOD_DIR/kernel/drivers/bluetooth"
    rm -rf "$KMOD_DIR/kernel/drivers/media"
    rm -rf "$KMOD_DIR/kernel/drivers/usb" # no USB passthrough on the live ISO
    rm -rf "$KMOD_DIR/kernel/drivers/staging"
    rm -rf "$KMOD_DIR/kernel/drivers/infiniband"
    rm -rf "$KMOD_DIR/kernel/drivers/isdn"
    rm -rf "$KMOD_DIR/kernel/drivers/nfc"
    rm -rf "$KMOD_DIR/kernel/drivers/thunderbolt"
    rm -rf "$KMOD_DIR/kernel/drivers/firewire"
    rm -rf "$KMOD_DIR/kernel/drivers/pcmcia"
    rm -rf "$KMOD_DIR/kernel/drivers/platform"
    rm -rf "$KMOD_DIR/kernel/drivers/iio"
    rm -rf "$KMOD_DIR/kernel/drivers/hwmon"
    rm -rf "$KMOD_DIR/kernel/drivers/leds"
    rm -rf "$KMOD_DIR/kernel/drivers/input/joystick"
    rm -rf "$KMOD_DIR/kernel/drivers/input/touchscreen"
    rm -rf "$KMOD_DIR/kernel/drivers/input/gameport"
    rm -rf "$KMOD_DIR/kernel/sound"
    rm -rf "$KMOD_DIR/kernel/net/wireless"
    rm -rf "$KMOD_DIR/kernel/net/bluetooth"
    rm -rf "$KMOD_DIR/kernel/net/mac80211"
    rm -rf "$KMOD_DIR/kernel/net/nfc"
    # Rebuild module dependency map
    depmod -a "$(basename "$KMOD_DIR")"
    echo "Kernel module stripping complete."
fi

# Purge linux-firmware — Hyper-V uses synthetic drivers, no firmware blobs needed
apt-get purge -y linux-firmware 2>/dev/null || true

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

# Bootloaders for UEFI/Secure Boot (Gen 2 only — no BIOS support)
apt-get install -y --no-install-recommends grub-efi-amd64-signed shim-signed

# Packages for autorun script (disk tools)
apt-get install -y --no-install-recommends partclone gdisk e2fsprogs dosfstools rsync lvm2 efibootmgr grub2-common util-linux parted psmisc

# Install btrfs-progs for btrfs root filesystem support (e.g. Parrot OS)
apt-get install -y --no-install-recommends btrfs-progs

# ── SSH for PowerShell Direct ────────────────────────────────────────
# Hyper-V PowerShell Direct on Linux guests uses SSH over VMBus (AF_VSOCK).
# This lets the host run commands inside the ISO guest without any network,
# which is used for:
#   1. Automated testing — pull journalctl output from the host terminal
#   2. Post-boot customization — drive configuration directly instead of KVP signaling
# Authentication: key-only. The host injects its SSH public key via KVP at boot
# time. Password auth is disabled for security.
apt-get install -y --no-install-recommends openssh-server
# Disable password auth — key-only access via KVP-injected pubkey
sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config
# Enable SSH early so it's available before autorun starts
systemctl enable ssh

# User setup — ubuntu user for SSH (key-only auth, no password)
adduser --disabled-password --gecos "" ubuntu
usermod -aG sudo ubuntu
echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ubuntu
chmod 0440 /etc/sudoers.d/ubuntu

# Prepare SSH authorized_keys directory (key injected at runtime via KVP)
mkdir -p /home/ubuntu/.ssh
touch /home/ubuntu/.ssh/authorized_keys
chown -R ubuntu:ubuntu /home/ubuntu/.ssh
chmod 700 /home/ubuntu/.ssh
chmod 600 /home/ubuntu/.ssh/authorized_keys

# ── KVP SSH key injection service ────────────────────────────────────
# Runs early at boot to read the host-injected SSH public key from KVP
# pool 0 and install it into the ubuntu user's authorized_keys.
# This enables PowerShell Direct with key-based auth.
cat << 'KVPKEY' > /opt/autorun/inject_ssh_key.sh
#!/bin/bash
# Read SSH public key from host-to-guest KVP and install it.
# The host sends the key ~12-15s after VM boot (after a 10s settle
# delay + padding KVPs). Retry for up to 60s so the key has time
# to arrive via hv_kvp_daemon.
POOL="/var/lib/hyperv/.kvp_pool_0"
KEY_SIZE=512
VALUE_SIZE=2048

# Wait for KVP pool file to appear (up to 30s)
for i in $(seq 1 30); do
    [ -f "$POOL" ] && break
    sleep 1
done
[ -f "$POOL" ] || exit 0

# Retry reading the key for up to 60s (host sends it ~12-15s after boot)
pubkey=""
for attempt in $(seq 1 60); do
    index=0
    while true; do
        offset=$((index * (KEY_SIZE + VALUE_SIZE)))
        key=$(dd status=none if="$POOL" bs=1 skip="$offset" count="$KEY_SIZE" 2>/dev/null | tr -d '\0')
        [ -z "$key" ] && break
        if [ "$key" = "VMCREATE_SSH_PUBKEY" ]; then
            value_offset=$((offset + KEY_SIZE))
            pubkey=$(dd status=none if="$POOL" bs=1 skip="$value_offset" count="$VALUE_SIZE" 2>/dev/null | tr -d '\0')
            break 2
        fi
        index=$((index + 1))
    done
    if (( attempt % 10 == 0 )); then
        echo "inject_ssh_key: waiting for VMCREATE_SSH_PUBKEY... ${attempt}s"
    fi
    sleep 1
done

if [ -n "$pubkey" ]; then
    # Install for ubuntu user (ISO debug access)
    mkdir -p /home/ubuntu/.ssh
    echo "$pubkey" > /home/ubuntu/.ssh/authorized_keys
    chown -R ubuntu:ubuntu /home/ubuntu/.ssh
    chmod 700 /home/ubuntu/.ssh
    chmod 600 /home/ubuntu/.ssh/authorized_keys
    echo "SSH public key injected for ubuntu user after ${attempt}s"
else
    echo "inject_ssh_key: VMCREATE_SSH_PUBKEY not found after 60s — skipping"
fi
KVPKEY
chmod +x /opt/autorun/inject_ssh_key.sh

# Systemd service to run key injection early in boot
cat << 'KVPUNIT' > /etc/systemd/system/inject-ssh-key.service
[Unit]
Description=Inject SSH public key from Hyper-V KVP
After=hv-kvp-daemon.service
Before=ssh.service autorun.service
Wants=hv-kvp-daemon.service

[Service]
Type=oneshot
ExecStart=/bin/bash /opt/autorun/inject_ssh_key.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
KVPUNIT
systemctl enable inject-ssh-key.service

# Create /var/crash to avoid boot error on missing directory
mkdir -p /var/crash

# Set up autorun service
cat << EOU > /etc/systemd/system/autorun.service
[Unit]
Description=Run autorun script on boot
After=multi-user.target ssh.service
Wants=ssh.service
OnSuccess=poweroff.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c "/opt/autorun/autorun.sh"
StandardOutput=journal+console
StandardError=journal+console
RemainAfterExit=no

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
apt-get install -y --no-install-recommends locales
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
