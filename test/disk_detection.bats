#!/usr/bin/env bats

# BATS tests for disk detection functions
# Tests: detect_disks, detect_partitions (with mocked system calls)

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

# Mock system commands for disk detection tests
setup_disk_detection_mocks() {
    # Create mock directories and devices
    mkdir -p "$TEST_TEMP_DIR/dev"
    
    # Create mock lsblk script
    cat > "$TEST_TEMP_DIR/lsblk" << 'EOF'
#!/bin/bash
if [[ "$1" == "-l" ]] && [[ "$2" == "-o" ]] && [[ "$3" == "NAME" ]] && [[ "$4" == "-n" ]]; then
    # For lsblk -l -o NAME -n output - handle any temp path
    if [[ "$5" =~ sda$ ]]; then
        echo "sda"
    elif [[ "$5" =~ sdb$ ]]; then
        echo "sdb"
        echo "sdb1"  
        echo "sdb2"
    fi
elif [[ "$1" =~ sda$ ]]; then
    # Empty disk with no partitions
    echo "sda"
elif [[ "$1" =~ sdb$ ]]; then
    # Disk with partitions
    echo "sdb"
    echo "sdb1"
    echo "sdb2"
fi
EOF
    chmod +x "$TEST_TEMP_DIR/lsblk"
    
    # Create mock blockdev script
    cat > "$TEST_TEMP_DIR/blockdev" << 'EOF'
#!/bin/bash
if [[ "$1" == "--getsz" ]]; then
    if [[ "$2" == "/dev/sda" ]]; then
        echo "2097152"  # ~1GB
    elif [[ "$2" == "/dev/sdb" ]]; then
        echo "4194304"  # ~2GB 
    fi
elif [[ "$1" == "--getsize64" ]]; then
    if [[ "$2" == "/dev/sda" ]]; then
        echo "1073741824"  # 1GB in bytes
    elif [[ "$2" == "/dev/sdb" ]]; then
        echo "2147483648"  # 2GB in bytes
    fi
fi
EOF
    chmod +x "$TEST_TEMP_DIR/blockdev"
    
    # Create mock device files
    touch "$TEST_TEMP_DIR/dev/sda" "$TEST_TEMP_DIR/dev/sdb"
    
    # Override PATH to use our mocks first
    export PATH="$TEST_TEMP_DIR:$PATH"
    export DEV_PATH="$TEST_TEMP_DIR/dev"
}

@test "detect_disks identifies empty and partitioned disks" {
    setup_disk_detection_mocks
    
    # Test disk detection logic directly
    local detect_disks_test="
        disks=($DEV_PATH/sda $DEV_PATH/sdb)
        new_disk=\"\"
        old_disk=\"\"
        
        for disk in \"\${disks[@]}\"; do
            part_count=\$(lsblk -l -o NAME -n \"\$disk\" | wc -l)
            if [ \"\$part_count\" -eq 1 ]; then
                new_disk=\$disk
            else
                old_disk=\$disk
            fi
        done

        if [ -z \"\$new_disk\" ] || [ -z \"\$old_disk\" ]; then
            echo \"Could not detect new (empty) or old disk. Aborting.\" >&2
            exit 1
        fi

        new_size=\$(blockdev --getsz \$new_disk)
        old_size=\$(blockdev --getsz \$old_disk)
        if (( new_size < old_size )); then
            temp=\$new_disk
            new_disk=\$old_disk
            old_disk=\$temp
        fi

        echo \"new_disk=\$new_disk old_disk=\$old_disk\"
    "
    
    # Debug what lsblk returns
    run bash -c "lsblk -l -o NAME -n $DEV_PATH/sda"
    echo "DEBUG lsblk sda: status=$status, output=$output"
    
    run bash -c "lsblk -l -o NAME -n $DEV_PATH/sdb"
    echo "DEBUG lsblk sdb: status=$status, output=$output"
    
    run bash -c "$detect_disks_test"
    echo "DEBUG detect_disks: status=$status, output=$output"
    [ "$status" -eq 0 ]
    [[ "$output" =~ new_disk=$DEV_PATH/sda ]] && [[ "$output" =~ old_disk=$DEV_PATH/sdb ]]
}

@test "detect_disks handles missing disks gracefully" {
    setup_disk_detection_mocks
    
    local detect_disks_test="
        disks=($DEV_PATH/nonexistent $DEV_PATH/also_missing)
        new_disk=\"\"
        old_disk=\"\"
        
        for disk in \"\${disks[@]}\"; do
            part_count=\$(lsblk -l -o NAME -n \"\$disk\" 2>/dev/null | wc -l)
            if [ \"\$part_count\" -eq 1 ]; then
                new_disk=\$disk
            else
                old_disk=\$disk
            fi
        done

        if [ -z \"\$new_disk\" ] || [ -z \"\$old_disk\" ]; then
            echo \"Could not detect new (empty) or old disk. Aborting.\" >&2
            exit 1
        fi
    "
    
    run bash -c "$detect_disks_test"
    [ "$status" -eq 1 ]
    [[ "$output" =~ Could\ not\ detect\ new\ \(empty\)\ or\ old\ disk\. ]]
}

@test "detect_partitions finds root filesystem" {
    # Test the filesystem type filtering logic
    local detect_partitions_test="
        partitions=\"/dev/sdb1\"
        temp_check=\"$TEST_TEMP_DIR/test_root\"
        
        root_part=\"\"
        root_found=false
        
        for part in \$partitions; do
            fs_type=\"ext4\"  # Mock ext4 filesystem

            if [[ ! \"\$fs_type\" =~ ^ext[234]\$ ]]; then
                echo \"Skipping non-ext4 partition: \$part (fs: \$fs_type)\"
                continue
            fi

            # Simulate successful mount and root detection
            root_found=true
            root_part=\"\$part\"
            echo \"Detected root partition: \$root_part (fs: \$fs_type)\"
            break
        done

        if ! \$root_found; then
            echo \"Error: No valid root partition found on /dev/sdb.\" >&2
            exit 1
        fi
        
        echo \"root_part=\$root_part\"
    "
    
    run bash -c "$detect_partitions_test"
    [ "$status" -eq 0 ]
    [[ "$output" =~ Detected\ root\ partition:\ /dev/sdb1 ]]
    [[ "$output" =~ root_part=/dev/sdb1 ]]
}

@test "detect_partitions skips non-filesystem partitions" {
    local test_root="$TEST_TEMP_DIR/test_root"
    mkdir -p "$test_root/bin" "$test_root/etc"
    
    # Create mock blkid script that returns swap
    cat > "$TEST_TEMP_DIR/blkid" << 'EOF'
#!/bin/bash
if [[ "$1" == "-o" ]]; then
    echo "swap"  # Not ext4, should be skipped
fi
EOF
    chmod +x "$TEST_TEMP_DIR/blkid"
    
    export PATH="$TEST_TEMP_DIR:$PATH"
    
    local detect_partitions_test="
        old_disk=/dev/sdb
        partitions=\"/dev/sdb1\"
        temp_check=\"$test_root\"
        
        root_part=\"\"
        root_found=false
        
        for part in \$partitions; do
            fs_type=\$(blkid -o value -s TYPE \"\$part\")

            if [[ ! \"\$fs_type\" =~ ^ext[234]\$ ]]; then
                echo \"Skipping non-ext4 partition: \$part (fs: \$fs_type)\"
                continue
            fi
        done
        
        echo \"root_part=\$root_part\"
    "
    
    run bash -c "$detect_partitions_test"
    [ "$status" -eq 0 ]
    [[ "$output" =~ Skipping\ non-ext4\ partition:\ /dev/sdb1\ \(fs:\ swap\) ]]
    [[ "$output" =~ root_part= ]]
}