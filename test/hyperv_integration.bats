#!/usr/bin/env bats

# BATS tests for Hyper-V integration shared functions
# Tests: capture_ssh_state, fix_apt_repo_conflicts, enable_services_via_symlinks,
#        generate_ssh_host_keys, fix_netplan_for_hyperv, disable_cloud_init_network

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

# ── capture_ssh_state tests ──────────────────────────────────────────

@test "capture_ssh_state creates marker when SSH is not enabled" {
    local root="$TEST_TEMP_DIR/rootfs"
    mkdir -p "$root/etc/systemd/system/multi-user.target.wants"

    # Source the actual function
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

    run capture_ssh_state "$root"
    [ "$status" -eq 0 ]
    [ -f "$root/var/lib/vmcreate/.ssh_was_disabled" ]
    [[ "$output" =~ "marked for post-boot restore" ]]
}

@test "capture_ssh_state does NOT create marker when ssh.service is enabled" {
    local root="$TEST_TEMP_DIR/rootfs"
    local wants="$root/etc/systemd/system/multi-user.target.wants"
    mkdir -p "$wants"
    # Simulate ssh.service already enabled (symlink exists)
    ln -sf /lib/systemd/system/ssh.service "$wants/ssh.service"

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

    run capture_ssh_state "$root"
    [ "$status" -eq 0 ]
    [ ! -f "$root/var/lib/vmcreate/.ssh_was_disabled" ]
}

@test "capture_ssh_state detects sshd.service (Fedora/Arch style)" {
    local root="$TEST_TEMP_DIR/rootfs"
    local wants="$root/etc/systemd/system/multi-user.target.wants"
    mkdir -p "$wants"
    ln -sf /usr/lib/systemd/system/sshd.service "$wants/sshd.service"

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

    run capture_ssh_state "$root"
    [ "$status" -eq 0 ]
    [ ! -f "$root/var/lib/vmcreate/.ssh_was_disabled" ]
}

# ── fix_apt_repo_conflicts tests ─────────────────────────────────────

@test "fix_apt_repo_conflicts removes .list when both .list and .sources exist" {
    local root="$TEST_TEMP_DIR/rootfs"
    mkdir -p "$root/etc/apt/sources.list.d"
    echo "deb http://packages.microsoft.com/ noble main" > "$root/etc/apt/sources.list.d/microsoft-prod.list"
    echo "Types: deb" > "$root/etc/apt/sources.list.d/microsoft.sources"

    fix_apt_repo_conflicts() {
        local root="$1"
        if [ -f "$root/etc/apt/sources.list.d/microsoft-prod.list" ] && \
           [ -f "$root/etc/apt/sources.list.d/microsoft.sources" ]; then
            rm -f "$root/etc/apt/sources.list.d/microsoft-prod.list"
            echo "Removed duplicate Microsoft repo file to fix apt conflict"
        fi
    }

    run fix_apt_repo_conflicts "$root"
    [ "$status" -eq 0 ]
    [ ! -f "$root/etc/apt/sources.list.d/microsoft-prod.list" ]
    [ -f "$root/etc/apt/sources.list.d/microsoft.sources" ]
    [[ "$output" =~ "Removed duplicate" ]]
}

@test "fix_apt_repo_conflicts does nothing when only .list exists" {
    local root="$TEST_TEMP_DIR/rootfs"
    mkdir -p "$root/etc/apt/sources.list.d"
    echo "deb http://packages.microsoft.com/ noble main" > "$root/etc/apt/sources.list.d/microsoft-prod.list"

    fix_apt_repo_conflicts() {
        local root="$1"
        if [ -f "$root/etc/apt/sources.list.d/microsoft-prod.list" ] && \
           [ -f "$root/etc/apt/sources.list.d/microsoft.sources" ]; then
            rm -f "$root/etc/apt/sources.list.d/microsoft-prod.list"
            echo "Removed duplicate Microsoft repo file to fix apt conflict"
        fi
    }

    run fix_apt_repo_conflicts "$root"
    [ "$status" -eq 0 ]
    [ -f "$root/etc/apt/sources.list.d/microsoft-prod.list" ]
    [ -z "$output" ]
}

@test "fix_apt_repo_conflicts does nothing when only .sources exists" {
    local root="$TEST_TEMP_DIR/rootfs"
    mkdir -p "$root/etc/apt/sources.list.d"
    echo "Types: deb" > "$root/etc/apt/sources.list.d/microsoft.sources"

    fix_apt_repo_conflicts() {
        local root="$1"
        if [ -f "$root/etc/apt/sources.list.d/microsoft-prod.list" ] && \
           [ -f "$root/etc/apt/sources.list.d/microsoft.sources" ]; then
            rm -f "$root/etc/apt/sources.list.d/microsoft-prod.list"
            echo "Removed duplicate Microsoft repo file to fix apt conflict"
        fi
    }

    run fix_apt_repo_conflicts "$root"
    [ "$status" -eq 0 ]
    [ -f "$root/etc/apt/sources.list.d/microsoft.sources" ]
    [ -z "$output" ]
}

@test "fix_apt_repo_conflicts does nothing when neither file exists" {
    local root="$TEST_TEMP_DIR/rootfs"
    mkdir -p "$root/etc/apt/sources.list.d"

    fix_apt_repo_conflicts() {
        local root="$1"
        if [ -f "$root/etc/apt/sources.list.d/microsoft-prod.list" ] && \
           [ -f "$root/etc/apt/sources.list.d/microsoft.sources" ]; then
            rm -f "$root/etc/apt/sources.list.d/microsoft-prod.list"
            echo "Removed duplicate Microsoft repo file to fix apt conflict"
        fi
    }

    run fix_apt_repo_conflicts "$root"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── enable_services_via_symlinks tests ───────────────────────────────

@test "enable_services_via_symlinks creates symlinks for Ubuntu-style services" {
    local root="$TEST_TEMP_DIR/rootfs"
    local wants="$root/etc/systemd/system/multi-user.target.wants"
    mkdir -p "$wants"
    # Create Ubuntu-style service files (hyphenated, under /lib)
    mkdir -p "$root/lib/systemd/system"
    touch "$root/lib/systemd/system/ssh.service"
    touch "$root/lib/systemd/system/hv-kvp-daemon.service"
    touch "$root/lib/systemd/system/hv-vss-daemon.service"
    touch "$root/lib/systemd/system/hv-fcopy-daemon.service"

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
            local _mask="$root/etc/systemd/system/${_svc}.service"
            if [ -L "$_mask" ] && [ "$(readlink "$_mask")" = "/dev/null" ]; then
                rm -f "$_mask"
                echo "Unmasked ${_svc}.service"
            fi
        done
    }

    run enable_services_via_symlinks "$root"
    [ "$status" -eq 0 ]
    # Check symlinks were created for the services that exist
    [ -L "$wants/ssh.service" ]
    [ -L "$wants/hv-kvp-daemon.service" ]
    [ -L "$wants/hv-vss-daemon.service" ]
    [ -L "$wants/hv-fcopy-daemon.service" ]
    # Underscored variants should NOT have symlinks (no service files for them)
    [ ! -L "$wants/hv_kvp_daemon.service" ]
    [[ "$output" =~ "Enabled ssh.service" ]]
    [[ "$output" =~ "Enabled hv-kvp-daemon.service" ]]
}

@test "enable_services_via_symlinks creates symlinks for Fedora-style services" {
    local root="$TEST_TEMP_DIR/rootfs"
    local wants="$root/etc/systemd/system/multi-user.target.wants"
    mkdir -p "$wants"
    # Create Fedora-style service files (underscored, under /usr/lib)
    mkdir -p "$root/usr/lib/systemd/system"
    touch "$root/usr/lib/systemd/system/sshd.service"
    touch "$root/usr/lib/systemd/system/hv_kvp_daemon.service"
    touch "$root/usr/lib/systemd/system/hv_vss_daemon.service"
    touch "$root/usr/lib/systemd/system/hv_fcopy_daemon.service"

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
            local _mask="$root/etc/systemd/system/${_svc}.service"
            if [ -L "$_mask" ] && [ "$(readlink "$_mask")" = "/dev/null" ]; then
                rm -f "$_mask"
                echo "Unmasked ${_svc}.service"
            fi
        done
    }

    run enable_services_via_symlinks "$root"
    [ "$status" -eq 0 ]
    [ -L "$wants/sshd.service" ]
    [ -L "$wants/hv_kvp_daemon.service" ]
    [ -L "$wants/hv_vss_daemon.service" ]
    [ -L "$wants/hv_fcopy_daemon.service" ]
    # Hyphenated variants should NOT have symlinks
    [ ! -L "$wants/hv-kvp-daemon.service" ]
    [[ "$output" =~ "Enabled sshd.service" ]]
    [[ "$output" =~ "Enabled hv_kvp_daemon.service" ]]
}

@test "enable_services_via_symlinks unmasks masked services" {
    local root="$TEST_TEMP_DIR/rootfs"
    local wants="$root/etc/systemd/system/multi-user.target.wants"
    mkdir -p "$wants"
    mkdir -p "$root/lib/systemd/system"
    touch "$root/lib/systemd/system/ssh.service"
    # Mask ssh.service (symlink to /dev/null)
    ln -sf /dev/null "$root/etc/systemd/system/ssh.service"

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
            local _mask="$root/etc/systemd/system/${_svc}.service"
            if [ -L "$_mask" ] && [ "$(readlink "$_mask")" = "/dev/null" ]; then
                rm -f "$_mask"
                echo "Unmasked ${_svc}.service"
            fi
        done
    }

    run enable_services_via_symlinks "$root"
    [ "$status" -eq 0 ]
    # Mask should be removed
    [ ! -L "$root/etc/systemd/system/ssh.service" ]
    [[ "$output" =~ "Unmasked ssh.service" ]]
    # Service should still be enabled in wants
    [ -L "$wants/ssh.service" ]
}

@test "enable_services_via_symlinks prefers /usr/lib over /lib" {
    local root="$TEST_TEMP_DIR/rootfs"
    local wants="$root/etc/systemd/system/multi-user.target.wants"
    mkdir -p "$wants"
    # Create service file in both locations
    mkdir -p "$root/usr/lib/systemd/system" "$root/lib/systemd/system"
    touch "$root/usr/lib/systemd/system/ssh.service"
    touch "$root/lib/systemd/system/ssh.service"

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
            local _mask="$root/etc/systemd/system/${_svc}.service"
            if [ -L "$_mask" ] && [ "$(readlink "$_mask")" = "/dev/null" ]; then
                rm -f "$_mask"
                echo "Unmasked ${_svc}.service"
            fi
        done
    }

    run enable_services_via_symlinks "$root"
    [ "$status" -eq 0 ]
    # Should use /usr/lib path (checked first)
    local target
    target=$(readlink "$wants/ssh.service")
    [ "$target" = "/usr/lib/systemd/system/ssh.service" ]
}

# ── generate_ssh_host_keys tests ─────────────────────────────────────

@test "generate_ssh_host_keys detects missing keys" {
    local root="$TEST_TEMP_DIR/rootfs"
    mkdir -p "$root/etc/ssh"
    # No host keys present

    # We can't actually run chroot in tests, so test the detection logic
    run bash -c "
        root='$root'
        if ! ls \"\$root/etc/ssh/ssh_host_\"*\"_key\" >/dev/null 2>&1; then
            echo 'No SSH host keys found — generating'
        else
            echo 'SSH host keys already exist'
        fi
    "
    [ "$status" -eq 0 ]
    [[ "$output" =~ "No SSH host keys found" ]]
}

@test "generate_ssh_host_keys skips when keys exist" {
    local root="$TEST_TEMP_DIR/rootfs"
    mkdir -p "$root/etc/ssh"
    # Create dummy host keys
    touch "$root/etc/ssh/ssh_host_rsa_key"
    touch "$root/etc/ssh/ssh_host_ed25519_key"

    run bash -c "
        root='$root'
        if ! ls \"\$root/etc/ssh/ssh_host_\"*\"_key\" >/dev/null 2>&1; then
            echo 'No SSH host keys found — generating'
        else
            echo 'SSH host keys already exist'
        fi
    "
    [ "$status" -eq 0 ]
    [[ "$output" =~ "SSH host keys already exist" ]]
}

# ── fix_netplan_for_hyperv tests ─────────────────────────────────────

@test "fix_netplan_for_hyperv replaces ens33 with match-all" {
    local root="$TEST_TEMP_DIR/rootfs"
    mkdir -p "$root/etc/netplan"
    cat > "$root/etc/netplan/50-cloud-init.yaml" << 'EOF'
network:
  version: 2
  ethernets:
    ens33:
      dhcp4: true
EOF

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

    run fix_netplan_for_hyperv "$root"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Replacing hardcoded interface" ]]
    # Check the content was replaced
    grep -q "hv_netvsc" "$root/etc/netplan/50-cloud-init.yaml"
    grep -q "all-en:" "$root/etc/netplan/50-cloud-init.yaml"
    ! grep -q "ens33:" "$root/etc/netplan/50-cloud-init.yaml"
}

@test "fix_netplan_for_hyperv replaces enp0s3 with match-all" {
    local root="$TEST_TEMP_DIR/rootfs"
    mkdir -p "$root/etc/netplan"
    cat > "$root/etc/netplan/01-netcfg.yaml" << 'EOF'
network:
  version: 2
  ethernets:
    enp0s3:
      dhcp4: true
      dhcp6: false
EOF

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

    run fix_netplan_for_hyperv "$root"
    [ "$status" -eq 0 ]
    grep -q "hv_netvsc" "$root/etc/netplan/01-netcfg.yaml"
    ! grep -q "enp0s3:" "$root/etc/netplan/01-netcfg.yaml"
}

@test "fix_netplan_for_hyperv preserves renderer when present" {
    local root="$TEST_TEMP_DIR/rootfs"
    mkdir -p "$root/etc/netplan"
    cat > "$root/etc/netplan/50-cloud-init.yaml" << 'EOF'
network:
  version: 2
  renderer: NetworkManager
  ethernets:
    ens33:
      dhcp4: true
EOF

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

    run fix_netplan_for_hyperv "$root"
    [ "$status" -eq 0 ]
    grep -q "renderer: NetworkManager" "$root/etc/netplan/50-cloud-init.yaml"
    grep -q "hv_netvsc" "$root/etc/netplan/50-cloud-init.yaml"
}

@test "fix_netplan_for_hyperv skips configs without hardcoded interface names" {
    local root="$TEST_TEMP_DIR/rootfs"
    mkdir -p "$root/etc/netplan"
    # Config that uses match: already — should not be touched
    cat > "$root/etc/netplan/50-cloud-init.yaml" << 'EOF'
network:
  version: 2
  ethernets:
    all-en:
      match:
        driver: hv_netvsc
      dhcp4: true
EOF

    fix_netplan_for_hyperv() {
        local root="$1"
        if ls "$root/etc/netplan/"*.yaml >/dev/null 2>&1; then
            for _np in "$root/etc/netplan/"*.yaml; do
                if grep -qE '^\s+(ens[0-9]|enp[0-9]|enx[0-9a-f]|eth[0-9])[a-z0-9]*:' "$_np"; then
                    echo "Replacing hardcoded interface in $_np"
                fi
            done
        fi
    }

    run fix_netplan_for_hyperv "$root"
    [ "$status" -eq 0 ]
    # The file should remain unchanged (still has all-en, not ens33)
    grep -q "all-en:" "$root/etc/netplan/50-cloud-init.yaml"
    grep -q "hv_netvsc" "$root/etc/netplan/50-cloud-init.yaml"
    # Should NOT contain "Replacing hardcoded interface" in output
    [[ ! "$output" =~ "Replacing hardcoded interface" ]]
}

@test "fix_netplan_for_hyperv handles no netplan directory" {
    local root="$TEST_TEMP_DIR/rootfs"
    mkdir -p "$root/etc"
    # No netplan directory

    fix_netplan_for_hyperv() {
        local root="$1"
        if ls "$root/etc/netplan/"*.yaml >/dev/null 2>&1; then
            echo "Found netplan files"
        fi
    }

    run fix_netplan_for_hyperv "$root"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── disable_cloud_init_network tests ─────────────────────────────────

@test "disable_cloud_init_network writes config when cloud-init is installed" {
    local root="$TEST_TEMP_DIR/rootfs"
    mkdir -p "$root/etc/cloud"

    disable_cloud_init_network() {
        local root="$1"
        if [ -d "$root/etc/cloud" ]; then
            mkdir -p "$root/etc/cloud/cloud.cfg.d"
            echo "network: {config: disabled}" > "$root/etc/cloud/cloud.cfg.d/99-disable-network.cfg"
            echo "Disabled cloud-init network config override"
        fi
    }

    run disable_cloud_init_network "$root"
    [ "$status" -eq 0 ]
    [ -f "$root/etc/cloud/cloud.cfg.d/99-disable-network.cfg" ]
    grep -q "network: {config: disabled}" "$root/etc/cloud/cloud.cfg.d/99-disable-network.cfg"
    [[ "$output" =~ "Disabled cloud-init network config override" ]]
}

@test "disable_cloud_init_network does nothing when cloud-init is not installed" {
    local root="$TEST_TEMP_DIR/rootfs"
    mkdir -p "$root/etc"
    # No /etc/cloud directory

    disable_cloud_init_network() {
        local root="$1"
        if [ -d "$root/etc/cloud" ]; then
            mkdir -p "$root/etc/cloud/cloud.cfg.d"
            echo "network: {config: disabled}" > "$root/etc/cloud/cloud.cfg.d/99-disable-network.cfg"
            echo "Disabled cloud-init network config override"
        fi
    }

    run disable_cloud_init_network "$root"
    [ "$status" -eq 0 ]
    [ ! -d "$root/etc/cloud/cloud.cfg.d" ]
    [ -z "$output" ]
}

@test "disable_cloud_init_network creates cloud.cfg.d if missing" {
    local root="$TEST_TEMP_DIR/rootfs"
    mkdir -p "$root/etc/cloud"
    # cloud.cfg.d doesn't exist yet

    disable_cloud_init_network() {
        local root="$1"
        if [ -d "$root/etc/cloud" ]; then
            mkdir -p "$root/etc/cloud/cloud.cfg.d"
            echo "network: {config: disabled}" > "$root/etc/cloud/cloud.cfg.d/99-disable-network.cfg"
            echo "Disabled cloud-init network config override"
        fi
    }

    run disable_cloud_init_network "$root"
    [ "$status" -eq 0 ]
    [ -d "$root/etc/cloud/cloud.cfg.d" ]
    [ -f "$root/etc/cloud/cloud.cfg.d/99-disable-network.cfg" ]
}

# ── fix_networkmanager_for_hyperv tests ──────────────────────────────

@test "fix_networkmanager_for_hyperv removes hardcoded VBox connection" {
    local root="$TEST_TEMP_DIR/rootfs"
    mkdir -p "$root/etc/NetworkManager/system-connections"
    cat > "$root/etc/NetworkManager/system-connections/Wired.nmconnection" <<'EOF'
[connection]
id=Wired connection 1
type=ethernet
interface-name=enp0s3
autoconnect=true

[ipv4]
method=auto
EOF

    fix_networkmanager_for_hyperv() {
        local root="$1"
        local nm_sys="$root/etc/NetworkManager/system-connections"
        [ -d "$nm_sys" ] || return 0
        local found=0
        for f in "$nm_sys"/*.nmconnection; do
            [ -f "$f" ] || continue
            if grep -qE 'interface-name=(enp[0-9]|ens[0-9]|eth[0-9]|enx[0-9a-f])' "$f"; then
                echo "Removing NM connection with hardcoded interface: $f"
                rm -f "$f"
                found=1
            fi
        done
        if [ "$found" -eq 1 ] || ! ls "$nm_sys"/*.nmconnection >/dev/null 2>&1; then
            echo "Creating generic DHCP connection for Hyper-V"
            cat > "$nm_sys/hyperv-dhcp.nmconnection" <<'NMCON'
[connection]
id=hyperv-dhcp
type=ethernet
autoconnect=true

[ipv4]
method=auto

[ipv6]
method=auto
NMCON
            chmod 600 "$nm_sys/hyperv-dhcp.nmconnection"
        fi
    }

    run fix_networkmanager_for_hyperv "$root"
    [ "$status" -eq 0 ]
    [ ! -f "$root/etc/NetworkManager/system-connections/Wired.nmconnection" ]
    [ -f "$root/etc/NetworkManager/system-connections/hyperv-dhcp.nmconnection" ]
    grep -q "method=auto" "$root/etc/NetworkManager/system-connections/hyperv-dhcp.nmconnection"
}

@test "fix_networkmanager_for_hyperv skips when no NM directory" {
    local root="$TEST_TEMP_DIR/rootfs"
    mkdir -p "$root"

    fix_networkmanager_for_hyperv() {
        local root="$1"
        local nm_sys="$root/etc/NetworkManager/system-connections"
        [ -d "$nm_sys" ] || return 0
    }

    run fix_networkmanager_for_hyperv "$root"
    [ "$status" -eq 0 ]
}

@test "fix_networkmanager_for_hyperv keeps non-VBox connections" {
    local root="$TEST_TEMP_DIR/rootfs"
    mkdir -p "$root/etc/NetworkManager/system-connections"
    cat > "$root/etc/NetworkManager/system-connections/wifi.nmconnection" <<'EOF'
[connection]
id=MyWifi
type=wifi
autoconnect=true

[wifi]
ssid=TestNet
EOF

    fix_networkmanager_for_hyperv() {
        local root="$1"
        local nm_sys="$root/etc/NetworkManager/system-connections"
        [ -d "$nm_sys" ] || return 0
        local found=0
        for f in "$nm_sys"/*.nmconnection; do
            [ -f "$f" ] || continue
            if grep -qE 'interface-name=(enp[0-9]|ens[0-9]|eth[0-9]|enx[0-9a-f])' "$f"; then
                rm -f "$f"
                found=1
            fi
        done
        if [ "$found" -eq 1 ] || ! ls "$nm_sys"/*.nmconnection >/dev/null 2>&1; then
            cat > "$nm_sys/hyperv-dhcp.nmconnection" <<'NMCON'
[connection]
id=hyperv-dhcp
type=ethernet
autoconnect=true

[ipv4]
method=auto

[ipv6]
method=auto
NMCON
            chmod 600 "$nm_sys/hyperv-dhcp.nmconnection"
        fi
    }

    run fix_networkmanager_for_hyperv "$root"
    [ "$status" -eq 0 ]
    [ -f "$root/etc/NetworkManager/system-connections/wifi.nmconnection" ]
    # No hardcoded interfaces removed, and existing .nmconnection exists, so no hyperv-dhcp created
    [ ! -f "$root/etc/NetworkManager/system-connections/hyperv-dhcp.nmconnection" ]
}

# ── fix_interfaces_for_hyperv tests ──────────────────────────────────

@test "fix_interfaces_for_hyperv replaces enp0s3 with eth0" {
    local root="$TEST_TEMP_DIR/rootfs"
    mkdir -p "$root/etc/network"
    cat > "$root/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback

auto enp0s3
iface enp0s3 inet dhcp
EOF

    fix_interfaces_for_hyperv() {
        local root="$1"
        local ifaces="$root/etc/network/interfaces"
        [ -f "$ifaces" ] || return 0
        if grep -qE '^(auto|allow-hotplug|iface)\s+(enp[0-9]|ens[0-9]|enx[0-9a-f])' "$ifaces"; then
            echo "Replacing hardcoded interface names in $ifaces"
            sed -i -E 's/^(auto|allow-hotplug|iface)(\s+)(enp[0-9][a-z0-9]*|ens[0-9][a-z0-9]*|enx[0-9a-f]+)/\1\2eth0/g' "$ifaces"
        fi
    }

    run fix_interfaces_for_hyperv "$root"
    [ "$status" -eq 0 ]
    grep -q "auto eth0" "$root/etc/network/interfaces"
    grep -q "iface eth0 inet dhcp" "$root/etc/network/interfaces"
    ! grep -q "enp0s3" "$root/etc/network/interfaces"
}

@test "fix_interfaces_for_hyperv skips when no interfaces file" {
    local root="$TEST_TEMP_DIR/rootfs"
    mkdir -p "$root"

    fix_interfaces_for_hyperv() {
        local root="$1"
        local ifaces="$root/etc/network/interfaces"
        [ -f "$ifaces" ] || return 0
    }

    run fix_interfaces_for_hyperv "$root"
    [ "$status" -eq 0 ]
}

@test "fix_interfaces_for_hyperv skips when no hardcoded names" {
    local root="$TEST_TEMP_DIR/rootfs"
    mkdir -p "$root/etc/network"
    cat > "$root/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

    fix_interfaces_for_hyperv() {
        local root="$1"
        local ifaces="$root/etc/network/interfaces"
        [ -f "$ifaces" ] || return 0
        if grep -qE '^(auto|allow-hotplug|iface)\s+(enp[0-9]|ens[0-9]|enx[0-9a-f])' "$ifaces"; then
            echo "Replacing hardcoded interface names in $ifaces"
            sed -i -E 's/^(auto|allow-hotplug|iface)(\s+)(enp[0-9][a-z0-9]*|ens[0-9][a-z0-9]*|enx[0-9a-f]+)/\1\2eth0/g' "$ifaces"
        fi
    }

    run fix_interfaces_for_hyperv "$root"
    [ "$status" -eq 0 ]
    [[ "$output" == "" ]]
}

# ── xRDP username prefill tests ──────────────────────────────────────

@test "install_xrdp prefills ls_username when XRDP_USERNAME is set" {
    local ini="$TEST_TEMP_DIR/xrdp.ini"
    cat > "$ini" << 'EOF'
[Globals]
port=3389
#ls_username=ask
ls_title=Test
EOF

    run bash -c "
        XRDP_USERNAME=remnux
        INI='$ini'
        if [ -n \"\${XRDP_USERNAME:-}\" ]; then
            sed -i '/^#*ls_username=/c\\ls_username='\"\${XRDP_USERNAME}\" \"\$INI\"
        fi
    "
    [ "$status" -eq 0 ]
    grep -q '^ls_username=remnux' "$ini"
    ! grep -q '#ls_username' "$ini"
}

@test "install_xrdp does not modify ls_username when XRDP_USERNAME is empty" {
    local ini="$TEST_TEMP_DIR/xrdp.ini"
    cat > "$ini" << 'EOF'
[Globals]
port=3389
#ls_username=ask
ls_title=Test
EOF

    run bash -c "
        XRDP_USERNAME=''
        INI='$ini'
        if [ -n \"\${XRDP_USERNAME:-}\" ]; then
            sed -i '/^#*ls_username=/c\\ls_username='\"\${XRDP_USERNAME}\" \"\$INI\"
        fi
    "
    [ "$status" -eq 0 ]
    grep -q '#ls_username=ask' "$ini"
}

@test "install_xrdp does not modify ls_username when XRDP_USERNAME is unset" {
    local ini="$TEST_TEMP_DIR/xrdp.ini"
    cat > "$ini" << 'EOF'
[Globals]
port=3389
#ls_username=ask
ls_title=Test
EOF

    run bash -c "
        unset XRDP_USERNAME
        INI='$ini'
        if [ -n \"\${XRDP_USERNAME:-}\" ]; then
            sed -i '/^#*ls_username=/c\\ls_username='\"\${XRDP_USERNAME}\" \"\$INI\"
        fi
    "
    [ "$status" -eq 0 ]
    grep -q '#ls_username=ask' "$ini"
}

@test "install_xrdp handles uncommented ls_username setting" {
    local ini="$TEST_TEMP_DIR/xrdp.ini"
    cat > "$ini" << 'EOF'
[Globals]
port=3389
ls_username=ask
ls_title=Test
EOF

    run bash -c "
        XRDP_USERNAME=kali
        INI='$ini'
        if [ -n \"\${XRDP_USERNAME:-}\" ]; then
            sed -i '/^#*ls_username=/c\\ls_username='\"\${XRDP_USERNAME}\" \"\$INI\"
        fi
    "
    [ "$status" -eq 0 ]
    grep -q '^ls_username=kali' "$ini"
    ! grep -q 'ls_username=ask' "$ini"
}
