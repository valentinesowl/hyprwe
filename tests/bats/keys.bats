#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
    load 'helper'
    hwe_setup
}

@test "keys renders real JSON binds with modmasks and descriptions" {
    run bash -c 'printf "%s\n" "$1" | python3 "$HWE_ROOT/scripts/keybinds.py"' _ \
        '[{"modmask":64,"key":"Q","dispatcher":"__lua","description":"Close window"},{"modmask":0,"key":"Print","dispatcher":"__lua","description":"Whole screen to clipboard"}]'
    assert_success
    assert_output --partial "SUPER + Q"
    assert_output --partial "Close window"
    assert_output --partial "Whole screen to clipboard"
}

@test "keys collapses workspaces and arrows and skips media" {
    local fixture='['
    fixture+='{"modmask":64,"key":"1","description":"Switch to workspace 1"},'
    fixture+='{"modmask":64,"key":"2","description":"Switch to workspace 2"},'
    fixture+='{"modmask":64,"key":"left","description":"Move focus left"},'
    fixture+='{"modmask":64,"key":"right","description":"Move focus right"},'
    fixture+='{"modmask":0,"key":"XF86AudioPlay","description":"Play media"}]'
    run bash -c 'printf "%s\n" "$1" | python3 "$HWE_ROOT/scripts/keybinds.py"' _ "$fixture"
    assert_success
    [[ "$(grep -c 'Switch to workspace' <<<"$output")" == 1 ]]
    [[ "$(grep -c 'Move focus' <<<"$output")" == 1 ]]
    refute_output --partial "Play media"
    assert_output --partial "1…0"
    assert_output --partial "← ↑ ↓ →"
}

@test "keys rejects malformed hyprctl output loudly" {
    run bash -c 'printf "not json" | python3 "$HWE_ROOT/scripts/keybinds.py"'
    assert_failure
    assert_output --partial "invalid hyprctl JSON"
}
