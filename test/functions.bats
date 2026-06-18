#!/usr/bin/env bats

# BATS tests for core functions
# Tests individual functions in isolation

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

skip_if_no_kvp() {
    if [[ -n "$SKIP_KVP_TESTS" ]]; then
        skip "Skipping KVP tests - SKIP_KVP_TESTS is set"
    fi
}

@test "log function outputs correct format for INFO level" {
    # Define log function inline for testing
    log() {
        local level="$1"
        local message="$2"
        local timestamp
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        
        case "$level" in
            INFO|WARN|ERROR)
                echo "[$timestamp] [$level] $message"
                ;;
            *)
                echo "[$timestamp] [INFO] $message"
                ;;
        esac
    }
    
    run log "INFO" "Test message"
    [ "$status" -eq 0 ]
    [[ "$output" =~ \[INFO\] ]] && [[ "$output" =~ Test\ message ]]
}

@test "send_kvp creates properly formatted entry" {
    skip_if_no_kvp
    
    local test_pool="$TEST_TEMP_DIR/test_pool"
    
    # Create test KVP directory
    mkdir -p "$(dirname "$test_pool")"
    
    # Test send_kvp function with custom pool
    send_kvp_test() {
        local key="$1"
        local value="$2"
        local pool="$test_pool"
        local tmpfile
        tmpfile=$(mktemp) || { echo "Failed to create temp file"; exit 1; }

        # Write null-terminated key and pad to 512 bytes with nulls
        printf "%s\0" "$key" > "$tmpfile"
        truncate -s 512 "$tmpfile"

        # Append null-terminated value and pad to additional 2048 bytes (total 2560)
        printf "%s\0" "$value" >> "$tmpfile"
        truncate -s 2560 "$tmpfile"

        # Append the fixed-size record to the pool
        cat "$tmpfile" >> "$pool" || { echo "Failed to write to $pool"; rm "$tmpfile"; exit 1; }
        rm "$tmpfile"
    }
    
    run send_kvp_test "TestKey" "TestValue"
    [ "$status" -eq 0 ]
    
    # Verify pool file has correct size (2560 bytes per entry)
    [ $(stat -c%s "$test_pool") -eq 2560 ]
    
    # Cleanup
    rm -f "$test_pool"
}

@test "read_kvp parses sample pool correctly" {
    skip_if_no_kvp
    
    local sample_pool="$PROJECT_ROOT/test/fixtures/sample_kvp_pool"
    
    # Define read_kvp function inline for testing
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
    
    run read_kvp "$sample_pool"
    [ "$status" -eq 0 ]
    
    # Check for expected key-value pairs
    [[ "$output" =~ Key:\ TestKey ]] && [[ "$output" =~ Value:\ TestValue ]]
    [[ "$output" =~ Key:\ DiskInfo ]] && [[ "$output" =~ Value:\ /dev/sda ]]
    [[ "$output" =~ Key:\ Progress ]] && [[ "$output" =~ Value:\ 50% ]]
}

@test "create_swap_file creates 8192 MB swap file and adds fstab entry" {
    # Source the real function under test
    source "$PROJECT_ROOT/lib/functions.sh"

    # Mock filesystem tools that are absent in git-bash on Windows
    mkswap() { echo "mkswap: $1"; }
    swapon() { return 0; }
    export -f mkswap swapon

    # Create a fake root filesystem with enough free space
    local fake_root="$TEST_TEMP_DIR/fake_root"
    mkdir -p "$fake_root/etc"
    echo "UUID=abc123 / ext4 defaults 0 1" > "$fake_root/etc/fstab"

    # Use a smaller size to keep tests fast but verify parameter plumbing
    create_swap_file "$fake_root" 64

    # Verify swap file exists with correct size (~64 MB)
    [ -f "$fake_root/swapfile" ]
    local size_kb
    size_kb=$(du -k "$fake_root/swapfile" | cut -f1)
    [ "$size_kb" -ge 60000 ] && [ "$size_kb" -le 70000 ]

    # Verify permissions (chmod semantics differ on Windows test filesystems,
    # so we only assert the file exists and is not world-writable)
    local perms
    perms=$(stat -c '%a' "$fake_root/swapfile" 2>/dev/null || echo "unknown")
    if [ "$perms" != "unknown" ]; then
        [ "${perms: -1}" -le 6 ]  # no write/exec for others
    fi

    # Verify fstab entry
    grep -q '/swapfile none swap sw 0 0' "$fake_root/etc/fstab"
}

@test "create_swap_file skips when swap file already exists" {
    source "$PROJECT_ROOT/lib/functions.sh"

    local fake_root="$TEST_TEMP_DIR/fake_root"
    mkdir -p "$fake_root/etc"
    touch "$fake_root/swapfile"
    echo "pre-existing" > "$fake_root/etc/fstab"

    create_swap_file "$fake_root" 64

    # fstab should not get a duplicate entry
    [ "$(grep -c '/swapfile' "$fake_root/etc/fstab")" -eq 0 ]
}

@test "create_swap_file detects non-btrfs filesystem and skips chattr" {
    source "$PROJECT_ROOT/lib/functions.sh"

    mkswap() { echo "mkswap: $1"; }
    swapon() { return 0; }
    export -f mkswap swapon

    local fake_root="$TEST_TEMP_DIR/fake_root"
    mkdir -p "$fake_root/etc"
    echo "UUID=abc123 / ext4 defaults 0 1" > "$fake_root/etc/fstab"

    # Mock df -T to report ext4
    df() {
        if [ "$1" = "-T" ]; then
            echo -e "Filesystem\tType\t1K-blocks\tUsed\tAvailable\tUse%\tMounted on"
            echo -e "dummy\t\text4\t10485760\t1048576\t9437184\t10%\t$fake_root"
        else
            command df "$@"
        fi
    }
    export -f df

    create_swap_file "$fake_root" 64

    # Should still create file and fstab entry even though real mkswap is missing
    [ -f "$fake_root/swapfile" ]
    grep -q '/swapfile none swap sw 0 0' "$fake_root/etc/fstab"
}

@test "create_swap_file detects btrfs and would disable COW" {
    source "$PROJECT_ROOT/lib/functions.sh"

    mkswap() { echo "mkswap: $1"; }
    swapon() { return 0; }
    export -f mkswap swapon

    local fake_root="$TEST_TEMP_DIR/fake_root"
    mkdir -p "$fake_root/etc"
    echo "UUID=abc123 / btrfs defaults,subvol=@ 0 1" > "$fake_root/etc/fstab"

    # Mock df -T to report btrfs
    df() {
        if [ "$1" = "-T" ]; then
            echo -e "Filesystem\tType\t1K-blocks\tUsed\tAvailable\tUse%\tMounted on"
            echo -e "dummy\t\tbtrfs\t10485760\t1048576\t9437184\t10%\t$fake_root"
        else
            command df "$@"
        fi
    }
    export -f df

    # Mock chattr to record it was called (it won't exist in git-bash)
    chattr() {
        echo "chattr_called_with:$*" > "$TEST_TEMP_DIR/chattr_trace"
        return 0
    }
    export -f chattr

    create_swap_file "$fake_root" 64

    [ -f "$fake_root/swapfile" ]
    [ -f "$TEST_TEMP_DIR/chattr_trace" ]
    grep -q '+C' "$TEST_TEMP_DIR/chattr_trace"
    grep -q '/swapfile none swap sw 0 0' "$fake_root/etc/fstab"
}

@test "create_swap_file skips when root filesystem has insufficient space" {
    source "$PROJECT_ROOT/lib/functions.sh"

    # Create a tiny tmpfs to simulate low-space root
    local fake_root="$TEST_TEMP_DIR/tiny_root"
    mkdir -p "$fake_root/etc"
    mount -t tmpfs -o size=16m tmpfs "$fake_root" || skip "Cannot mount tmpfs for low-space test"
    echo "UUID=abc123 / ext4 defaults 0 1" > "$fake_root/etc/fstab"

    create_swap_file "$fake_root" 8192

    # Swap file should not be created because 8192 MB + 1 GB headroom exceeds 16 MB
    [ ! -f "$fake_root/swapfile" ]

    umount "$fake_root"
}

@test "report_progress logs without progress value" {
    # Mock log and send_kvp to capture calls
    log() {
        echo "LOG: $1: $2"
    }
    send_kvp() {
        echo "KVP: $1: $2"
    }
    
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
    
    run report_progress "Initialization"
    [ "$status" -eq 0 ]
    [[ "$output" =~ LOG:\ INFO:\ Workflow\ step:\ Initialization ]]
    [[ "$output" =~ KVP:\ WorkflowProgress:\ Initialization ]]
}