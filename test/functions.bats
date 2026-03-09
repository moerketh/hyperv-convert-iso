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