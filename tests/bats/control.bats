#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
    load 'helper'
    hwe_setup
}

@test "control help documents the direct shelf shortcut" {
    run --separate-stderr hwe control help
    assert_success
    [[ "$stderr" == *"usage: hwe control"* ]]
    [[ "$stderr" == *"SUPER+SHIFT+Up"* ]]
}

@test "control rejects stray arguments instead of toggling" {
    run --separate-stderr hwe control unexpected
    assert_failure
    [[ "$stderr" == *"takes no arguments"* ]]
}

@test "a second control invocation closes the running shelf" {
    run bash -c '
        set -euo pipefail
        source "$HWE_ROOT/lib/common.sh"
        source "$HWE_ROOT/lib/control.sh"
        pgrep() { return 0; }
        pkill() { printf "stop:%s\n" "$*"; }
        control_main
    '
    assert_success
    assert_output --partial "stop:-USR1 -f ^python3 $HWE_ROOT/scripts/control_shelf.py$"
}

@test "the shelf shortcut does not steal focus or window movement" {
    run grep -F 'bind("SUPER + SHIFT + Up", hl.dsp.exec_cmd("hwe control")' "$HWE_ROOT/config/hypr/keybindings.lua"
    assert_success
    run grep -F 'bind("SUPER + " .. key, hl.dsp.focus' "$HWE_ROOT/config/hypr/keybindings.lua"
    assert_success
    run grep -F 'bind("SUPER + CTRL + " .. key, hl.dsp.window.move' "$HWE_ROOT/config/hypr/keybindings.lua"
    assert_success
}
