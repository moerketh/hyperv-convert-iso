#!/bin/bash
set -eo pipefail

# Source utility functions
source /opt/autorun/../lib/functions.sh

echo "=== autorun.sh started at $(date -Iseconds) ==="

# ── Diagnostics ──────────────────────────────────────────────────────
echo "--- Environment ---"
echo "Kernel: $(uname -r)"
echo "Hostname: $(hostname)"
echo "Block devices:"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>&1 || true

echo "--- Hyper-V KVP daemon status ---"
systemctl is-active hv_kvp_daemon.service 2>&1 || echo "(service not found or inactive)"
ls -la /var/lib/hyperv/ 2>&1 || echo "/var/lib/hyperv/ does not exist"
echo "Pool 0 size: $(stat -c%s /var/lib/hyperv/.kvp_pool_0 2>/dev/null || echo 'N/A') bytes"

echo "--- Dumping all host-to-guest KVP entries (pool 0) ---"
if [ -f /var/lib/hyperv/.kvp_pool_0 ]; then
    read_kvp "/var/lib/hyperv/.kvp_pool_0" 2>&1 || \
        strings /var/lib/hyperv/.kvp_pool_0 2>/dev/null | head -40 || \
        echo "(unable to dump pool file)"
else
    echo "Pool file does not exist yet"
fi
echo "---------------------------------------------------"

# ── Wait for Hyper-V KVP daemon to deliver host-to-guest data ────────
# The host pushes VMCREATE_MODE (and other flags) via WMI after the VM starts,
# but hv_kvp_daemon may not have flushed them to .kvp_pool_0 by the time
# autorun.service fires. Retry for up to 30 seconds before falling through
# to the default (clone) workflow.
VMCREATE_MODE=""
for i in $(seq 1 30); do
    VMCREATE_MODE=$(read_kvp_value "/var/lib/hyperv/.kvp_pool_0" "VMCREATE_MODE")
    if [ -n "$VMCREATE_MODE" ]; then
        echo "VMCREATE_MODE=$VMCREATE_MODE received after ${i}s"
        break
    fi
    # Also check if there are two sd* block devices (clone scenario doesn't
    # need VMCREATE_MODE) — if so, no point waiting further.
    disk_count=$(ls -1 /dev/sd[a-z] 2>/dev/null | wc -l)
    if [ "$disk_count" -ge 2 ]; then
        echo "Two disks detected after ${i}s, proceeding with clone workflow (no VMCREATE_MODE needed)"
        break
    fi
    # Log progress every 5 seconds
    if (( i % 5 == 0 )); then
        echo "Waiting for KVP... ${i}s elapsed (pool size: $(stat -c%s /var/lib/hyperv/.kvp_pool_0 2>/dev/null || echo 'N/A') bytes, disks: $(ls -1 /dev/sd[a-z] 2>/dev/null | wc -l))"
    fi
    sleep 1
done

echo "--- Post-wait KVP dump ---"
read_kvp "/var/lib/hyperv/.kvp_pool_0" 2>&1 || \
    strings /var/lib/hyperv/.kvp_pool_0 2>/dev/null | head -40 || \
    echo "(unable to dump pool file)"

echo "--- Decision ---"
echo "VMCREATE_MODE='${VMCREATE_MODE}'"
echo "Disk count: $(ls -1 /dev/sd[a-z] 2>/dev/null | wc -l)"

if [ "$VMCREATE_MODE" = "customize" ]; then
    echo "VMCREATE_MODE=customize detected, running customize-only workflow"
    exec /bin/bash /opt/autorun/customize_only.sh
fi

echo "Falling through to clone workflow"

# Set trap for cleanup on script exit
trap cleanup_mounts EXIT

# Detect disks: new (empty, no partitions) and old (has partitions)
detect_disks

report_progress "PREFLIGHT" "Disk detection complete"

# Run pre-flight checks before proceeding with disk operations
preflight_checks

# Partition new disk (GPT with ESP and root)
report_progress "PARTITION" "Starting disk partitioning"
sgdisk --zap-all $new_disk
sgdisk --new=1:2048:+512M --typecode=1:ef00 --change-name=1:ESP $new_disk  # ESP
sgdisk --new=2::0 --typecode=2:8300 --change-name=2:root $new_disk         # Root (rest, combined boot/root)
retry 3 1 partprobe "$new_disk"
udevadm settle

# Detect partitions on old_disk
echo "Detecting partitions on $old_disk" | tee -a /tmp/clone.log

detect_partitions "$old_disk"

# Format new ESP partition (only needed if no source ESP to clone, but partclone
# will overwrite it if there is one — cheap to do unconditionally for vfat)
mkfs.vfat -F32 "${new_disk}1"

# Only format root if partclone will NOT overwrite it (shouldn't happen, but guard)
# partclone.ext4 --dev-to-dev overwrites the partition, so skip mkfs.ext4

# Clone root
report_progress "CLONE_ROOT" "Starting root partition cloning"
echo "Cloning root from $root_part to ${new_disk}2"



# Run partclone in background with logfile
# Use a named pipe so we can capture partclone's exit code directly
partclone.ext4 --force --dev-to-dev --source "$root_part" --output "${new_disk}2" --logfile /tmp/partclone.log 2>&1 | tee -a /tmp/partclone_process.log &
clone_pipeline_pid=$!

while kill -0 $clone_pipeline_pid 2>/dev/null; do
    if [ -f /tmp/partclone_process.log ]; then
        # Clean last 20 lines (adjust as needed) with ansifilter
        cleaned=$(tail -n 20 /tmp/partclone_process.log | ansifilter --text)
        # Parse with awk: focus on Elapsed lines, extract 6th field as percentage (remove % and ,), 7th as rate number
        progress=$(echo "$cleaned" | awk '
            /Elapsed:/ {
                perc = $6;
                gsub(/[%,\s]/, "", perc);  # Remove %, ,, and any spaces
                rate = $7;
                gsub(/[\s]/, "", rate);  # Clean rate if needed
                print "Progress: " perc "% | Rate: " rate " GB/min"
            }
        ' | tail -n 1)  # Take the last matching line to get the most recent update

        if [ -n "$progress" ]; then
            send_kvp "PartcloneProgress" "$progress"
        fi
    else
        echo "Waiting for partclone.log to be created..."  # Optional debug message
    fi
    sleep 1  # Poll interval
done

# Wait for the pipeline to finish and check exit code (pipefail ensures partclone failures propagate)
wait $clone_pipeline_pid
clone_exit=$?
if [ $clone_exit -ne 0 ]; then
    report_progress "CLONE_ERROR" "Root partition cloning failed with exit code $clone_exit"
    echo "ERROR: partclone.ext4 failed with exit code $clone_exit" | tee -a /tmp/error.log
    exit 1
fi

# Send final completion KVP
send_kvp "PartcloneProgress" "Completed: 100% | Done"
echo "Partclone conversion completed."

# Clone ESP if detected
if [ -n "$esp_part" ]; then
  report_progress "CLONE_ESP" "Starting ESP partition cloning"
  echo "Cloning ESP from $esp_part to ${new_disk}1"
  partclone.vfat --force --dev-to-dev --source "$esp_part" --output "${new_disk}1" 2>&1
  esp_clone_exit=$?
  if [ $esp_clone_exit -ne 0 ]; then
      report_progress "CLONE_ERROR" "ESP cloning failed with exit code $esp_clone_exit"
      echo "ERROR: partclone.vfat failed with exit code $esp_clone_exit" | tee -a /tmp/error.log
      exit 1
  fi
else
  echo "No ESP detected on old disk (new ESP will be populated by grub-install)."
fi

# Verify cloned partitions are clean
report_progress "VERIFY" "Verifying cloned filesystems"
if verify_clone "${new_disk}2" "${new_disk}1"; then
    echo "Filesystem verification PASSED"
else
    echo "ERROR: Filesystem verification FAILED" | tee -a /tmp/error.log
    exit 1
fi

# Mount new root and ESP
mkdir -p /mnt/new
retry 3 1 mount ${new_disk}2 /mnt/new
mkdir -p /mnt/new/boot/efi
retry 3 1 mount ${new_disk}1 /mnt/new/boot/efi

# Merge separate /boot if detected
if [ ! -z "$boot_part" ]; then
  report_progress "MERGE_BOOT" "Merging separate /boot partition"
  echo "Merging /boot from $boot_part into /mnt/new/boot/"
  temp_old_boot="/tmp/old_boot"
  mkdir -p "$temp_old_boot"
  mount $boot_part "$temp_old_boot"
  rsync -av "$temp_old_boot/" /mnt/new/boot/
  umount "$temp_old_boot"
  rmdir "$temp_old_boot"
fi

# Update fstab with new UUIDs
report_progress "UPDATE_FSTAB" "Updating fstab with new UUIDs"
update_fstab "/mnt/new/etc/fstab" "$root_part" "${new_disk}1" "${new_disk}2"

# Bind mounts for chroot
mount --bind /dev /mnt/new/dev
mount --bind /proc /mnt/new/proc
mount --bind /sys /mnt/new/sys
#mount --bind /run /mnt/new/run
mount --bind /dev/pts /mnt/new/dev/pts
modprobe efivarfs
mount --bind /sys/firmware/efi/efivars /mnt/new/sys/firmware/efi/efivars || true
mount --bind /etc/resolv.conf /mnt/new/etc/resolv.conf || cp -L /etc/resolv.conf /mnt/new/etc/resolv.conf

# copy autorun files
mkdir -p /mnt/new/opt/autorun
cp /opt/autorun/* /mnt/new/opt/autorun

# Install grub with UEFI support
report_progress "INSTALL_GRUB" "Installing GRUB bootloader"
chroot /mnt/new /bin/bash /opt/autorun/install_grub.sh "$new_disk"
rm /mnt/new/opt/autorun/install_grub.sh

# ── Hyper-V guest optimization ───────────────────────────────────────
# Install daemons that make the guest a first-class Hyper-V citizen.
# Non-fatal: if the distro can't install these, the VM still works.
report_progress "HYPERV_OPTIMIZE" "Installing Hyper-V guest integration services"
echo "Installing Hyper-V guest optimizations..."
if chroot /mnt/new /bin/bash -c '
    export DEBIAN_FRONTEND=noninteractive
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y -qq
        apt-get install -y -qq hyperv-daemons openssh-server 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q hyperv-daemons openssh-server 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q hyperv-daemons openssh-server 2>&1
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm hyperv openssh 2>&1
    else
        echo "Unknown package manager — skipping Hyper-V optimization"
        exit 1
    fi
    systemctl enable hv_kvp_daemon.service 2>/dev/null || true
    systemctl enable hv_vss_daemon.service 2>/dev/null || true
    systemctl enable hv_fcopy_daemon.service 2>/dev/null || true
    systemctl enable ssh.service 2>/dev/null || systemctl enable sshd.service 2>/dev/null || true
'; then
    echo "Hyper-V guest optimization completed successfully"
else
    report_progress "HYPERV_OPTIMIZE_WARNING" "Hyper-V optimization partially failed (non-fatal)"
    echo "WARNING: Some Hyper-V optimizations could not be installed (non-fatal)" | tee -a /tmp/error.log
fi

# Read KVP flags using the proper binary reader
XRDP_FLAG=$(read_kvp_value "/var/lib/hyperv/.kvp_pool_0" "VMCREATE_XRDP")
if [ "$XRDP_FLAG" = "true" ]; then
    report_progress "INSTALL_XRDP" "Installing XRDP for Enhanced Session support"
    echo "Installing xrdp for Hyper-V Enhanced Session support"
    # Non-fatal: a failed XRDP install should not invalidate a successful conversion
    if chroot /mnt/new /bin/bash /opt/autorun/install_xrdp.sh; then
        echo "XRDP installation completed successfully"
    else
        report_progress "XRDP_WARNING" "XRDP installation failed, VM will boot without XRDP"
        echo "WARNING: XRDP installation failed, continuing..." | tee -a /tmp/error.log
    fi
    rm -f /mnt/new/opt/autorun/install_xrdp.sh
fi

# ── Install pwsh for PowerShell Direct on target VM ──────────────────
# Required for post-boot customization via Invoke-Command -VMName.
report_progress "INSTALL_PWSH" "Installing PowerShell for post-boot configuration"
echo "Installing PowerShell on target VM..."
if chroot /mnt/new /bin/bash /opt/autorun/install_pwsh.sh; then
    echo "PowerShell installation completed successfully"
else
    report_progress "PWSH_WARNING" "PowerShell installation failed (post-boot config will not be available)"
    echo "WARNING: PowerShell installation failed, continuing..." | tee -a /tmp/error.log
fi
rm -f /mnt/new/opt/autorun/install_pwsh.sh

# ── Create automation user and inject SSH key on target VM ───────────
# The 'vmcreate' user is used by the host for post-boot SSH connections.
# The SSH public key is sent via KVP from the host — retry for up to 30s
# in case the KVP hasn't been flushed yet (hv_kvp_daemon latency).
report_progress "SSH_SETUP" "Setting up automation user and SSH key on target VM"
SSH_PUBKEY=""
for i in $(seq 1 30); do
    SSH_PUBKEY=$(read_kvp_value "/var/lib/hyperv/.kvp_pool_0" "VMCREATE_SSH_PUBKEY")
    if [ -n "$SSH_PUBKEY" ]; then
        echo "VMCREATE_SSH_PUBKEY received after ${i}s (${#SSH_PUBKEY} bytes)"
        break
    fi
    if (( i % 5 == 0 )); then
        echo "Waiting for SSH public key in KVP... ${i}s elapsed"
    fi
    sleep 1
done
if [ -n "$SSH_PUBKEY" ]; then
    echo "Injecting SSH key and creating vmcreate automation user on target VM"
    chroot /mnt/new /bin/bash -c "
        # Create vmcreate user if it doesn't exist
        if ! id vmcreate >/dev/null 2>&1; then
            adduser --disabled-password --gecos 'VMCreate Automation' vmcreate
            usermod -aG sudo vmcreate
            echo 'vmcreate ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/vmcreate
            chmod 0440 /etc/sudoers.d/vmcreate
        fi
        # Install SSH public key
        mkdir -p /home/vmcreate/.ssh
        echo \"$SSH_PUBKEY\" > /home/vmcreate/.ssh/authorized_keys
        chown -R vmcreate:vmcreate /home/vmcreate/.ssh
        chmod 700 /home/vmcreate/.ssh
        chmod 600 /home/vmcreate/.ssh/authorized_keys
        # Ensure pubkey auth is enabled
        sed -i 's/^#\\?PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
    " || echo "WARNING: SSH key injection failed (non-fatal)" | tee -a /tmp/error.log
else
    echo "No SSH public key in KVP — skipping automation user setup"
fi

# Remove Virtual Box Guest Additions (non-fatal)
echo "Removing Virtualbox Guest Additions"
chroot /mnt/new /bin/bash -c 'for d in /opt/VBoxGuestAdditions-*; do "$d/uninstall.sh" || true; done' || true

report_progress "CLEANUP" "Workflow completed successfully"
echo "autorun completed"

# Read debug flag using proper KVP reader
DEBUG_FLAG=$(read_kvp_value "/var/lib/hyperv/.kvp_pool_0" "VMCREATE_DEBUG")

if [ "$DEBUG_FLAG" = "true" ]; then
    echo "Debug flag set; VM will remain running for inspection."
    echo "Login via Hyper-V console to inspect. Run 'systemctl poweroff' when done."
    # Exit with error to prevent OnSuccess=poweroff.target from firing
    exit 1
fi

echo "Autorun completed successfully; systemd will handle shutdown via OnSuccess=poweroff.target."
exit 0
