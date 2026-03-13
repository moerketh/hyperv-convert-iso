#!/bin/bash
# Hyper-V Convert ISO - Common Functions Library

# Sourcing guard to prevent multiple inclusions
[[ -n "${FUNCTIONS_SH_LOADED:-}" ]] && return
FUNCTIONS_SH_LOADED=1

# Function to send KVP (write to custom pool for guest-to-host)
# Updates the value in-place if the key already exists; appends to the
# first empty slot otherwise.  The pool is a fixed-size array of 2560-byte
# records (512 key + 2048 value).  Appending duplicate keys caused the
# hv_kvp_daemon to report stale values to the host, breaking the
# PartcloneProgress completion marker detection.
send_kvp() {
    local key="$1"
    local value="$2"
    local pool="/var/lib/hyperv/.kvp_pool_1"
    local key_size=512
    local value_size=2048
    local record_size=$((key_size + value_size))  # 2560

    # Build the new record in a temp file
    local tmpfile
    tmpfile=$(mktemp) || { echo "Failed to create temp file"; exit 1; }
    printf "%s\0" "$key" > "$tmpfile"
    truncate -s "$key_size" "$tmpfile"
    printf "%s\0" "$value" >> "$tmpfile"
    truncate -s "$record_size" "$tmpfile"

    # Scan existing records for a matching key to update in-place
    local index=0
    local found=0
    if [ -f "$pool" ]; then
        local pool_size
        pool_size=$(stat -c%s "$pool" 2>/dev/null || echo 0)
        while [ $((index * record_size)) -lt "$pool_size" ]; do
            local offset=$((index * record_size))
            local existing_key
            existing_key=$(dd status=none if="$pool" bs=1 skip="$offset" count="$key_size" 2>/dev/null | tr -d '\0')

            if [ -z "$existing_key" ]; then
                # Empty slot — write here
                dd status=none if="$tmpfile" of="$pool" bs=1 seek="$offset" count="$record_size" conv=notrunc 2>/dev/null
                found=1
                break
            fi

            if [ "$existing_key" = "$key" ]; then
                # Matching key — overwrite the record in-place
                dd status=none if="$tmpfile" of="$pool" bs=1 seek="$offset" count="$record_size" conv=notrunc 2>/dev/null
                found=1
                break
            fi

            index=$((index + 1))
        done
    fi

    # If no existing slot found, append (new pool or all slots occupied by other keys)
    if [ "$found" -eq 0 ]; then
        cat "$tmpfile" >> "$pool" || { echo "Failed to write to $pool"; rm "$tmpfile"; exit 1; }
    fi

    rm "$tmpfile"
}

# Logging function with severity levels
log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case "$level" in
        INFO|WARN|ERROR)
            echo "[$timestamp] [$level] $message" | tee -a /var/log/hyperv-convert.log
            ;;
        *)
            echo "[$timestamp] [INFO] $message" | tee -a /var/log/hyperv-convert.log
            ;;
    esac
}

# Progress reporting function that logs to console and sends to KVP
report_progress() {
    local step="$1"
    local progress="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    if [ -n "$progress" ]; then
        local message="Workflow step: $step - $progress"
        log "INFO" "$message"
        send_kvp "WorkflowProgress" "$step: $progress"
    else
        local message="Workflow step: $step"
        log "INFO" "$message"
        send_kvp "WorkflowProgress" "$step"
    fi
}
# Retry function for transient failures
# Usage: retry max_attempts delay command args...
retry() {
    local max_attempts=$1
    local delay=$2
    shift 2
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if "$@"; then
            return 0
        fi
        log "WARN" "[RETRY] Attempt $attempt/$max_attempts failed: $*"
        ((attempt++))
        sleep $delay
    done
    
    log "ERROR" "[RETRY] All $max_attempts attempts failed: $*"
    return 1
}

# Pre-flight checks function
preflight_checks() {
    local errors=0
    local warnings=0
    
    echo "Running pre-flight checks..."
    
    # Check 1: New disk size >= old disk used space
    echo "Checking disk sizes..."
    if [ -z "$new_disk" ] || [ -z "$old_disk" ]; then
        echo "ERROR: new_disk or old_disk variables not set"
        ((errors++))
    else
        # Get disk sizes
        new_size_bytes=$(blockdev --getsize64 "$new_disk" 2>/dev/null) || {
            echo "ERROR: Failed to get size of new disk $new_disk"
            ((errors++))
        }
        
        # Get used space from old disk (sum of all partition sizes as approximation)
        old_used_bytes=0
        for part in $(lsblk -lpno NAME,TYPE "$old_disk" | grep ' part$' | awk '{print $1}'); do
            part_size=$(blockdev --getsize64 "$part" 2>/dev/null) || continue
            old_used_bytes=$((old_used_bytes + part_size))
        done
        
        if [ $old_used_bytes -eq 0 ]; then
            echo "ERROR: Failed to calculate used space on old disk $old_disk"
            ((errors++))
        else
            echo "New disk size: $((new_size_bytes / 1024 / 1024)) MB"
            echo "Old disk used space: $((old_used_bytes / 1024 / 1024)) MB"
            
            if [ "$new_size_bytes" -lt "$old_used_bytes" ]; then
                echo "ERROR: New disk ($new_disk) is smaller than old disk used space"
                send_kvp "PreflightError" "New disk too small: ${new_size_bytes} < ${old_used_bytes} bytes" 2>/dev/null || true
                ((errors++))
            else
                echo "Disk size check PASSED"
            fi
        fi
    fi
    
    # Check 2: Required tools are available
    echo "Checking required tools..."
    local required_tools=(
        "partclone.ext4"
        "partclone.vfat" 
        "sgdisk"
        "mkfs.vfat"
        "mkfs.ext4"
        "mount"
        "umount"
        "rsync"
        "chroot"
        "blockdev"
        "lsblk"
        "blkid"
        "partprobe"
    )
    
    local missing_tools=()
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
            ((errors++))
        fi
    done
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        echo "ERROR: Missing required tools: ${missing_tools[*]}"
        send_kvp "PreflightError" "Missing tools: ${missing_tools[*]}" 2>/dev/null || true
    else
        echo "Required tools check PASSED"
    fi
    
    # Check 3: Hyper-V KVP daemon is accessible (with fallback)
    echo "Checking KVP accessibility..."
    local kvp_dir="/var/lib/hyperv"
    local pool0_file="${kvp_dir}/.kvp_pool_0"
    local pool1_file="${kvp_dir}/.kvp_pool_1"
    
    if [ ! -d "$kvp_dir" ]; then
        echo "WARNING: KVP directory $kvp_dir does not exist"
        send_kvp "PreflightWarning" "KVP directory missing" 2>/dev/null || true
        ((warnings++))
    elif [ ! -f "$pool0_file" ]; then
        echo "WARNING: KVP pool 0 file not accessible"
        send_kvp "PreflightWarning" "KVP pool 0 missing" 2>/dev/null || true
        ((warnings++))
    elif [ ! -f "$pool1_file" ]; then
        echo "WARNING: KVP pool 1 file not accessible"
        send_kvp "PreflightWarning" "KVP pool 1 missing" 2>/dev/null || true
        ((warnings++))
    else
        # Test KVP functionality
        if ! send_kvp "PreflightTest" "KVP accessible" 2>/dev/null; then
            echo "WARNING: KVP write test failed"
            ((warnings++))
        else
            echo "KVP accessibility check PASSED"
        fi
    fi
    
    # Summary
    echo "Pre-flight checks completed:"
    echo "  Errors: $errors"
    echo "  Warnings: $warnings"
    
    if [ $errors -gt 0 ]; then
        echo "ERROR: Pre-flight checks failed with $errors error(s). Aborting."
        exit 1
    elif [ $warnings -gt 0 ]; then
        echo "WARNING: Pre-flight checks completed with $warnings warning(s). Proceeding with caution."
    else
        echo "SUCCESS: All pre-flight checks passed."
    fi
}

# Cleanup function to unmount bind mounts in reverse order
cleanup_mounts() {
    # Unmount all bind mounts in REVERSE order with checks
    if mount | grep -q "/mnt/new/etc/resolv.conf"; then
        umount -lf /mnt/new/etc/resolv.conf 2>/dev/null || true
    fi
    if mount | grep -q "/mnt/new/sys/firmware/efi/efivars"; then
        umount -lf /mnt/new/sys/firmware/efi/efivars 2>/dev/null || true
    fi
    if mount | grep -q "/mnt/new/dev/pts"; then
        umount -lf /mnt/new/dev/pts 2>/dev/null || true
    fi
    if mount | grep -q "/mnt/new/sys"; then
        umount -lf /mnt/new/sys 2>/dev/null || true
    fi
    if mount | grep -q "/mnt/new/proc"; then
        umount -lf /mnt/new/proc 2>/dev/null || true
    fi
    if mount | grep -q "/mnt/new/dev"; then
        umount -lf /mnt/new/dev 2>/dev/null || true
    fi
    # Unmount any fstab-based mounts (e.g. /home) before boot/efi and root
    for mp in $(mount | grep '/mnt/new/' | grep -v '/mnt/new/\(dev\|proc\|sys\|boot/efi\|etc/resolv\)' | awk '{print $3}' | sort -r); do
        umount -lf "$mp" 2>/dev/null || true
    done
    if mount | grep -q "/mnt/new/boot/efi"; then
        umount -lf /mnt/new/boot/efi 2>/dev/null || true
    fi
    if mount | grep -q "/mnt/new"; then
        umount -lf /mnt/new 2>/dev/null || true
    fi
    # Create flag file for getty override
    touch /run/autorun-done
}

# Function to read KVP values from pool (extracted from inline code)
read_kvp() {
    local pool_file="${1:-/var/lib/hyperv/.kvp_pool_0}"
    local key_size=512
    local value_size=2048
    local kvp_index=0

    while true; do
        kvp_start_byte=$((kvp_index * (key_size + value_size)))
        kvp_key_offset=$kvp_start_byte
        kvp_value_offset=$((kvp_start_byte + key_size))

        kvp_key=$(dd status=none if="$pool_file" bs=1 skip="$kvp_key_offset" count="$key_size" 2>/dev/null | tr -d '\0')
        kvp_value=$(dd status=none if="$pool_file" bs=1 skip="$kvp_value_offset" count="$value_size" 2>/dev/null | tr -d '\0')

        if [ -z "$kvp_key" ]; then
            break
        fi

        echo "Key: $kvp_key Value: $kvp_value"
        kvp_index=$((kvp_index + 1))
    done
}

# Function to read a specific KVP value by key name
# Usage: value=$(read_kvp_value "/var/lib/hyperv/.kvp_pool_0" "VMCREATE_XRDP")
read_kvp_value() {
    local pool_file="${1:-/var/lib/hyperv/.kvp_pool_0}"
    local target_key="$2"
    local key_size=512
    local value_size=2048
    local kvp_index=0

    if [ ! -f "$pool_file" ]; then
        return
    fi

    while true; do
        local kvp_start_byte=$((kvp_index * (key_size + value_size)))
        local kvp_key_offset=$kvp_start_byte
        local kvp_value_offset=$((kvp_start_byte + key_size))

        local kvp_key
        kvp_key=$(dd status=none if="$pool_file" bs=1 skip="$kvp_key_offset" count="$key_size" 2>/dev/null | tr -d '\0')

        if [ -z "$kvp_key" ]; then
            break
        fi

        if [ "$kvp_key" = "$target_key" ]; then
            dd status=none if="$pool_file" bs=1 skip="$kvp_value_offset" count="$value_size" 2>/dev/null | tr -d '\0'
            return
        fi

        kvp_index=$((kvp_index + 1))
    done
}

# Function to detect new (empty) and old (has partitions) disks
# Sets global variables: new_disk, old_disk, new_size, old_size
detect_disks() {
    local disks part_count temp
    
    disks=(/dev/sd[a-z])
    new_disk=""
    old_disk=""
    
    for disk in "${disks[@]}"; do
        part_count=$(lsblk -l -o NAME -n "$disk" | wc -l)
        if [ "$part_count" -eq 1 ]; then
            new_disk=$disk
        else
            old_disk=$disk
        fi
    done

    if [ -z "$new_disk" ] || [ -z "$old_disk" ]; then
        echo "Could not detect new (empty) or old disk. Aborting." | tee -a /tmp/error.log
        exit 1
    fi

    # Fallback to size if detection ambiguous
    new_size=$(blockdev --getsz "$new_disk")
    old_size=$(blockdev --getsz "$old_disk")
    if (( new_size < old_size )); then
        # Swap if sizes don't match expected
        temp=$new_disk
        new_disk=$old_disk
        old_disk=$temp
        # Also swap the sizes
        temp=$new_size
        new_size=$old_size
        old_size=$temp
    fi

    export new_disk old_disk new_size old_size
    
    echo "New disk: $new_disk (size $new_size sectors), Old disk: $old_disk (size $old_size sectors)" | tee -a /tmp/detection.log
}

# Function to detect partitions on old disk
# Returns global variables: root_part, esp_part, boot_part, old_esp_uuid, old_boot_uuid, old_esp_label, old_boot_label, boot_device
detect_partitions() {
    local old_disk="$1"
    local partitions temp_check part fs_type esp_device boot_device
    local uuid label part_num
    
    partitions=$(lsblk -lpno NAME,TYPE "$old_disk" | grep ' part$' | awk '{print $1}')
    
    temp_check="/tmp/check_root"
    mkdir -p "$temp_check"
    
    # Initialize global variables
    root_part=""
    esp_part=""
    boot_part=""
    old_esp_uuid=""
    old_boot_uuid=""
    old_esp_label=""
    old_boot_label=""
    boot_device=""
    local root_found=false
    
    for part in $partitions; do
        fs_type=$(blkid -o value -s TYPE "$part")

        if [[ ! "$fs_type" =~ ^(ext[234]|btrfs|xfs)$ ]]; then
            continue
        fi

        # Temporarily mount to check if it's root
        if mount -o ro "$part" "$temp_check" 2>/dev/null; then
            if [ -f "$temp_check/etc/fstab" ] && [ -d "$temp_check/bin" ]; then
                root_found=true
                root_part="$part"
                echo "Detected root partition: $root_part (fs: $fs_type)"

                # Parse fstab for /boot and /boot/efi
                esp_device=$(awk '$2 == "/boot/efi" {print $1}' "$temp_check/etc/fstab")
                if [ ! -z "$esp_device" ]; then
                    echo "Detected ESP mount in fstab: $esp_device"
                fi

                boot_device=$(awk '$2 == "/boot" {print $1}' "$temp_check/etc/fstab")
                if [ ! -z "$boot_device" ]; then
                    echo "Detected separate /boot mount in fstab: $boot_device"
                fi

                umount "$temp_check"
                break  # Assume only one root
            fi
            umount "$temp_check"
        fi

        # btrfs subvolume handling: many distros (Parrot, openSUSE, Fedora)
        # put root in a subvolume like @ or @rootfs. A plain mount shows
        # the top-level tree which lacks /etc/fstab and /bin.
        if [ "$fs_type" = "btrfs" ] && ! $root_found; then
            for subvol in @ @rootfs; do
                if mount -o ro,subvol="$subvol" "$part" "$temp_check" 2>/dev/null; then
                    if [ -f "$temp_check/etc/fstab" ] && [ -d "$temp_check/bin" ]; then
                        root_found=true
                        root_part="$part"
                        echo "Detected root partition: $root_part (fs: $fs_type, subvol: $subvol)"

                        esp_device=$(awk '$2 == "/boot/efi" {print $1}' "$temp_check/etc/fstab")
                        if [ ! -z "$esp_device" ]; then
                            echo "Detected ESP mount in fstab: $esp_device"
                        fi

                        boot_device=$(awk '$2 == "/boot" {print $1}' "$temp_check/etc/fstab")
                        if [ ! -z "$boot_device" ]; then
                            echo "Detected separate /boot mount in fstab: $boot_device"
                        fi

                        umount "$temp_check"
                        break
                    fi
                    umount "$temp_check"
                fi
            done
            $root_found && break
        fi
    done

    rmdir "$temp_check"

    if ! $root_found; then
        echo "Error: No valid root partition found on $old_disk."
        exit 1
    fi

    # Resolve esp_part if esp_device present
    if [ ! -z "$esp_device" ]; then
        if [[ "$esp_device" == UUID=* ]]; then
            uuid="${esp_device#UUID=}"
            esp_part=$(blkid -U "$uuid")
            old_esp_uuid="$uuid"
        elif [[ "$esp_device" == LABEL=* ]]; then
            label="${esp_device#LABEL=}"
            esp_part=$(blkid -L "$label")
            old_esp_label="$label"
        elif [[ "$esp_device" == /dev/* ]]; then
            # Remap device to current old_disk if necessary
            if [[ "$esp_device" == ${old_disk}* ]]; then
                esp_part="$esp_device"
            else
                # Original device uses different letter; remap to old_disk
                part_num=$(echo "$esp_device" | sed 's/^\/dev\/sd[a-z]\([0-9]*\)$/\1/')
                esp_part="${old_disk}${part_num}"
                echo "Remapped ESP device from $esp_device to $esp_part"
            fi
            old_esp_uuid=$(blkid -s UUID -o value "$esp_part")
        fi
        if [ -z "$esp_part" ]; then
            echo "Warning: Could not resolve ESP partition from $esp_device. Skipping clone."
        else
            fs_type=$(blkid -o value -s TYPE "$esp_part")
            if [ "$fs_type" != "vfat" ]; then
                echo "Warning: ESP partition $esp_part is not vfat. Skipping clone."
                esp_part=""
            fi
        fi
    fi

    # Resolve boot_part if boot_device present
    if [ ! -z "$boot_device" ]; then
        if [[ "$boot_device" == UUID=* ]]; then
            uuid="${boot_device#UUID=}"
            boot_part=$(blkid -U "$uuid")
            old_boot_uuid="$uuid"
        elif [[ "$boot_device" == LABEL=* ]]; then
            label="${boot_device#LABEL=}"
            boot_part=$(blkid -L "$label")
            old_boot_label="$label"
        elif [[ "$boot_device" == /dev/* ]]; then
            # Remap device to current old_disk if necessary
            if [[ "$boot_device" == ${old_disk}* ]]; then
                boot_part="$boot_device"
            else
                # Original device uses different letter; remap to old_disk
                part_num=$(echo "$boot_device" | sed 's/^\/dev\/sd[a-z]\([0-9]*\)$/\1/')
                boot_part="${old_disk}${part_num}"
                echo "Remapped boot device from $boot_device to $boot_part"
            fi
            old_boot_uuid=$(blkid -s UUID -o value "$boot_part")
        fi
        if [ -z "$boot_part" ]; then
            echo "Warning: Could not resolve /boot partition from $boot_device. Skipping merge."
        else
            fs_type=$(blkid -o value -s TYPE "$boot_part")
            if [[ ! "$fs_type" =~ ^ext[234]$ ]]; then
                echo "Warning: /boot partition $boot_part is not ext*. Skipping merge."
                boot_part=""
            fi
        fi
    fi
    
    # Export global variables for calling script
    export root_part esp_part boot_part old_esp_uuid old_boot_uuid old_esp_label old_boot_label boot_device
}

# Verify cloned partitions are clean
# Args: root_partition esp_partition
verify_clone() {
    local root_part=$1
    local esp_part=$2
    local errors=0
    
    log "INFO" "Verifying cloned filesystems..."
    
    # Check root partition (ext4)
    if command -v e2fsck >/dev/null; then
        if e2fsck -n "$root_part" >/dev/null 2>&1; then
            log "INFO" "Root partition $root_part verification PASSED"
        else
            log "ERROR" "Root partition $root_part verification FAILED"
            ((errors++))
        fi
    else
        log "WARN" "e2fsck not available, skipping root verification"
    fi
    
    # Check ESP (vfat)
    if command -v fsck.vfat >/dev/null; then
        if fsck.vfat -n "$esp_part" >/dev/null 2>&1; then
            log "INFO" "ESP partition $esp_part verification PASSED"
        else
            log "ERROR" "ESP partition $esp_part verification FAILED"
            ((errors++))
        fi
    else
        log "WARN" "fsck.vfat not available, skipping ESP verification"
    fi
    
    return $errors
}

# Function to update fstab with new UUIDs
update_fstab() {
    local fstab_path="$1"
    local root_part="$2" new_esp_part="$3" new_root_part="$4"
    local old_root_uuid new_esp_uuid new_root_uuid old_esp_uuid boot_device_esc
    
    echo "Updating fstab at $fstab_path"

    old_root_uuid=$(blkid -s UUID -o value $root_part)
    new_esp_uuid=$(blkid -s UUID -o value $new_esp_part)
    new_root_uuid=$(blkid -s UUID -o value $new_root_part)

    if [ -f "$fstab_path" ]; then
        sed -i "s/$old_root_uuid/$new_root_uuid/g" "$fstab_path"
        if [ ! -z "$esp_part" ]; then
            if [ -z "$old_esp_uuid" ]; then old_esp_uuid=$(blkid -s UUID -o value $esp_part); fi
            sed -i "s/$old_esp_uuid/$new_esp_uuid/g" "$fstab_path"
        else
            if ! grep -q '/boot/efi' "$fstab_path"; then
                echo "Adding new /boot/efi entry to fstab."
                echo "UUID=$new_esp_uuid /boot/efi vfat defaults 0 2" >> "$fstab_path"
            else
                echo "/boot/efi already in fstab; no addition needed."
            fi
        fi

        # Comment out swap entries — the new GPT disk has no swap partition,
        # so stale swap UUIDs would cause a ~90s boot delay.
        if grep -qE '^[^#].*\bswap\b' "$fstab_path"; then
            echo "Commenting out swap entries in fstab (no swap on new disk)."
            sed -i '/\bswap\b/s/^/#/' "$fstab_path"
        fi

        if [ -n "$boot_part" ]; then
            echo "Removing separate /boot entry from fstab."
            if [ -n "$old_boot_uuid" ]; then
              sed -i "/UUID=$old_boot_uuid/d" "$fstab_path"
            elif [ -n "$old_boot_label" ]; then
              sed -i "/LABEL=$old_boot_label/d" "$fstab_path"
            elif [[ "$boot_device" == /dev/* ]]; then
              boot_device_esc=$(echo "$boot_device" | sed 's/\//\\\//g')
              sed -i "/^${boot_device_esc}[ \t]/d" "$fstab_path"
            fi
        fi
    else
        echo "fstab not found after cloning, creating a new one with root and ESP entries."
        mkdir -p "$(dirname "$fstab_path")"
        cat << EOF > "$fstab_path"
UUID=$new_root_uuid / ext4 defaults 0 1
UUID=$new_esp_uuid /boot/efi vfat defaults 0 2
EOF
    fi
}

# ── DNS resolution for chroot ────────────────────────────────────────
# Many distros (Arch, Fedora, NixOS) use a symlink for /etc/resolv.conf
# that points into /run/systemd/resolve/ which doesn't exist inside
# the ISO.  A bind-mount over a dangling symlink fails silently,
# leaving the chroot without DNS.  This function removes the symlink
# (if any), then writes the live ISO's resolv.conf into the target.
setup_chroot_dns() {
    local target="$1/etc/resolv.conf"
    # Remove dangling symlink so we can write a real file
    if [ -L "$target" ]; then
        rm -f "$target"
        echo "Removed dangling resolv.conf symlink in chroot"
    fi
    # Copy the running ISO's resolv.conf (which has working DNS)
    if [ -f /etc/resolv.conf ] && [ -s /etc/resolv.conf ]; then
        cp -L /etc/resolv.conf "$target"
    else
        # Fallback: write a basic DNS config
        printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$target"
    fi
    echo "Configured DNS in chroot: $(cat "$target")"
}

# ── Create the vmcreate automation user (distro-agnostic) ────────────
# Works on Debian/Ubuntu (adduser), Arch (useradd), Fedora/RHEL (useradd)
# and detects the correct admin group (sudo vs wheel).
create_automation_user() {
    local root="$1"       # chroot root, e.g. /mnt/new
    local ssh_pubkey="$2"  # SSH public key string

    chroot "$root" /bin/bash -c '
        # Ensure sudo is available (Arch minimal may not ship it)
        if ! command -v sudo >/dev/null 2>&1; then
            if command -v pacman >/dev/null 2>&1; then
                pacman -S --noconfirm sudo 2>&1 || true
            fi
        fi

        # Create vmcreate user if it does not exist
        if ! id vmcreate >/dev/null 2>&1; then
            if command -v adduser >/dev/null 2>&1 && adduser --help 2>&1 | grep -q "\-\-gecos"; then
                # Debian/Ubuntu style
                adduser --disabled-password --gecos "VMCreate Automation" vmcreate
            else
                # Arch/Fedora/RHEL style
                useradd -m -c "VMCreate Automation" -s /bin/bash vmcreate
            fi
        fi

        # Detect admin group: Debian=sudo, Arch/Fedora=wheel
        if getent group sudo >/dev/null 2>&1; then
            usermod -aG sudo vmcreate
        elif getent group wheel >/dev/null 2>&1; then
            usermod -aG wheel vmcreate
        fi

        mkdir -p /etc/sudoers.d
        echo "vmcreate ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/vmcreate
        chmod 0440 /etc/sudoers.d/vmcreate

        # Install SSH public key
        mkdir -p /home/vmcreate/.ssh
        echo "'"$ssh_pubkey"'" > /home/vmcreate/.ssh/authorized_keys
        chown -R vmcreate:vmcreate /home/vmcreate/.ssh
        chmod 700 /home/vmcreate/.ssh
        chmod 600 /home/vmcreate/.ssh/authorized_keys

        # Ensure pubkey auth is enabled
        sed -i "s/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/" /etc/ssh/sshd_config
    ' || echo "WARNING: Automation user setup failed (non-fatal)" | tee -a /tmp/error.log
}

# ── Hyper-V integration shared helpers ───────────────────────────────
# These functions are called by both autorun.sh and customize_only.sh
# to avoid duplicating integration logic in two places.

# Capture SSH state before any chroot apt calls that might enable SSH.
# Creates a marker file that the post-boot DisableSshStep reads.
# Usage: capture_ssh_state /mnt/new
capture_ssh_state() {
    local root="$1"
    local _wants="$root/etc/systemd/system/multi-user.target.wants"
    mkdir -p "$_wants"
    local _ssh_already_enabled=false
    for _svc in ssh sshd; do
        if [ -L "$_wants/${_svc}.service" ]; then
            _ssh_already_enabled=true
            break
        fi
    done
    if [ "$_ssh_already_enabled" = "false" ]; then
        mkdir -p "$root/var/lib/vmcreate"
        touch "$root/var/lib/vmcreate/.ssh_was_disabled"
        echo "SSH was not enabled — marked for post-boot restore"
    fi
}

# Remove conflicting apt sources that prevent apt-get update from working.
# E.g. REMnux ships both .list and .sources for Microsoft repos with
# different Signed-By values.
# Usage: fix_apt_repo_conflicts /mnt/new
fix_apt_repo_conflicts() {
    local root="$1"
    if [ -f "$root/etc/apt/sources.list.d/microsoft-prod.list" ] && \
       [ -f "$root/etc/apt/sources.list.d/microsoft.sources" ]; then
        rm -f "$root/etc/apt/sources.list.d/microsoft-prod.list"
        echo "Removed duplicate Microsoft repo file to fix apt conflict"
    fi
}

# Install Hyper-V guest integration packages.
# Package names differ across distros: Ubuntu uses linux-cloud-tools-*,
# Fedora/RHEL uses hyperv-daemons, Arch uses hyperv.
# Usage: install_hyperv_packages /mnt/new
install_hyperv_packages() {
    local root="$1"
    local _kver
    _kver=$(ls "$root/lib/modules/" 2>/dev/null | sort -V | tail -1)

    report_progress "HYPERV_OPTIMIZE" "Installing Hyper-V guest integration services"
    echo "Installing Hyper-V guest optimizations..."

    if chroot "$root" /bin/bash -c "
        export DEBIAN_FRONTEND=noninteractive
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y -qq
            KVER=\"${_kver}\"
            apt-get install -y -qq linux-cloud-tools-common openssh-server 2>&1
            if [ -n \"\$KVER\" ]; then
                apt-get install -y -qq \"linux-cloud-tools-\${KVER}\" 2>&1 || true
            fi
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y -q hyperv-daemons openssh-server 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y -q hyperv-daemons openssh-server 2>&1
        elif command -v pacman >/dev/null 2>&1; then
            pacman-key --init 2>&1 && pacman-key --populate archlinux 2>&1 || true
            pacman -Sy --noconfirm hyperv openssh sudo 2>&1
        else
            echo 'Unknown package manager — skipping Hyper-V optimization'
            exit 1
        fi
        # Try enabling services in chroot (unreliable but harmless)
        for svc in hv-kvp-daemon hv_kvp_daemon hv-vss-daemon hv_vss_daemon hv-fcopy-daemon hv_fcopy_daemon; do
            systemctl enable \"\${svc}.service\" 2>/dev/null || true
        done
        systemctl enable ssh.service 2>/dev/null || systemctl enable sshd.service 2>/dev/null || true
    "; then
        echo "Hyper-V guest optimization completed successfully"
    else
        report_progress "HYPERV_OPTIMIZE_WARNING" "Hyper-V optimization partially failed (non-fatal)"
        echo "WARNING: Some Hyper-V optimizations could not be installed (non-fatal)" | tee -a /tmp/error.log
    fi
}

# Enable critical services via direct symlinks from the host side.
# systemctl enable is unreliable in chroot (policy-rc.d, presets, missing D-Bus).
# Both hyphenated (Ubuntu) and underscored (Fedora/Arch) service names are tried.
# Usage: enable_services_via_symlinks /mnt/new
enable_services_via_symlinks() {
    local root="$1"
    local _wants="$root/etc/systemd/system/multi-user.target.wants"
    mkdir -p "$_wants"
    for _svc in ssh sshd hv-kvp-daemon hv_kvp_daemon hv-vss-daemon hv_vss_daemon hv-fcopy-daemon hv_fcopy_daemon; do
        for _prefix in /usr/lib/systemd/system /lib/systemd/system; do
            if [ -f "$root${_prefix}/${_svc}.service" ]; then
                ln -sf "${_prefix}/${_svc}.service" "$_wants/${_svc}.service"
                echo "Enabled ${_svc}.service via direct symlink"
                break
            fi
        done
        # Unmask if the distro ships it masked (symlink to /dev/null)
        local _mask="$root/etc/systemd/system/${_svc}.service"
        if [ -L "$_mask" ] && [ "$(readlink "$_mask")" = "/dev/null" ]; then
            rm -f "$_mask"
            echo "Unmasked ${_svc}.service"
        fi
    done
}

# Generate SSH host keys if none exist (distros with SSH disabled often
# ship without them, causing connection failures).
# Usage: generate_ssh_host_keys /mnt/new
generate_ssh_host_keys() {
    local root="$1"
    if ! ls "$root/etc/ssh/ssh_host_"*"_key" >/dev/null 2>&1; then
        echo "No SSH host keys found — generating"
        chroot "$root" ssh-keygen -A
    fi
}

# Replace hardcoded interface names in netplan configs with a Hyper-V
# match-all pattern so DHCP works regardless of hypervisor.
# VirtualBox uses ens33/enp0s3, Hyper-V uses eth0.
# Usage: fix_netplan_for_hyperv /mnt/new
fix_netplan_for_hyperv() {
    local root="$1"
    if ls "$root/etc/netplan/"*.yaml >/dev/null 2>&1; then
        for _np in "$root/etc/netplan/"*.yaml; do
            if grep -qE '^\s+(ens[0-9]|enp[0-9]|enx[0-9a-f]|eth[0-9])[a-z0-9]*:' "$_np"; then
                local _renderer=""
                if grep -q 'renderer:' "$_np"; then
                    _renderer=$(grep 'renderer:' "$_np" | head -1 | sed 's/.*renderer:\s*//')
                fi
                echo "Replacing hardcoded interface in $_np with match-all DHCP config"
                cat > "$_np" <<'NETPLAN'
network:
  version: 2
  ethernets:
    all-en:
      match:
        driver: hv_netvsc
      dhcp4: true
      dhcp6: true
NETPLAN
                if [ -n "$_renderer" ]; then
                    sed -i "s/^  ethernets:/  renderer: $_renderer\n  ethernets:/" "$_np"
                fi
            fi
        done
    fi
}

# Disable cloud-init network config override if cloud-init is installed.
# Without this, cloud-init may regenerate the old netplan on first boot,
# undoing the fix_netplan_for_hyperv changes.
# Usage: disable_cloud_init_network /mnt/new
disable_cloud_init_network() {
    local root="$1"
    if [ -d "$root/etc/cloud" ]; then
        mkdir -p "$root/etc/cloud/cloud.cfg.d"
        echo "network: {config: disabled}" > "$root/etc/cloud/cloud.cfg.d/99-disable-network.cfg"
        echo "Disabled cloud-init network config override"
    fi
}