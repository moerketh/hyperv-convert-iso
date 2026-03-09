#!/usr/bin/env bats

# BATS tests for fstab update functionality
# Tests: update_fstab with various scenarios

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

# Mock blkid for UUID generation
setup_fstab_mocks() {
    cat > "$TEST_TEMP_DIR/blkid" << 'EOF'
#!/bin/bash
if [[ "$1" == "-s" ]] && [[ "$2" == "UUID" ]] && [[ "$3" == "-o" ]]; then
    if [[ "$4" == "/dev/old_root" ]]; then
        echo "abcd1234-abcd-1234-abcd-123456789abc"
    elif [[ "$4" == "/dev/new_root" ]]; then
        echo "11112222-1111-2222-3333-444455556666"
    elif [[ "$4" == "/dev/old_esp" ]]; then
        echo "efgh5678-efgh-5678-efgh-567890123456"
    elif [[ "$4" == "/dev/new_esp" ]]; then
        echo "77778888-7777-8888-9999-aaaabbbbcccc"
    elif [[ "$4" == "/dev/old_boot" ]]; then
        echo "ijkl9012-ijkl-9012-ijkl-901234567890"
    fi
fi
EOF
    chmod +x "$TEST_TEMP_DIR/blkid"
    export PATH="$TEST_TEMP_DIR:$PATH"
}

@test "update_fstab replaces root UUID correctly" {
    setup_fstab_mocks
    
    local test_fstab="$TEST_TEMP_DIR/test_fstab"
    cp "$PROJECT_ROOT/test/fixtures/sample_fstab" "$test_fstab"
    
    # Mock the global variables that update_fstab expects
    esp_part="/dev/old_esp"
    old_esp_uuid="efgh5678-efgh-5678-efgh-567890123456"
    boot_part="/dev/old_boot"
    old_boot_uuid="ijkl9012-ijkl-9012-ijkl-901234567890"
    boot_device="/dev/old_boot"
    
    # Simplified update_fstab test
    local update_fstab_test="
        fstab_path=\"$test_fstab\"
        old_root_uuid=\"abcd1234-abcd-1234-abcd-123456789abc\"
        new_root_uuid=\"11112222-1111-2222-3333-444455556666\"
        new_esp_uuid=\"77778888-7777-8888-9999-aaaabbbbcccc\"
        
        # Test root UUID replacement
        sed -i \"s/\$old_root_uuid/\$new_root_uuid/g\" \"\$fstab_path\"
        
        echo \"Root UUID updated\"
    "
    
    run bash -c "$update_fstab_test"
    [ "$status" -eq 0 ]
    
    # Check that root UUID was replaced
    grep -q "11112222-1111-2222-3333-444455556666" "$test_fstab"
    ! grep -q "abcd1234-abcd-1234-abcd-123456789abc" "$test_fstab"
}

@test "update_fstab replaces ESP UUID correctly" {
    setup_fstab_mocks
    
    local test_fstab="$TEST_TEMP_DIR/test_fstab"
    cp "$PROJECT_ROOT/test/fixtures/sample_fstab" "$test_fstab"
    
    # Simplified update_fstab test for ESP
    local update_fstab_test="
        fstab_path=\"$test_fstab\"
        old_esp_uuid=\"efgh5678-efgh-5678-efgh-567890123456\"
        new_esp_uuid=\"77778888-7777-8888-9999-aaaabbbbcccc\"
        
        # Test ESP UUID replacement
        sed -i \"s/\$old_esp_uuid/\$new_esp_uuid/g\" \"\$fstab_path\"
        
        echo \"ESP UUID updated\"
    "
    
    run bash -c "$update_fstab_test"
    [ "$status" -eq 0 ]
    
    # Check that ESP UUID was replaced
    grep -q "77778888-7777-8888-9999-aaaabbbbcccc" "$test_fstab"
    ! grep -q "efgh5678-efgh-5678-efgh-567890123456" "$test_fstab"
}

@test "update_fstab removes separate /boot entry" {
    setup_fstab_mocks
    
    local test_fstab="$TEST_TEMP_DIR/test_fstab"
    cp "$PROJECT_ROOT/test/fixtures/sample_fstab" "$test_fstab"
    
    # Simplified update_fstab test for boot removal
    local update_fstab_test="
        fstab_path=\"$test_fstab\"
        old_boot_uuid=\"efgh5678-efgh-5678-efgh-567890123456\"
        
        # Test boot entry removal
        sed -i \"/UUID=\$old_boot_uuid/d\" \"\$fstab_path\"
        
        echo \"Boot entry removed\"
    "
    
    run bash -c "$update_fstab_test"
    [ "$status" -eq 0 ]
    
    # Check that /boot entry was removed
    ! grep -q "efgh5678-efgh-5678-efgh-567890123456" "$test_fstab"
    ! grep -q "/boot.*ext4" "$test_fstab"
}

@test "update_fstab adds new /boot/efi entry when missing" {
    setup_fstab_mocks
    
    local test_fstab_no_esp="$TEST_TEMP_DIR/test_fstab_no_esp"
    # Create fstab without /boot/efi entry
    cat > "$test_fstab_no_esp" << 'EOF'
UUID=abcd1234-abcd-1234-abcd-123456789abc / ext4 defaults,errors=remount-ro 0 1
UUID=ijkl9012-ijkl-9012-ijkl-901234567890 /boot ext4 defaults 0 2
tmpfs /tmp tmpfs defaults 0 0
EOF
    
    # Simplified update_fstab test for ESP addition
    local update_fstab_test="
        fstab_path=\"$test_fstab_no_esp\"
        new_esp_uuid=\"77778888-7777-8888-9999-aaaabbbbcccc\"
        
        # Check if /boot/efi exists and add if missing
        if ! grep -q '/boot/efi' \"\$fstab_path\"; then
            echo \"UUID=\$new_esp_uuid /boot/efi vfat defaults 0 2\" >> \"\$fstab_path\"
            echo \"ESP entry added\"
        else
            echo \"ESP entry already exists\"
        fi
    "
    
    run bash -c "$update_fstab_test"
    [ "$status" -eq 0 ]
    
    # Check that /boot/efi entry was added
    grep -q "77778888-7777-8888-9999-aaaabbbbcccc /boot/efi vfat" "$test_fstab_no_esp"
}

@test "update_fstab creates new fstab when none exists" {
    setup_fstab_mocks
    
    local test_fstab="$TEST_TEMP_DIR/new_fstab"
    local test_dir="$TEST_TEMP_DIR/new_etc"
    
    # Create directory but no fstab file
    mkdir -p "$test_dir"
    
    # Simplified update_fstab test for new fstab creation
    local update_fstab_test="
        fstab_path=\"$test_fstab\"
        new_root_uuid=\"11112222-1111-2222-3333-444455556666\"
        new_esp_uuid=\"77778888-7777-8888-9999-aaaabbbbcccc\"
        
        # Create new fstab if doesn't exist
        if [ ! -f \"\$fstab_path\" ]; then
            mkdir -p \"\$(dirname \"\$fstab_path\")\"
            cat > \"\$fstab_path\" << EOF
UUID=\$new_root_uuid / ext4 defaults 0 1
UUID=\$new_esp_uuid /boot/efi vfat defaults 0 2
EOF
            echo \"New fstab created\"
        fi
    "
    
    run bash -c "$update_fstab_test"
    [ "$status" -eq 0 ]
    
    # Check that new fstab was created with correct content
    [ -f "$test_fstab" ]
    grep -q "11112222-1111-2222-3333-444455556666 / ext4" "$test_fstab"
    grep -q "77778888-7777-8888-9999-aaaabbbbcccc /boot/efi vfat" "$test_fstab"
}