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
