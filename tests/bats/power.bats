#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
    load 'helper'
    hwe_setup
    export HWE_REPO_ROOT="$HWE_ROOT"
}

power_fn() {
    bash -c '
        set -euo pipefail
        HWE_ROOT="$HWE_REPO_ROOT"
        source "$HWE_ROOT/lib/common.sh"
        source "$HWE_ROOT/lib/power.sh"
        pgrep() { return 1; }
        need() { :; }
        rofi() {
            local input
            input="$(cat)"
            if [[ "$input" == *"Confirm "* ]]; then
                printf "%s\n" "$CONFIRM_REPLY"
                return "${CONFIRM_RC:-0}"
            fi
            printf "%s\n" "$POWER_CHOICE"
        }
        systemctl() { printf "systemctl:%s\n" "$*"; }
        hyprlock() { echo hyprlock; }
        _power_logout() { echo logout; }
        power_main
    ' _
}

@test "shutdown cancellation runs no system command" {
    POWER_CHOICE=Shutdown CONFIRM_REPLY=Cancel run power_fn
    assert_success
    refute_output --partial "systemctl:"
    assert_output --partial "Shutdown cancelled"
}

@test "closing the confirmation menu cancels reboot" {
    POWER_CHOICE=Reboot CONFIRM_REPLY= CONFIRM_RC=1 run power_fn
    assert_success
    refute_output --partial "systemctl:"
    assert_output --partial "Reboot cancelled"
}

@test "confirmed shutdown runs exactly one poweroff" {
    POWER_CHOICE=Shutdown CONFIRM_REPLY="Confirm Shutdown" run power_fn
    assert_success
    assert_output "systemctl:poweroff"
}

@test "confirmed reboot runs exactly one reboot" {
    POWER_CHOICE=Reboot CONFIRM_REPLY="Confirm Reboot" run power_fn
    assert_success
    assert_output "systemctl:reboot"
}

@test "logout also requires confirmation" {
    POWER_CHOICE=Logout CONFIRM_REPLY=Cancel run power_fn
    assert_success
    refute_output --partial "logout"
}

@test "suspend and lock stay one-step actions" {
    POWER_CHOICE=Suspend run power_fn
    assert_success
    assert_output "systemctl:suspend"
    POWER_CHOICE=Lock run power_fn
    assert_success
    assert_output "hyprlock"
}
