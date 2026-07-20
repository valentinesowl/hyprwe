#!/usr/bin/env bats
# lib/checkconfig.sh — the "is the Hyprland config clean?" predicate.
#
# checkconfig runs at every login and doctor runs on demand; both must agree on
# what a clean result looks like, or a version that prints "no errors" instead of
# nothing raises a red login notification while doctor calls the same config fine.

bats_require_minimum_version 1.5.0

setup() {
    load 'helper'
    hwe_setup
    export HWE_REPO_ROOT="$HWE_ROOT"
}

clean_fn() {
    bash -c '
        set -euo pipefail
        HWE_ROOT="$HWE_REPO_ROOT"
        source "$HWE_ROOT/lib/common.sh"
        source "$HWE_ROOT/lib/checkconfig.sh"
        if _hypr_config_clean "$1"; then echo CLEAN; else echo DIRTY; fi
    ' _ "$@"
}

@test "empty output is clean" {
    run clean_fn ""
    assert_output "CLEAN"
}

@test "a build that says 'no errors' is clean" {
    run clean_fn "no errors"
    assert_output "CLEAN"
}

@test "an actual error is not clean" {
    run clean_fn "Config error in line 3: unknown keyword"
    assert_output "DIRTY"
}

@test "doctor uses the predicate and actually sources it from checkconfig" {
    # checkconfig defines it; doctor must both source the file and call it, or the
    # two drift apart again.
    grep -q '_hypr_config_clean()' "$HWE_ROOT/lib/checkconfig.sh"
    grep -q '_hypr_config_clean "\$errs"' "$HWE_ROOT/lib/doctor.sh"
    grep -q 'source "\$HWE_ROOT/lib/checkconfig.sh"' "$HWE_ROOT/lib/doctor.sh"
}
