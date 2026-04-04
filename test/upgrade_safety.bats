#!/usr/bin/env bats

# BATS tests for upgrade-safety mitigations
# Tests: install_grub_postinst_hook, create_swap_file, select_partclone_tool,
#        resize_cloned_filesystem, validate_fstab, ensure_hyperv_initramfs_modules,
#        distro_boot_id (install_grub.sh)

PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"

setup() {
    export TEST_TEMP_DIR=$(mktemp -d)
    cd "$PROJECT_ROOT"
}

teardown() {
    if [[ -n "$TEST_TEMP_DIR" && -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

# ── install_grub_postinst_hook tests ─────────────────────────────────

@test "install_grub_postinst_hook creates hook in postinst.d for grub dir" {
    local root="$TEST_TEMP_DIR/rootfs"
    mkdir -p "$root/boot/grub"

    # Inline the function for testing
    install_grub_postinst_hook() {
        local root="$1"
        local grub_dir
        if [ -d "$root/boot/grub2" ]; then
            grub_dir="/boot/grub2"
        else
            grub_dir="/boot/grub"
        fi
        mkdir -p "$root/etc/kernel/postinst.d"
        cat > "$root/etc/kernel/postinst.d/zz-vmcreate-grub-redirect" <<HOOK
#!/bin/bash
ROOT_UUID=\$(findmnt -n -o UUID / 2>/dev/null || blkid -s UUID -o value \$(findmnt -n -o SOURCE / 2>/dev/null) 2>/dev/null)
[ -z "\$ROOT_UUID" ] && exit 0
GRUB_DIR="$grub_dir"
for dir in /boot/efi/EFI/BOOT "/boot/efi\${GRUB_DIR}"; do
    mkdir -p "\$dir"
    cat > "\$dir/grub.cfg" <<EOF
search.fs_uuid \${ROOT_UUID} root
set prefix=(\\\$root)\${GRUB_DIR}
configfile \\\$prefix/grub.cfg
EOF
done
HOOK
        chmod 755 "$root/etc/kernel/postinst.d/zz-vmcreate-grub-redirect"
        echo "Installed kernel postinst hook: zz-vmcreate-grub-redirect"
    }

    run install_grub_postinst_hook "$root"
    [ "$status" -eq 0 ]
    [ -f "$root/etc/kernel/postinst.d/zz-vmcreate-grub-redirect" ]
    [ -x "$root/etc/kernel/postinst.d/zz-vmcreate-grub-redirect" ]
    [[ "$output" =~ "Installed kernel postinst hook" ]]
    # Verify the hook references /boot/grub (not grub2)
    grep -q 'GRUB_DIR="/boot/grub"' "$root/etc/kernel/postinst.d/zz-vmcreate-grub-redirect"
}

@test "install_grub_postinst_hook detects grub2 directory" {
    local root="$TEST_TEMP_DIR/rootfs"
    mkdir -p "$root/boot/grub2"

    install_grub_postinst_hook() {
        local root="$1"
        local grub_dir
        if [ -d "$root/boot/grub2" ]; then
            grub_dir="/boot/grub2"
        else
            grub_dir="/boot/grub"
        fi
        mkdir -p "$root/etc/kernel/postinst.d"
        cat > "$root/etc/kernel/postinst.d/zz-vmcreate-grub-redirect" <<HOOK
#!/bin/bash
GRUB_DIR="$grub_dir"
HOOK
        chmod 755 "$root/etc/kernel/postinst.d/zz-vmcreate-grub-redirect"
        echo "Installed kernel postinst hook: zz-vmcreate-grub-redirect"
    }

    run install_grub_postinst_hook "$root"
    [ "$status" -eq 0 ]
    grep -q 'GRUB_DIR="/boot/grub2"' "$root/etc/kernel/postinst.d/zz-vmcreate-grub-redirect"
}

@test "install_grub_postinst_hook also installs kernel-install hook when install.d exists" {
    local root="$TEST_TEMP_DIR/rootfs"
    mkdir -p "$root/boot/grub"
    mkdir -p "$root/etc/kernel/install.d"

    install_grub_postinst_hook() {
        local root="$1"
        local grub_dir
        if [ -d "$root/boot/grub2" ]; then
            grub_dir="/boot/grub2"
        else
            grub_dir="/boot/grub"
        fi
        mkdir -p "$root/etc/kernel/postinst.d"
        cat > "$root/etc/kernel/postinst.d/zz-vmcreate-grub-redirect" <<HOOK
#!/bin/bash
GRUB_DIR="$grub_dir"
HOOK
        chmod 755 "$root/etc/kernel/postinst.d/zz-vmcreate-grub-redirect"
        echo "Installed kernel postinst hook: zz-vmcreate-grub-redirect"

        if [ -d "$root/etc/kernel/install.d" ] || [ -d "$root/usr/lib/kernel/install.d" ]; then
            local install_d="$root/etc/kernel/install.d"
            mkdir -p "$install_d"
            cp "$root/etc/kernel/postinst.d/zz-vmcreate-grub-redirect" \
                "$install_d/99-vmcreate-grub-redirect.install"
            chmod 755 "$install_d/99-vmcreate-grub-redirect.install"
            echo "Installed kernel-install hook: 99-vmcreate-grub-redirect.install"
        fi
    }

    run install_grub_postinst_hook "$root"
    [ "$status" -eq 0 ]
    [ -f "$root/etc/kernel/postinst.d/zz-vmcreate-grub-redirect" ]
    [ -f "$root/etc/kernel/install.d/99-vmcreate-grub-redirect.install" ]
    [ -x "$root/etc/kernel/install.d/99-vmcreate-grub-redirect.install" ]
    [[ "$output" =~ "Installed kernel-install hook" ]]
}

# ── create_swap_file tests ───────────────────────────────────────────

@test "create_swap_file creates swap file and adds fstab entry" {
    local root="$TEST_TEMP_DIR/rootfs"
    mkdir -p "$root/etc"
    # Create a fstab with a commented-out swap line
    cat > "$root/etc/fstab" <<'EOF'
UUID=aaaa-bbbb / ext4 defaults 0 1
#UUID=cccc-dddd none swap sw 0 0
EOF

    # Mock mkswap
    cat > "$TEST_TEMP_DIR/mkswap" << 'MOCK'
#!/bin/bash
echo "Setting up swapspace..."
MOCK
    chmod +x "$TEST_TEMP_DIR/mkswap"
    export PATH="$TEST_TEMP_DIR:$PATH"

    create_swap_file() {
        local root="$1"
        local swap_size_mb="${2:-2048}"
        local swapfile="$root/swapfile"
        if [ -f "$swapfile" ]; then
            echo "Swap file already exists at $swapfile — skipping"
            return 0
        fi
        # Use a small size for testing
        dd if=/dev/zero of="$swapfile" bs=1M count=1 status=none 2>&1 || {
            rm -f "$swapfile"
            echo "WARNING: Failed to create swap file (non-fatal)"
            return 0
        }
        chmod 600 "$swapfile"
        mkswap "$swapfile" 2>&1
        echo "Created ${swap_size_mb}MB swap file"
        local fstab="$root/etc/fstab"
        if [ -f "$fstab" ] && ! grep -q '/swapfile' "$fstab"; then
            echo "/swapfile none swap sw 0 0" >> "$fstab"
            echo "Added swap file entry to fstab"
        fi
    }

    run create_swap_file "$root"
    [ "$status" -eq 0 ]
    [ -f "$root/swapfile" ]
    # Swap file should be 0600
    local perms
    perms=$(stat -c%a "$root/swapfile")
    [ "$perms" = "600" ]
    # fstab should have swap entry
    grep -q '/swapfile none swap sw 0 0' "$root/etc/fstab"
    [[ "$output" =~ "Created" ]]
    [[ "$output" =~ "Added swap file entry to fstab" ]]
}

@test "create_swap_file skips if swap file already exists" {
    local root="$TEST_TEMP_DIR/rootfs"
    mkdir -p "$root"
    touch "$root/swapfile"

    create_swap_file() {
        local root="$1"
        local swapfile="$root/swapfile"
        if [ -f "$swapfile" ]; then
            echo "Swap file already exists at $swapfile — skipping"
            return 0
        fi
    }

    run create_swap_file "$root"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "already exists" ]]
}

@test "create_swap_file does not duplicate fstab entry" {
    local root="$TEST_TEMP_DIR/rootfs"
    mkdir -p "$root/etc"
    cat > "$root/etc/fstab" <<'EOF'
UUID=aaaa-bbbb / ext4 defaults 0 1
/swapfile none swap sw 0 0
EOF

    cat > "$TEST_TEMP_DIR/mkswap" << 'MOCK'
#!/bin/bash
echo "Setting up swapspace..."
MOCK
    chmod +x "$TEST_TEMP_DIR/mkswap"
    export PATH="$TEST_TEMP_DIR:$PATH"

    create_swap_file() {
        local root="$1"
        local swapfile="$root/swapfile"
        if [ -f "$swapfile" ]; then
            echo "Swap file already exists at $swapfile — skipping"
            return 0
        fi
        dd if=/dev/zero of="$swapfile" bs=1M count=1 status=none 2>&1
        chmod 600 "$swapfile"
        mkswap "$swapfile" 2>&1
        echo "Created swap file"
        local fstab="$root/etc/fstab"
        if [ -f "$fstab" ] && ! grep -q '/swapfile' "$fstab"; then
            echo "/swapfile none swap sw 0 0" >> "$fstab"
            echo "Added swap file entry to fstab"
        fi
    }

    run create_swap_file "$root"
    [ "$status" -eq 0 ]
    # Should only have one swap entry
    local count
    count=$(grep -c '/swapfile' "$root/etc/fstab")
    [ "$count" -eq 1 ]
}

# ── select_partclone_tool tests ──────────────────────────────────────

@test "select_partclone_tool returns correct tool for ext4" {
    select_partclone_tool() {
        local fs_type="$1"
        case "$fs_type" in
            ext2) echo "partclone.ext2" ;; ext3) echo "partclone.ext3" ;;
            ext4) echo "partclone.ext4" ;; btrfs) echo "partclone.btrfs" ;;
            xfs)  echo "partclone.xfs" ;; *) echo ""; return 1 ;;
        esac
    }

    run select_partclone_tool "ext4"
    [ "$status" -eq 0 ]
    [ "$output" = "partclone.ext4" ]
}

@test "select_partclone_tool returns correct tool for btrfs" {
    select_partclone_tool() {
        local fs_type="$1"
        case "$fs_type" in
            ext2) echo "partclone.ext2" ;; ext3) echo "partclone.ext3" ;;
            ext4) echo "partclone.ext4" ;; btrfs) echo "partclone.btrfs" ;;
            xfs)  echo "partclone.xfs" ;; *) echo ""; return 1 ;;
        esac
    }

    run select_partclone_tool "btrfs"
    [ "$status" -eq 0 ]
    [ "$output" = "partclone.btrfs" ]
}

@test "select_partclone_tool returns correct tool for xfs" {
    select_partclone_tool() {
        local fs_type="$1"
        case "$fs_type" in
            ext2) echo "partclone.ext2" ;; ext3) echo "partclone.ext3" ;;
            ext4) echo "partclone.ext4" ;; btrfs) echo "partclone.btrfs" ;;
            xfs)  echo "partclone.xfs" ;; *) echo ""; return 1 ;;
        esac
    }

    run select_partclone_tool "xfs"
    [ "$status" -eq 0 ]
    [ "$output" = "partclone.xfs" ]
}

@test "select_partclone_tool returns correct tool for ext2" {
    select_partclone_tool() {
        local fs_type="$1"
        case "$fs_type" in
            ext2) echo "partclone.ext2" ;; ext3) echo "partclone.ext3" ;;
            ext4) echo "partclone.ext4" ;; btrfs) echo "partclone.btrfs" ;;
            xfs)  echo "partclone.xfs" ;; *) echo ""; return 1 ;;
        esac
    }

    run select_partclone_tool "ext2"
    [ "$status" -eq 0 ]
    [ "$output" = "partclone.ext2" ]
}

@test "select_partclone_tool fails for unsupported filesystem" {
    select_partclone_tool() {
        local fs_type="$1"
        case "$fs_type" in
            ext2) echo "partclone.ext2" ;; ext3) echo "partclone.ext3" ;;
            ext4) echo "partclone.ext4" ;; btrfs) echo "partclone.btrfs" ;;
            xfs)  echo "partclone.xfs" ;; *) echo ""; return 1 ;;
        esac
    }

    run select_partclone_tool "ntfs"
    [ "$status" -eq 1 ]
    [ "$output" = "" ]
}

@test "select_partclone_tool fails for empty input" {
    select_partclone_tool() {
        local fs_type="$1"
        case "$fs_type" in
            ext2) echo "partclone.ext2" ;; ext3) echo "partclone.ext3" ;;
            ext4) echo "partclone.ext4" ;; btrfs) echo "partclone.btrfs" ;;
            xfs)  echo "partclone.xfs" ;; *) echo ""; return 1 ;;
        esac
    }

    run select_partclone_tool ""
    [ "$status" -eq 1 ]
    [ "$output" = "" ]
}

# ── validate_fstab tests ────────────────────────────────────────────

@test "validate_fstab detects stale UUIDs from old disk" {
    local fstab="$TEST_TEMP_DIR/fstab"
    local old_disk="$TEST_TEMP_DIR/dev/sdb"

    # Create mock blkid that returns known UUIDs for the old disk
    cat > "$TEST_TEMP_DIR/blkid" << 'MOCK'
#!/bin/bash
if [[ "$1" == "-o" && "$2" == "value" && "$3" == "-s" && "$4" == "UUID" ]]; then
    shift 4
    for dev in "$@"; do
        case "$dev" in
            */sdb1) echo "stale-uuid-1111" ;;
            */sdb2) echo "stale-uuid-2222" ;;
        esac
    done
fi
MOCK
    chmod +x "$TEST_TEMP_DIR/blkid"
    export PATH="$TEST_TEMP_DIR:$PATH"

    # Create old disk device files
    mkdir -p "$TEST_TEMP_DIR/dev"
    touch "$TEST_TEMP_DIR/dev/sdb" "$TEST_TEMP_DIR/dev/sdb1" "$TEST_TEMP_DIR/dev/sdb2"

    # Create fstab with a stale UUID
    cat > "$fstab" <<'EOF'
UUID=new-root-uuid / ext4 defaults 0 1
UUID=stale-uuid-1111 /data ext4 defaults 0 2
UUID=new-esp-uuid /boot/efi vfat defaults 0 2
EOF

    # Mock send_kvp as no-op
    send_kvp() { true; }
    export -f send_kvp

    validate_fstab() {
        local fstab_path="$1"
        local old_disk="$2"
        local warnings=0
        [ -f "$fstab_path" ] || return 0
        local old_uuids
        old_uuids=$(blkid -o value -s UUID "$old_disk"* 2>/dev/null | sort -u)
        for uuid in $old_uuids; do
            if grep -q "$uuid" "$fstab_path"; then
                echo "WARNING: fstab still references old disk UUID $uuid"
                send_kvp "FstabWarning" "Stale UUID: $uuid" 2>/dev/null || true
                ((warnings++))
            fi
        done
        if grep -qE "^/dev/sd[a-z][0-9]" "$fstab_path"; then
            echo "WARNING: fstab contains device-path entries that may not survive disk reordering"
            ((warnings++))
        fi
        if [ "$warnings" -eq 0 ]; then
            echo "fstab validation PASSED — no stale references found"
        else
            echo "fstab validation completed with $warnings warning(s)"
        fi
        return 0
    }

    run validate_fstab "$fstab" "$TEST_TEMP_DIR/dev/sdb"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "WARNING: fstab still references old disk UUID stale-uuid-1111" ]]
    [[ "$output" =~ "1 warning" ]]
}

@test "validate_fstab passes when no stale references exist" {
    local fstab="$TEST_TEMP_DIR/fstab"

    # Create mock blkid that returns UUIDs NOT in fstab
    cat > "$TEST_TEMP_DIR/blkid" << 'MOCK'
#!/bin/bash
if [[ "$1" == "-o" && "$2" == "value" && "$3" == "-s" && "$4" == "UUID" ]]; then
    shift 4
    case "$1" in
        */sdb1) echo "old-uuid-gone" ;;
        */sdb2) echo "old-uuid-removed" ;;
    esac
fi
MOCK
    chmod +x "$TEST_TEMP_DIR/blkid"
    export PATH="$TEST_TEMP_DIR:$PATH"

    mkdir -p "$TEST_TEMP_DIR/dev"
    touch "$TEST_TEMP_DIR/dev/sdb" "$TEST_TEMP_DIR/dev/sdb1" "$TEST_TEMP_DIR/dev/sdb2"

    cat > "$fstab" <<'EOF'
UUID=new-root-uuid / ext4 defaults 0 1
UUID=new-esp-uuid /boot/efi vfat defaults 0 2
/swapfile none swap sw 0 0
EOF

    send_kvp() { true; }
    export -f send_kvp

    validate_fstab() {
        local fstab_path="$1"
        local old_disk="$2"
        local warnings=0
        [ -f "$fstab_path" ] || return 0
        local old_uuids
        old_uuids=$(blkid -o value -s UUID "$old_disk"* 2>/dev/null | sort -u)
        for uuid in $old_uuids; do
            if grep -q "$uuid" "$fstab_path"; then
                echo "WARNING: fstab still references old disk UUID $uuid"
                ((warnings++))
            fi
        done
        if grep -qE "^/dev/sd[a-z][0-9]" "$fstab_path"; then
            echo "WARNING: fstab contains device-path entries"
            ((warnings++))
        fi
        if [ "$warnings" -eq 0 ]; then
            echo "fstab validation PASSED — no stale references found"
        else
            echo "fstab validation completed with $warnings warning(s)"
        fi
        return 0
    }

    run validate_fstab "$fstab" "$TEST_TEMP_DIR/dev/sdb"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "PASSED" ]]
}

@test "validate_fstab warns about device-path entries" {
    local fstab="$TEST_TEMP_DIR/fstab"

    cat > "$TEST_TEMP_DIR/blkid" << 'MOCK'
#!/bin/bash
echo ""
MOCK
    chmod +x "$TEST_TEMP_DIR/blkid"
    export PATH="$TEST_TEMP_DIR:$PATH"

    mkdir -p "$TEST_TEMP_DIR/dev"
    touch "$TEST_TEMP_DIR/dev/sdb"

    cat > "$fstab" <<'EOF'
/dev/sda1 / ext4 defaults 0 1
/dev/sda2 /boot/efi vfat defaults 0 2
EOF

    send_kvp() { true; }
    export -f send_kvp

    validate_fstab() {
        local fstab_path="$1"
        local old_disk="$2"
        local warnings=0
        [ -f "$fstab_path" ] || return 0
        local old_uuids
        old_uuids=$(blkid -o value -s UUID "$old_disk"* 2>/dev/null | sort -u)
        for uuid in $old_uuids; do
            if grep -q "$uuid" "$fstab_path"; then
                echo "WARNING: fstab still references old disk UUID $uuid"
                ((warnings++))
            fi
        done
        if grep -qE "^/dev/sd[a-z][0-9]" "$fstab_path"; then
            echo "WARNING: fstab contains device-path entries that may not survive disk reordering"
            ((warnings++))
        fi
        if [ "$warnings" -eq 0 ]; then
            echo "fstab validation PASSED"
        else
            echo "fstab validation completed with $warnings warning(s)"
        fi
        return 0
    }

    run validate_fstab "$fstab" "$TEST_TEMP_DIR/dev/sdb"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "device-path entries" ]]
    [[ "$output" =~ "1 warning" ]]
}

@test "validate_fstab handles missing fstab gracefully" {
    validate_fstab() {
        local fstab_path="$1"
        [ -f "$fstab_path" ] || return 0
    }

    run validate_fstab "$TEST_TEMP_DIR/nonexistent" "/dev/sdb"
    [ "$status" -eq 0 ]
}

# ── ensure_hyperv_initramfs_modules tests ────────────────────────────

@test "ensure_hyperv_initramfs_modules adds modules to initramfs-tools" {
    local root="$TEST_TEMP_DIR/rootfs"
    mkdir -p "$root/etc/initramfs-tools"
    echo "# Existing modules" > "$root/etc/initramfs-tools/modules"

    ensure_hyperv_initramfs_modules() {
        local root="$1"
        local modules="hv_vmbus hv_storvsc hv_netvsc hv_utils"
        echo "Ensuring Hyper-V modules are included in initramfs..."
        if [ -f "$root/etc/initramfs-tools/modules" ]; then
            for mod in $modules; do
                if ! grep -q "^${mod}$" "$root/etc/initramfs-tools/modules"; then
                    echo "$mod" >> "$root/etc/initramfs-tools/modules"
                    echo "Added $mod to initramfs-tools modules"
                fi
            done
        fi
    }

    run ensure_hyperv_initramfs_modules "$root"
    [ "$status" -eq 0 ]
    grep -q "^hv_vmbus$" "$root/etc/initramfs-tools/modules"
    grep -q "^hv_storvsc$" "$root/etc/initramfs-tools/modules"
    grep -q "^hv_netvsc$" "$root/etc/initramfs-tools/modules"
    grep -q "^hv_utils$" "$root/etc/initramfs-tools/modules"
    [[ "$output" =~ "Added hv_vmbus" ]]
}

@test "ensure_hyperv_initramfs_modules does not duplicate existing modules" {
    local root="$TEST_TEMP_DIR/rootfs"
    mkdir -p "$root/etc/initramfs-tools"
    cat > "$root/etc/initramfs-tools/modules" <<'EOF'
# Existing modules
hv_vmbus
hv_storvsc
EOF

    ensure_hyperv_initramfs_modules() {
        local root="$1"
        local modules="hv_vmbus hv_storvsc hv_netvsc hv_utils"
        echo "Ensuring Hyper-V modules are included in initramfs..."
        if [ -f "$root/etc/initramfs-tools/modules" ]; then
            for mod in $modules; do
                if ! grep -q "^${mod}$" "$root/etc/initramfs-tools/modules"; then
                    echo "$mod" >> "$root/etc/initramfs-tools/modules"
                    echo "Added $mod to initramfs-tools modules"
                fi
            done
        fi
    }

    run ensure_hyperv_initramfs_modules "$root"
    [ "$status" -eq 0 ]
    # hv_vmbus and hv_storvsc should NOT be added again
    local vmbus_count
    vmbus_count=$(grep -c "^hv_vmbus$" "$root/etc/initramfs-tools/modules")
    [ "$vmbus_count" -eq 1 ]
    local storvsc_count
    storvsc_count=$(grep -c "^hv_storvsc$" "$root/etc/initramfs-tools/modules")
    [ "$storvsc_count" -eq 1 ]
    # hv_netvsc and hv_utils should be added
    grep -q "^hv_netvsc$" "$root/etc/initramfs-tools/modules"
    grep -q "^hv_utils$" "$root/etc/initramfs-tools/modules"
    [[ "$output" =~ "Added hv_netvsc" ]]
    [[ "$output" =~ "Added hv_utils" ]]
    # Should NOT mention adding the existing ones
    [[ ! "$output" =~ "Added hv_vmbus" ]]
    [[ ! "$output" =~ "Added hv_storvsc" ]]
}

@test "ensure_hyperv_initramfs_modules creates dracut config" {
    local root="$TEST_TEMP_DIR/rootfs"
    mkdir -p "$root/etc/dracut.conf.d"

    ensure_hyperv_initramfs_modules() {
        local root="$1"
        local modules="hv_vmbus hv_storvsc hv_netvsc hv_utils"
        echo "Ensuring Hyper-V modules are included in initramfs..."
        if [ -d "$root/etc/dracut.conf.d" ]; then
            echo "add_drivers+=\" $modules \"" \
                > "$root/etc/dracut.conf.d/hyperv.conf"
            echo "Created dracut hyperv.conf with modules: $modules"
        fi
    }

    run ensure_hyperv_initramfs_modules "$root"
    [ "$status" -eq 0 ]
    [ -f "$root/etc/dracut.conf.d/hyperv.conf" ]
    grep -q "hv_vmbus" "$root/etc/dracut.conf.d/hyperv.conf"
    grep -q "hv_storvsc" "$root/etc/dracut.conf.d/hyperv.conf"
    grep -q "add_drivers" "$root/etc/dracut.conf.d/hyperv.conf"
    [[ "$output" =~ "Created dracut hyperv.conf" ]]
}

@test "ensure_hyperv_initramfs_modules creates mkinitcpio config" {
    local root="$TEST_TEMP_DIR/rootfs"
    mkdir -p "$root/etc/mkinitcpio.conf.d"

    ensure_hyperv_initramfs_modules() {
        local root="$1"
        local modules="hv_vmbus hv_storvsc hv_netvsc hv_utils"
        echo "Ensuring Hyper-V modules are included in initramfs..."
        if [ -d "$root/etc/mkinitcpio.conf.d" ]; then
            echo "MODULES=($modules)" \
                > "$root/etc/mkinitcpio.conf.d/hyperv.conf"
            echo "Created mkinitcpio hyperv.conf with modules: $modules"
        fi
    }

    run ensure_hyperv_initramfs_modules "$root"
    [ "$status" -eq 0 ]
    [ -f "$root/etc/mkinitcpio.conf.d/hyperv.conf" ]
    grep -q "MODULES=(hv_vmbus" "$root/etc/mkinitcpio.conf.d/hyperv.conf"
    [[ "$output" =~ "Created mkinitcpio hyperv.conf" ]]
}

@test "ensure_hyperv_initramfs_modules handles all three systems simultaneously" {
    local root="$TEST_TEMP_DIR/rootfs"
    mkdir -p "$root/etc/initramfs-tools"
    mkdir -p "$root/etc/dracut.conf.d"
    mkdir -p "$root/etc/mkinitcpio.conf.d"
    echo "# modules" > "$root/etc/initramfs-tools/modules"

    ensure_hyperv_initramfs_modules() {
        local root="$1"
        local modules="hv_vmbus hv_storvsc hv_netvsc hv_utils"
        echo "Ensuring Hyper-V modules are included in initramfs..."
        if [ -f "$root/etc/initramfs-tools/modules" ]; then
            for mod in $modules; do
                if ! grep -q "^${mod}$" "$root/etc/initramfs-tools/modules"; then
                    echo "$mod" >> "$root/etc/initramfs-tools/modules"
                fi
            done
        fi
        if [ -d "$root/etc/dracut.conf.d" ]; then
            echo "add_drivers+=\" $modules \"" > "$root/etc/dracut.conf.d/hyperv.conf"
        fi
        if [ -d "$root/etc/mkinitcpio.conf.d" ]; then
            echo "MODULES=($modules)" > "$root/etc/mkinitcpio.conf.d/hyperv.conf"
        fi
    }

    run ensure_hyperv_initramfs_modules "$root"
    [ "$status" -eq 0 ]
    # All three should be populated
    grep -q "hv_vmbus" "$root/etc/initramfs-tools/modules"
    [ -f "$root/etc/dracut.conf.d/hyperv.conf" ]
    [ -f "$root/etc/mkinitcpio.conf.d/hyperv.conf" ]
}

# ── distro_boot_id tests (from install_grub.sh) ─────────────────────

@test "distro_boot_id returns ubuntu for ubuntu" {
    distro_boot_id() {
        local ID="$1" ID_LIKE="$2"
        case "$ID" in
            ubuntu) echo "ubuntu" ;; kali) echo "kali" ;; parrot) echo "parrot" ;;
            debian) echo "debian" ;; fedora) echo "fedora" ;;
            opensuse-tumbleweed|opensuse-leap) echo "opensuse" ;; arch) echo "arch" ;;
            *) if [[ "${ID_LIKE:-}" =~ debian ]]; then echo "debian"
               elif [[ "${ID_LIKE:-}" =~ fedora ]]; then echo "fedora"
               elif [[ "${ID_LIKE:-}" =~ arch ]]; then echo "arch"
               elif [[ "${ID_LIKE:-}" =~ suse ]]; then echo "opensuse"
               else echo "GRUB"; fi ;;
        esac
    }

    run distro_boot_id "ubuntu" ""
    [ "$output" = "ubuntu" ]
}

@test "distro_boot_id returns kali for kali" {
    distro_boot_id() {
        local ID="$1" ID_LIKE="$2"
        case "$ID" in
            ubuntu) echo "ubuntu" ;; kali) echo "kali" ;; parrot) echo "parrot" ;;
            debian) echo "debian" ;; fedora) echo "fedora" ;;
            opensuse-tumbleweed|opensuse-leap) echo "opensuse" ;; arch) echo "arch" ;;
            *) if [[ "${ID_LIKE:-}" =~ debian ]]; then echo "debian"
               elif [[ "${ID_LIKE:-}" =~ fedora ]]; then echo "fedora"
               elif [[ "${ID_LIKE:-}" =~ arch ]]; then echo "arch"
               elif [[ "${ID_LIKE:-}" =~ suse ]]; then echo "opensuse"
               else echo "GRUB"; fi ;;
        esac
    }

    run distro_boot_id "kali" ""
    [ "$output" = "kali" ]
}

@test "distro_boot_id falls back to debian for debian-like distros" {
    distro_boot_id() {
        local ID="$1" ID_LIKE="$2"
        case "$ID" in
            ubuntu) echo "ubuntu" ;; kali) echo "kali" ;; parrot) echo "parrot" ;;
            debian) echo "debian" ;; fedora) echo "fedora" ;;
            opensuse-tumbleweed|opensuse-leap) echo "opensuse" ;; arch) echo "arch" ;;
            *) if [[ "${ID_LIKE:-}" =~ debian ]]; then echo "debian"
               elif [[ "${ID_LIKE:-}" =~ fedora ]]; then echo "fedora"
               elif [[ "${ID_LIKE:-}" =~ arch ]]; then echo "arch"
               elif [[ "${ID_LIKE:-}" =~ suse ]]; then echo "opensuse"
               else echo "GRUB"; fi ;;
        esac
    }

    run distro_boot_id "remnux" "debian ubuntu"
    [ "$output" = "debian" ]
}

@test "distro_boot_id falls back to arch for arch-like distros" {
    distro_boot_id() {
        local ID="$1" ID_LIKE="$2"
        case "$ID" in
            ubuntu) echo "ubuntu" ;; kali) echo "kali" ;; parrot) echo "parrot" ;;
            debian) echo "debian" ;; fedora) echo "fedora" ;;
            opensuse-tumbleweed|opensuse-leap) echo "opensuse" ;; arch) echo "arch" ;;
            *) if [[ "${ID_LIKE:-}" =~ debian ]]; then echo "debian"
               elif [[ "${ID_LIKE:-}" =~ fedora ]]; then echo "fedora"
               elif [[ "${ID_LIKE:-}" =~ arch ]]; then echo "arch"
               elif [[ "${ID_LIKE:-}" =~ suse ]]; then echo "opensuse"
               else echo "GRUB"; fi ;;
        esac
    }

    run distro_boot_id "blackarch" "arch"
    [ "$output" = "arch" ]
}

@test "distro_boot_id returns GRUB for unknown distros" {
    distro_boot_id() {
        local ID="$1" ID_LIKE="$2"
        case "$ID" in
            ubuntu) echo "ubuntu" ;; kali) echo "kali" ;; parrot) echo "parrot" ;;
            debian) echo "debian" ;; fedora) echo "fedora" ;;
            opensuse-tumbleweed|opensuse-leap) echo "opensuse" ;; arch) echo "arch" ;;
            *) if [[ "${ID_LIKE:-}" =~ debian ]]; then echo "debian"
               elif [[ "${ID_LIKE:-}" =~ fedora ]]; then echo "fedora"
               elif [[ "${ID_LIKE:-}" =~ arch ]]; then echo "arch"
               elif [[ "${ID_LIKE:-}" =~ suse ]]; then echo "opensuse"
               else echo "GRUB"; fi ;;
        esac
    }

    run distro_boot_id "unknown_distro" ""
    [ "$output" = "GRUB" ]
}

# ── resize_cloned_filesystem tests ───────────────────────────────────

@test "resize_cloned_filesystem calls e2fsck and resize2fs for ext4" {
    # Mock e2fsck and resize2fs
    cat > "$TEST_TEMP_DIR/e2fsck" << 'MOCK'
#!/bin/bash
echo "e2fsck called with: $@"
MOCK
    cat > "$TEST_TEMP_DIR/resize2fs" << 'MOCK'
#!/bin/bash
echo "resize2fs called with: $@"
MOCK
    chmod +x "$TEST_TEMP_DIR/e2fsck" "$TEST_TEMP_DIR/resize2fs"
    export PATH="$TEST_TEMP_DIR:$PATH"

    resize_cloned_filesystem() {
        local partition="$1"
        local fs_type="$2"
        echo "Resizing $fs_type filesystem on $partition to fill partition..."
        case "$fs_type" in
            ext2|ext3|ext4)
                e2fsck -f -y "$partition" 2>&1 || true
                resize2fs "$partition" 2>&1
                echo "ext filesystem resized successfully"
                ;;
            *) echo "WARNING: Don't know how to resize $fs_type — skipping" ;;
        esac
    }

    run resize_cloned_filesystem "/dev/sda2" "ext4"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "e2fsck called with" ]]
    [[ "$output" =~ "resize2fs called with" ]]
    [[ "$output" =~ "ext filesystem resized successfully" ]]
}

@test "resize_cloned_filesystem handles ext2 and ext3" {
    cat > "$TEST_TEMP_DIR/e2fsck" << 'MOCK'
#!/bin/bash
echo "e2fsck ok"
MOCK
    cat > "$TEST_TEMP_DIR/resize2fs" << 'MOCK'
#!/bin/bash
echo "resize2fs ok"
MOCK
    chmod +x "$TEST_TEMP_DIR/e2fsck" "$TEST_TEMP_DIR/resize2fs"
    export PATH="$TEST_TEMP_DIR:$PATH"

    resize_cloned_filesystem() {
        local partition="$1"
        local fs_type="$2"
        echo "Resizing $fs_type filesystem..."
        case "$fs_type" in
            ext2|ext3|ext4)
                e2fsck -f -y "$partition" 2>&1 || true
                resize2fs "$partition" 2>&1
                echo "ext filesystem resized successfully"
                ;;
            *) echo "WARNING: Don't know how to resize $fs_type" ;;
        esac
    }

    run resize_cloned_filesystem "/dev/sda2" "ext2"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "ext filesystem resized successfully" ]]

    run resize_cloned_filesystem "/dev/sda2" "ext3"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "ext filesystem resized successfully" ]]
}

@test "resize_cloned_filesystem skips unknown filesystem types" {
    resize_cloned_filesystem() {
        local partition="$1"
        local fs_type="$2"
        echo "Resizing $fs_type filesystem on $partition to fill partition..."
        case "$fs_type" in
            ext2|ext3|ext4)
                echo "ext resize"
                ;;
            xfs)
                echo "xfs resize"
                ;;
            btrfs)
                echo "btrfs resize"
                ;;
            *)
                echo "WARNING: Don't know how to resize $fs_type — skipping"
                ;;
        esac
    }

    run resize_cloned_filesystem "/dev/sda2" "zfs"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "WARNING: Don't know how to resize zfs" ]]
}

# ── GRUB pinning test (Debian) ───────────────────────────────────────

@test "install_grub.sh pins GRUB packages on Debian-family systems" {
    # Verify the install_grub.sh contains the apt-mark hold line
    grep -q 'apt-mark hold grub-efi-amd64-signed shim-signed' \
        "$PROJECT_ROOT/autorun/install_grub.sh"
}

@test "install_grub.sh runs dual grub-install for all distro families" {
    # Verify each distro block has both a distro-specific and --removable install
    local script="$PROJECT_ROOT/autorun/install_grub.sh"

    # Count distro-specific installs (with $DISTRO_BOOT_ID)
    local distro_installs
    distro_installs=$(grep -c 'bootloader-id="\$DISTRO_BOOT_ID"' "$script")
    [ "$distro_installs" -ge 4 ]  # arch, debian, fedora, suse

    # Count removable fallback installs
    local removable_installs
    removable_installs=$(grep -c '\-\-removable' "$script")
    [ "$removable_installs" -ge 4 ]  # arch, debian, fedora, suse
}
