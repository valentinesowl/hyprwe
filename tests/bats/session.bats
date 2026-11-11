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

@test "session mode shows the key hint before entering the submap" {
    run bash -c '
        source "$HWE_ROOT/lib/common.sh"
        source "$HWE_ROOT/lib/session.sh"
        notify() { printf "notify:%s|%s|%s\n" "$1" "$2" "$3"; }
        _hyprctl() { printf "hyprctl:%s\n" "$*"; }
        session_main mode
    '
    assert_success
    assert_output --partial "1–9 save · Shift+1–9 restore · Esc cancel"
    assert_output --partial 'hl.dsp.submap("session")'
}

@test "a failed session save reports an error rather than success" {
    run bash -c '
        source "$HWE_ROOT/lib/common.sh"
        source "$HWE_ROOT/lib/session.sh"
        python3() { return 42; }
        notify() { printf "notify:%s|%s|%s\n" "$1" "$2" "$3"; }
        session_main save 3
    '
    assert_failure
    assert_output --partial "notify:error|Session save failed|Snapshot '3'"
    refute_output --partial "notify:success"
}
