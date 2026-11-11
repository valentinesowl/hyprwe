#!/usr/bin/env bats
# lib/sunset.sh — `hwe sunset`, the night-light toggle.
#
# The daemon itself (hyprsunset, the colour matrix) is out of scope; what IS
# testable anywhere is the dispatch, the toggle's direction, and the exact
# waybar contract: JSON with a class while the binary exists, EMPTY output
# where it does not (that emptiness is what hides the bar module on Ubuntu's
# archive path — assert it, or a refactor could turn "hidden" into an error).

bats_require_minimum_version 1.5.0

setup() {
    load 'helper'
    hwe_setup
    export HWE_REPO_ROOT="$HWE_ROOT"
}

# Subshell for the usual reason (common.sh's `run` shadows bats'). The process
# seams are overridden: FAKE_AVAILABLE/FAKE_RUNNING pick the world, and on/off
# print markers instead of touching processes.
hwe_sunset() {
    bash -c '
        set -euo pipefail
        HWE_ROOT="$HWE_REPO_ROOT"
        source "$HWE_ROOT/lib/common.sh"
        source "$HWE_ROOT/lib/sunset.sh"
        _sunset_available() { [[ "${FAKE_AVAILABLE:-1}" == 1 ]]; }
        _sunset_running()   { [[ "${FAKE_RUNNING:-0}" == 1 ]]; }
        fn="$1"; shift
        "$fn" "$@"
    ' _ "$@"
}

@test "status prints off when the daemon is not running" {
    FAKE_RUNNING=0 run hwe_sunset _sunset_status
    assert_success
    assert_output "off"
}

@test "status prints on when it is" {
    FAKE_RUNNING=1 run hwe_sunset _sunset_status
    assert_success
    assert_output "on"
}

@test "status fails plainly when hyprsunset is not installed" {
    FAKE_AVAILABLE=0 run --separate-stderr hwe_sunset _sunset_status
    assert_failure
    [[ "$stderr" == *"not installed"* ]]
}

@test "waybar status carries a glyph, a class and the click action" {
    FAKE_RUNNING=1 run hwe_sunset _sunset_status --waybar
    assert_success
    assert_output --partial '"class":"on"'
    assert_output --partial '"text":"󰖔"'
    refute_output --partial 'ON'
    assert_output --partial 'Left click: turn off'
    FAKE_RUNNING=0 run hwe_sunset _sunset_status --waybar
    assert_output --partial '"class":"off"'
    assert_output --partial '"text":"󰖔"'
    refute_output --partial 'OFF'
    assert_output --partial 'Left click: turn on'
}

@test "waybar status is EMPTY and ok without the binary — that is what hides the module" {
    FAKE_AVAILABLE=0 run hwe_sunset _sunset_status --waybar
    assert_success
    assert_output ""
}

@test "bare sunset toggles away from the current state" {
    # Marker overrides ride on the same subshell trick, appended after the file.
    toggle() {
        bash -c '
            set -euo pipefail
            HWE_ROOT="$HWE_REPO_ROOT"
            source "$HWE_ROOT/lib/common.sh"
            source "$HWE_ROOT/lib/sunset.sh"
            _sunset_running() { [[ "${FAKE_RUNNING:-0}" == 1 ]]; }
            _sunset_on()  { echo "marker:on"; }
            _sunset_off() { echo "marker:off"; }
            sunset_main
        '
    }
    FAKE_RUNNING=0 run toggle
    assert_output "marker:on"
    FAKE_RUNNING=1 run toggle
    assert_output "marker:off"
}

@test "sunset names an unknown action rather than silently toggling" {
    run --separate-stderr "$HWE_ROOT/bin/hwe" sunset frobnicate
    assert_failure
    [[ "$stderr" == *"unknown sunset action: frobnicate"* ]]
}


@test "waybar status is one line of valid JSON" {
    FAKE_RUNNING=1 run hwe_sunset _sunset_status --waybar
    assert_success
    [[ "$output" != *$'\n'* ]]
    run python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["text"] == "󰖔"; assert "\n" in d["tooltip"]' <<< "$output"
    assert_success
}
