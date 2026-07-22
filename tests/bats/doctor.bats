#!/usr/bin/env bats
# lib/doctor.sh — pure verdict helpers (the live checks run against a real machine
# and live in the VM/host, not here).

bats_require_minimum_version 1.5.0

setup() {
    load 'helper'
    hwe_setup
    export HWE_REPO_ROOT="$HWE_ROOT"
}

# Subshell: sourcing doctor.sh pulls in common.sh's `run`, which would shadow bats'.
doctor_fn() {
    bash -c '
        set -euo pipefail
        HWE_ROOT="$HWE_REPO_ROOT"
        source "$HWE_ROOT/lib/common.sh"
        source "$HWE_ROOT/lib/doctor.sh"
        fn="$1"; shift
        "$fn" "$@"
    ' _ "$@"
}

@test "a zsh login shell is ok" {
    run doctor_fn _doctor_shell_verdict /usr/bin/zsh
    assert_output "ok"
}

@test "any other shell is drift (so doctor counts it, not just warns)" {
    run doctor_fn _doctor_shell_verdict /bin/bash
    assert_output "drift"
}

@test "an unreadable shell is unknown, not drift" {
    # A blank passwd field (getent failed / env -i) must not be flagged as drift.
    run doctor_fn _doctor_shell_verdict ""
    assert_output "unknown"
}

# --- screen sharing --------------------------------------------------------

@test "a running unit is ok" {
    run doctor_fn _doctor_unit_verdict active
    assert_output "ok"
}

@test "an inactive unit is lazy — bus activation is not drift" {
    run doctor_fn _doctor_unit_verdict inactive
    assert_output "lazy"
}

@test "a failed unit is down" {
    run doctor_fn _doctor_unit_verdict failed
    assert_output "down"
}

@test "an unreadable unit state is down, not silently ok" {
    # systemctl absent/erroring yields an empty state — that must count.
    run doctor_fn _doctor_unit_verdict ""
    assert_output "down"
}

# Feed a captured `show-environment` through the verdict, stdin and all.
wayland_env_fn() {
    bash -c '
        set -euo pipefail
        HWE_ROOT="$HWE_REPO_ROOT"
        source "$HWE_ROOT/lib/common.sh"
        source "$HWE_ROOT/lib/doctor.sh"
        printf "%s\n" "$1" | _doctor_wayland_env_verdict
    ' _ "$1"
}

@test "WAYLAND_DISPLAY in the user environment is ok" {
    run wayland_env_fn $'PATH=/usr/bin\nWAYLAND_DISPLAY=wayland-1\nXDG_SEAT=seat0'
    assert_output "ok"
}

@test "a user environment without WAYLAND_DISPLAY is missing (portals start blind)" {
    # A lookalike in another variable must not satisfy the check.
    run wayland_env_fn $'PATH=/usr/bin\nSOMETHING=WAYLAND_DISPLAY=nope'
    assert_output "missing"
}
