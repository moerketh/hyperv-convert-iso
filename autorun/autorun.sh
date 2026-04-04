#!/bin/bash
set -eo pipefail

# Source utility functions
source /opt/autorun/../lib/functions.sh

echo "=== autorun.sh started at $(date -Iseconds) ==="
echo "hyperv-convert-iso version: $(cat /etc/hyperv-convert-version 2>/dev/null || echo 'unknown')"

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

# Detect root filesystem type for correct partclone tool selection
root_fs_type=$(blkid -o value -s TYPE "$root_part" 2>/dev/null || echo "ext4")
echo "Root filesystem type: $root_fs_type"
clone_tool=$(select_partclone_tool "$root_fs_type")
if [ -z "$clone_tool" ]; then
    echo "ERROR: Unsupported root filesystem type: $root_fs_type" | tee -a /tmp/error.log
    exit 1
fi
echo "Selected clone tool: $clone_tool"

# Format new ESP partition (only needed if no source ESP to clone, but partclone
# will overwrite it if there is one — cheap to do unconditionally for vfat)
mkfs.vfat -F32 "${new_disk}1"

# Only format root if partclone will NOT overwrite it (shouldn't happen, but guard)
# partclone --dev-to-dev overwrites the partition, so skip mkfs

# Clone root
report_progress "CLONE_ROOT" "Starting root partition cloning"
echo "Cloning root from $root_part to ${new_disk}2 using $clone_tool"



# Run partclone in background with logfile
# Use a named pipe so we can capture partclone's exit code directly
$clone_tool --force --dev-to-dev --source "$root_part" --output "${new_disk}2" --logfile /tmp/partclone.log 2>&1 | tee -a /tmp/partclone_process.log &
clone_pipeline_pid=$!

while kill -0 $clone_pipeline_pid 2>/dev/null; do
    if [ -f /tmp/partclone_process.log ]; then
        # Clean last 20 lines — convert \r to \n (partclone uses \r for in-place
        # updates), then strip ANSI escape codes.
        cleaned=$(tail -n 20 /tmp/partclone_process.log | tr '\r' '\n' | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g')
        # Parse with awk: use regex to extract percentage and rate from Elapsed lines.
        # Partclone rate may be in GB/min, MB/min, or KB/min — forward the actual unit.
        progress=$(echo "$cleaned" | awk '
            /Elapsed:/ {
                perc = ""
                rate = ""
                for (i = 1; i <= NF; i++) {
                    if (perc == "" && $i ~ /^[0-9.]+%/) {
                        perc = $i
                        gsub(/[%,]/, "", perc)
                    }
                    if (rate == "" && $i ~ /[0-9][GgMmKk][Bb]\/min/) {
                        rate = $i
                        gsub(/,$/, "", rate)
                    }
                }
                if (perc != "") {
                    if (rate != "")
                        print "Progress: " perc "% | Rate: " rate
                    else
                        print "Progress: " perc "%"
                }
            }
        ' | tail -n 1)

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
    echo "ERROR: $clone_tool failed with exit code $clone_exit" | tee -a /tmp/error.log
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

# Resize root filesystem to fill the new (potentially larger) partition
report_progress "RESIZE" "Resizing root filesystem to fill partition"
resize_cloned_filesystem "${new_disk}2" "$root_fs_type"

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

# Validate fstab for stale references to old disk
validate_fstab "/mnt/new/etc/fstab" "$old_disk"

# Create swap file to replace the removed swap partition
report_progress "CREATE_SWAP" "Creating swap file"
create_swap_file /mnt/new

# Bind mounts for chroot
mount --bind /dev /mnt/new/dev
mount --bind /proc /mnt/new/proc
mount --bind /sys /mnt/new/sys
#mount --bind /run /mnt/new/run
mount --bind /dev/pts /mnt/new/dev/pts
modprobe efivarfs
mount --bind /sys/firmware/efi/efivars /mnt/new/sys/firmware/efi/efivars || true
setup_chroot_dns /mnt/new

# copy autorun files
mkdir -p /mnt/new/opt/autorun
cp /opt/autorun/* /mnt/new/opt/autorun

# Install grub with UEFI support
report_progress "INSTALL_GRUB" "Installing GRUB bootloader"
chroot /mnt/new /bin/bash /opt/autorun/install_grub.sh "$new_disk"
rm /mnt/new/opt/autorun/install_grub.sh

# ── Disable stale resume (hibernate) device ──────────────────────────
# The old MBR disk may have had a swap partition configured as the resume
# device. The new GPT disk has no swap, so the stale UUID causes a ~90s
# boot delay ("Gave up waiting for suspend/resume device").
echo "Disabling stale resume device references..."
if [ -f /mnt/new/etc/initramfs-tools/conf.d/resume ]; then
    echo "RESUME=none" > /mnt/new/etc/initramfs-tools/conf.d/resume
    echo "Cleared /etc/initramfs-tools/conf.d/resume"
fi
# Also strip resume= from GRUB command line defaults
if [ -f /mnt/new/etc/default/grub ]; then
    sed -i 's/resume=UUID=[^ ]*/noresume/g; s/resume=\/dev\/[^ ]*/noresume/g' /mnt/new/etc/default/grub
fi

# ── Install kernel postinst hook for ESP redirect ────────────────────
# This hook re-generates the ESP redirect grub.cfg after every kernel
# install, ensuring the boot chain survives future package upgrades.
install_grub_postinst_hook /mnt/new

# ── Force Hyper-V modules into initramfs ─────────────────────────────
# Ensure hv_vmbus, hv_storvsc, hv_netvsc, hv_utils are included so the
# VM can find its root disk after kernel upgrades.
ensure_hyperv_initramfs_modules /mnt/new

# Regenerate initramfs so the resume hook and Hyper-V modules take effect
if chroot /mnt/new /bin/bash -c 'command -v update-initramfs >/dev/null 2>&1'; then
    echo "Regenerating initramfs..."
    chroot /mnt/new update-initramfs -u -k all 2>&1 || echo "WARNING: update-initramfs failed (non-fatal)"
elif chroot /mnt/new /bin/bash -c 'command -v dracut >/dev/null 2>&1'; then
    echo "Regenerating initramfs (dracut)..."
    chroot /mnt/new dracut --force 2>&1 || echo "WARNING: dracut failed (non-fatal)"
elif chroot /mnt/new /bin/bash -c 'command -v mkinitcpio >/dev/null 2>&1'; then
    echo "Regenerating initramfs (mkinitcpio)..."
    chroot /mnt/new mkinitcpio -P 2>&1 || echo "WARNING: mkinitcpio failed (non-fatal)"
fi

# ── Capture SSH state BEFORE any chroot apt calls ────────────────────
capture_ssh_state /mnt/new

# ── Fix conflicting apt sources ──────────────────────────────────────
fix_apt_repo_conflicts /mnt/new
# ── Start Tor if the target uses tor+https APT sources ──────────────
start_tor_if_needed /mnt/new

# ── Configure temporary second NIC for post-boot SSH ─────────────────
# Writes firewall rules + DHCP config for eth1; no-op if not needed.
configure_temp_nic /mnt/new

# ── Hyper-V guest optimization ───────────────────────────────────────
report_progress "INSTALL_HYPERV_PACKAGES" "Installing Hyper-V guest integration services"
install_hyperv_packages /mnt/new

# ── Ensure critical services are enabled via direct symlinks ──────────
enable_services_via_symlinks /mnt/new

# Generate SSH host keys if missing
generate_ssh_host_keys /mnt/new

# ── Fix network configs: replace hardcoded interface names ────────────
fix_netplan_for_hyperv /mnt/new
fix_networkmanager_for_hyperv /mnt/new
fix_interfaces_for_hyperv /mnt/new

# ── Disable cloud-init network override ──────────────────────────────
disable_cloud_init_network /mnt/new

# Read KVP flags using the proper binary reader
XRDP_FLAG=$(read_kvp_value "/var/lib/hyperv/.kvp_pool_0" "VMCREATE_XRDP")
if [ "$XRDP_FLAG" = "true" ]; then
    report_progress "INSTALL_XRDP" "Installing XRDP for Enhanced Session support"
    echo "Installing xrdp for Hyper-V Enhanced Session support"
    # Non-fatal: a failed XRDP install should not invalidate a successful conversion
    if chroot /mnt/new /bin/bash -c "/opt/autorun/install_xrdp.sh"; then
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

# ── Stop Tor daemon if we started it ─────────────────────────────────
stop_tor_if_running

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
    create_automation_user /mnt/new "$SSH_PUBKEY"
else
    echo "No SSH public key in KVP — skipping automation user setup"
fi

# ── Fix ESP redirect grub.cfg ────────────────────────────────────────
# The GRUB EFI binary has its prefix embedded as /boot/grub (or /boot/grub2).
# At EFI boot, GRUB's $root defaults to the ESP, so it looks for its config
# at <ESP>/boot/grub/grub.cfg — NOT at <ESP>/EFI/BOOT/grub.cfg.
# Additionally, Ubuntu's grub-efi-amd64-signed dpkg trigger overwrites
# EFI/BOOT/grub.cfg with a broken single-quoted version.
# We write the redirect to BOTH the embedded-prefix path and the EFI dirs,
# AFTER all chroot apt-get calls, from the host side.
if [ -d /mnt/new/boot/grub2 ]; then
    _grub_dir="/boot/grub2"
else
    _grub_dir="/boot/grub"
fi
_root_uuid=$(blkid -o value -s UUID "${new_disk}2" 2>/dev/null || true)
if [ -n "$_root_uuid" ]; then
    # Discover the distro-specific EFI directory from install_grub.sh output
    # (it writes to EFI/<distro_id>/ via --bootloader-id)
    _distro_efi_dirs=""
    for _candidate in /mnt/new/boot/efi/EFI/*/; do
        _base=$(basename "$_candidate")
        # Skip known generic dirs — add the rest as distro-specific
        case "$_base" in
            BOOT|GRUB) continue ;;
            *) _distro_efi_dirs="$_distro_efi_dirs $_candidate" ;;
        esac
    done

    # The critical path: GRUB looks here based on its embedded prefix
    # Also write to EFI standard directories and distro-specific directories
    for _dir in "/mnt/new/boot/efi${_grub_dir}" /mnt/new/boot/efi/EFI/BOOT /mnt/new/boot/efi/EFI/GRUB $_distro_efi_dirs; do
        mkdir -p "$_dir"
        cat > "$_dir/grub.cfg" <<GRUBCFG
search.fs_uuid ${_root_uuid} root
set prefix=(\$root)${_grub_dir}
configfile \$prefix/grub.cfg
GRUBCFG
    done
    echo "Wrote ESP redirect grub.cfg (root UUID: $_root_uuid, grub dir: $_grub_dir)"
    echo "--- Final ESP contents ---"
    find /mnt/new/boot/efi -type f 2>&1 || true
    echo "--- Final ESP ${_grub_dir}/grub.cfg ---"
    cat "/mnt/new/boot/efi${_grub_dir}/grub.cfg"
    echo "---"
else
    echo "WARNING: Could not determine root UUID for ESP redirect grub.cfg"
fi

# Clean up autorun scripts from the target VM
rm -rf /mnt/new/opt/autorun

# Save autorun journal to the target disk so the host can collect it
# after the VM reboots from the hard drive.
journalctl --no-pager > /mnt/new/var/log/vmcreate-autorun.log 2>&1 || true
echo "Saved autorun journal to /mnt/new/var/log/vmcreate-autorun.log"

report_progress "REBOOT" "Shutting down VM to boot from converted disk"
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
