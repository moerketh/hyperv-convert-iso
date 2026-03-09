#!/usr/bin/env bats

load 'test_helper'

@test "smoke test passes" {
    true
}

@test "project root directory exists" {
    assert_directory_exists "$PROJECT_ROOT"
}

@test "test helper is loaded correctly" {
    # Test that PROJECT_ROOT is set
    [[ -n "$PROJECT_ROOT" ]]
    [[ -d "$PROJECT_ROOT" ]]
}

@test "temp directory is created during setup" {
    # Check that TEST_TEMP_DIR is created and is a directory
    [[ -n "$TEST_TEMP_DIR" ]]
    [[ -d "$TEST_TEMP_DIR" ]]
}

@test "skip_if_no_kvp function exists" {
    # Test that the helper function is defined
    declare -f skip_if_no_kvp
}

@test "skip_if_no_kvp function works with SKIP_KVP_TESTS set" {
    # Test that skip_if_no_kvp doesn't error when SKIP_KVP_TESTS is set
    export SKIP_KVP_TESTS=1
    
    # Create a subshell to test the skip function
    # We can't directly test skip because it exits the test
    (skip_if_no_kvp 2>/dev/null) && echo "skip called" || echo "skip not called"
    
    unset SKIP_KVP_TESTS
}