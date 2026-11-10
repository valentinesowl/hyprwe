#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
    load 'helper'
    hwe_setup
    export HWE_SESSION_DIR="$BATS_TEST_TMPDIR/sessions"
}

@test "session help shows the complete command surface" {
    run --separate-stderr hwe session help
    assert_success
    [[ "$stderr" == *"save <name>"* ]]
    [[ "$stderr" == *"restore <name>"* ]]
    [[ "$stderr" == *"list"* ]]
    [[ "$stderr" == *"clear --all"* ]]
}

@test "an unknown session action fails instead of guessing" {
    run --separate-stderr hwe session frobnicate
    assert_failure
    [[ "$stderr" == *"unknown session action: frobnicate"* ]]
}

@test "save rejects a path traversal name before asking Hyprland for anything" {
    run --separate-stderr hwe session save ../escape
    assert_failure
    [[ "$stderr" == *"invalid session name"* ]]
}

@test "list works in an empty state directory" {
    run hwe session list
    assert_success
    assert_output "no saved sessions"
}

@test "clear --all is safe on an empty state directory" {
    HWE_ASSUME_YES=1 run hwe session clear --all
    assert_success
    assert_output "deleted 0 saved session(s)"
}

@test "clear reports a missing snapshot" {
    run --separate-stderr hwe session clear missing
    assert_failure
    [[ "$stderr" == *"session not found: missing"* ]]
}
