#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
    load 'helper'
    hwe_setup
    export HWE_REPO_ROOT="$HWE_ROOT"
    export TEST_LOG="$BATS_TEST_TMPDIR/notify.log"
}

@test "notify uses mako categories and semantic urgency" {
    run bash -c '
        HWE_ROOT="$HWE_REPO_ROOT"
        source "$HWE_ROOT/lib/common.sh"
        notify-send() { printf "%s\n" "$*" >> "$TEST_LOG"; }
        notify success "Theme applied" "Restart Qt apps"
    '
    assert_success
    run cat "$TEST_LOG"
    assert_output --partial "--urgency=normal"
    assert_output --partial "category:hwe-success"
    assert_output --partial "Theme applied Restart Qt apps"
}

@test "notify never falls back to Hyprland's translucent popup" {
    run bash -c '
        HWE_ROOT="$HWE_REPO_ROOT"
        source "$HWE_ROOT/lib/common.sh"
        notify-send() { return 1; }
        hyprctl() { printf "%s\n" "$*" >> "$TEST_LOG"; }
        notify warning "Applied with warnings" "Sync SDDM"
    '
    assert_success
    [[ ! -e "$TEST_LOG" ]]
}

@test "a headless CLI notification is a successful no-op" {
    run bash -c '
        HWE_ROOT="$HWE_REPO_ROOT"
        source "$HWE_ROOT/lib/common.sh"
        notify info "CLI only"
    '
    assert_success
    assert_output ""
}
