#!/bin/bash
set -eo pipefail

# Customize-only mode: mount the existing GPT disk, chroot into it,
# and apply customizations (e.g. install xrdp) without any disk cloning.
# This is used when a GPT image is already in the correct format
# but needs post-install customization via the helper ISO.

# Source utility functions
source /opt/autorun/../lib/functions.sh

# Set trap for cleanup on script exit
trap cleanup_mounts EXIT

report_progress "CUSTOMIZE_START" "Starting customize-only mode"

# In customize-only mode there is exactly one partitioned disk attached.
# The ISO boots from DVD; the target disk is the only /dev/sd* device.
target_disk=""
for disk in /dev/sd[a-z]; do
    [ -b "$disk" ] || continue
    part_count=$(lsblk -l -o NAME -n "$disk" | wc -l)
    if [ "$part_count" -gt 1 ]; then
        target_disk="$disk"
        break
    fi
done

if [ -z "$target_disk" ]; then
    report_progress "CUSTOMIZE_ERROR" "No partitioned disk found"
    echo "ERROR: Could not find a partitioned disk to customize." | tee -a /tmp/error.log
    exit 1
fi

echo "Target disk: $target_disk"

# Detect root and ESP partitions on the target disk
report_progress "DETECT" "Detecting partitions on target disk"

# Find root partition (ext4 with /etc/fstab)
root_part=""
esp_part=""
root_mount_opts=""
temp_check="/tmp/check_root"
mkdir -p "$temp_check"

for part in $(lsblk -lpno NAME,TYPE "$target_disk" | grep ' part$' | awk '{print $1}'); do
    fs_type=$(blkid -o value -s TYPE "$part" 2>/dev/null || true)

    # Check for ESP (vfat)
    if [ "$fs_type" = "vfat" ]; then
        esp_part="$part"
        echo "Detected ESP: $esp_part"
        continue
    fi

    # Check for root (ext2/3/4, btrfs, xfs — anything with fstab + bin)
    if [[ "$fs_type" =~ ^(ext[234]|btrfs|xfs)$ ]]; then
        if mount -o ro "$part" "$temp_check" 2>/dev/null; then
            if [ -f "$temp_check/etc/fstab" ] && [ -d "$temp_check/bin" ]; then
                root_part="$part"
                echo "Detected root: $root_part (fs: $fs_type)"
                umount "$temp_check"
                break
            fi
            umount "$temp_check"
        fi
        # btrfs subvolume handling: many distros (Parrot, openSUSE, Fedora)
        # put root in a subvolume like @ or @rootfs. A plain mount shows
        # the top-level tree which lacks /etc/fstab and /bin.
        if [ "$fs_type" = "btrfs" ] && [ -z "$root_part" ]; then
            for subvol in @ @rootfs; do
                if mount -o ro,subvol="$subvol" "$part" "$temp_check" 2>/dev/null; then
                    if [ -f "$temp_check/etc/fstab" ] && [ -d "$temp_check/bin" ]; then
                        root_part="$part"
                        root_mount_opts="-o subvol=$subvol"
                        echo "Detected root: $root_part (fs: $fs_type, subvol: $subvol)"
                        umount "$temp_check"
                        break
                    fi
                    umount "$temp_check"
                fi
            done
            [ -n "$root_part" ] && break
        fi
    fi
done
rmdir "$temp_check"

if [ -z "$root_part" ]; then
    report_progress "CUSTOMIZE_ERROR" "No root partition found on $target_disk"
    echo "ERROR: Could not find root partition on $target_disk." | tee -a /tmp/error.log
    exit 1
fi

# Mount root (with subvolume option if detected)
mkdir -p /mnt/new
if [ -n "$root_mount_opts" ]; then
    retry 3 1 mount $root_mount_opts "$root_part" /mnt/new
else
    retry 3 1 mount "$root_part" /mnt/new
fi

# Mount ESP if found
if [ -n "$esp_part" ]; then
    mkdir -p /mnt/new/boot/efi
    retry 3 1 mount "$esp_part" /mnt/new/boot/efi
fi

# ── Mount additional fstab entries (e.g. /home on separate partition/subvol) ──
# Some distros (Ubuntu 24.04+, openSUSE) use a separate btrfs subvolume or
# partition for /home.  If we don't mount it before chroot, any user/home dirs
# we create will land on the root subvolume and be hidden when the real /home
# is mounted at boot.
mount_fstab_extras() {
    local fstab="/mnt/new/etc/fstab"
    [ -f "$fstab" ] || return 0

    # Read fstab, skip comments/empty/swap, skip / and /boot/efi (already mounted)
    while read -r fs_spec fs_file fs_vfstype fs_mntops _; do
        [[ "$fs_spec" =~ ^#  ]] && continue
        [ -z "$fs_spec" ] && continue
        [ "$fs_vfstype" = "swap" ] && continue
        [ "$fs_file" = "/" ] && continue
        [ "$fs_file" = "/boot/efi" ] && continue
        [ "$fs_file" = "/boot" ] && continue
        # Only mount real filesystems (skip proc/sys/devpts/tmpfs etc)
        case "$fs_vfstype" in
            proc|sysfs|devpts|tmpfs|devtmpfs|cgroup*|securityfs|debugfs|efivarfs|fuse*) continue ;;
        esac

        local target="/mnt/new${fs_file}"
        mkdir -p "$target"

        # Handle btrfs subvolumes specified in fstab options
        if [ "$fs_vfstype" = "btrfs" ]; then
            local subvol_opt
            subvol_opt=$(echo "$fs_mntops" | tr ',' '\n' | grep '^subvol=' | head -1)
            if [ -n "$subvol_opt" ]; then
                echo "Mounting fstab entry: $fs_file ($fs_vfstype, $subvol_opt)"
                mount -o "$subvol_opt" "$root_part" "$target" 2>/dev/null && continue
            fi
        fi

        # Handle UUID= and LABEL= references
        local dev="$fs_spec"
        if [[ "$fs_spec" =~ ^UUID= ]]; then
            dev=$(blkid -U "${fs_spec#UUID=}" 2>/dev/null || true)
        elif [[ "$fs_spec" =~ ^LABEL= ]]; then
            dev=$(blkid -L "${fs_spec#LABEL=}" 2>/dev/null || true)
        fi

        if [ -n "$dev" ] && [ -b "$dev" ]; then
            echo "Mounting fstab entry: $fs_file ($fs_vfstype, $dev)"
            mount -t "$fs_vfstype" "$dev" "$target" 2>/dev/null || \
                echo "WARNING: Failed to mount fstab $fs_file — user home dirs may not persist" | tee -a /tmp/error.log
        fi
    done < "$fstab"
}
mount_fstab_extras

# Bind mounts for chroot
mount --bind /dev /mnt/new/dev
mount --bind /proc /mnt/new/proc
mount --bind /sys /mnt/new/sys
mount --bind /dev/pts /mnt/new/dev/pts
modprobe efivarfs
mount --bind /sys/firmware/efi/efivars /mnt/new/sys/firmware/efi/efivars || true
setup_chroot_dns /mnt/new

# Copy autorun files for chroot scripts
mkdir -p /mnt/new/opt/autorun
cp /opt/autorun/install_xrdp.sh /mnt/new/opt/autorun/ 2>/dev/null || true
cp /opt/autorun/install_pwsh.sh /mnt/new/opt/autorun/ 2>/dev/null || true

# ── Capture SSH state BEFORE any chroot apt calls ────────────────────
capture_ssh_state /mnt/new

# ── Fix conflicting apt sources ──────────────────────────────────────
fix_apt_repo_conflicts /mnt/new

# ── Hyper-V guest optimization ───────────────────────────────────────
report_progress "INSTALL_HYPERV_PACKAGES" "Installing Hyper-V guest integration services"
install_hyperv_packages /mnt/new

# ── Ensure critical services are enabled via direct symlinks ──────────
enable_services_via_symlinks /mnt/new

# Generate SSH host keys if missing
generate_ssh_host_keys /mnt/new

# ── Fix netplan: replace hardcoded interface names with match-all ─────
fix_netplan_for_hyperv /mnt/new

# ── Disable cloud-init network override ──────────────────────────────
disable_cloud_init_network /mnt/new

# Read KVP flags
XRDP_FLAG=$(read_kvp_value "/var/lib/hyperv/.kvp_pool_0" "VMCREATE_XRDP")
if [ "$XRDP_FLAG" = "true" ]; then
    report_progress "INSTALL_XRDP" "Installing XRDP for Enhanced Session support"
    echo "Installing xrdp for Hyper-V Enhanced Session support"
    XRDP_USERNAME=$(read_kvp_value "/var/lib/hyperv/.kvp_pool_0" "VMCREATE_XRDP_USERNAME")
    export XRDP_USERNAME
    # Non-fatal: a failed XRDP install should not invalidate a successful customization
    if chroot /mnt/new /bin/bash -c "XRDP_USERNAME='$XRDP_USERNAME' /opt/autorun/install_xrdp.sh"; then
        echo "XRDP installation completed successfully"
    else
        report_progress "XRDP_WARNING" "XRDP installation failed, VM will boot without XRDP"
        echo "WARNING: XRDP installation failed, continuing..." | tee -a /tmp/error.log
    fi
    rm -f /mnt/new/opt/autorun/install_xrdp.sh
fi

# ── Install pwsh for PowerShell Direct on target VM ──────────────────
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
# Retry for up to 30s — KVP may not have been flushed by hv_kvp_daemon yet.
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

# Clean up autorun scripts from the target VM
rm -rf /mnt/new/opt/autorun

# Save autorun journal to the target disk so the host can collect it
# after the VM reboots from the hard drive.
# Filter to autorun.service only — the full journal includes thousands of
# lines of kernel, systemd and sbkeysync noise that obscure the actual output.
journalctl -u autorun.service --no-pager > /mnt/new/var/log/vmcreate-autorun.log 2>&1 || true
echo "Saved autorun journal to /mnt/new/var/log/vmcreate-autorun.log"

report_progress "REBOOT" "Shutting down VM to apply changes"
echo "Customize-only mode completed"

# Read debug flag
DEBUG_FLAG=$(read_kvp_value "/var/lib/hyperv/.kvp_pool_0" "VMCREATE_DEBUG")

if [ "$DEBUG_FLAG" = "true" ]; then
    echo "Debug flag set; VM will remain running for inspection."
    echo "Login via Hyper-V console to inspect. Run 'systemctl poweroff' when done."
    exit 1
fi

echo "Customization completed successfully; systemd will handle shutdown via OnSuccess=poweroff.target."
exit 0
