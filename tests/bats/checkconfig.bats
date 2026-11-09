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

@test "checkconfig reports Lua errors even when configerrors is empty" {
    local fakebin="$BATS_TEST_TMPDIR/bin" runtime="$BATS_TEST_TMPDIR/runtime"
    mkdir -p "$fakebin" "$runtime/hypr/test-sig"
    printf '#!/usr/bin/env bash\n[[ "${1:-}" == configerrors ]] && exit 0\nexit 1\n' > "$fakebin/hyprctl"
    printf '#!/usr/bin/env bash\nprintf "======== Config parsing result:\\n\\n/home/hwe/.config/hypr/appearance.lua:43: bezier or spring is required\\n"\nexit 1\n' > "$fakebin/Hyprland"
    chmod +x "$fakebin/hyprctl" "$fakebin/Hyprland"
    PATH="$fakebin:$PATH" HYPRLAND_INSTANCE_SIGNATURE= XDG_RUNTIME_DIR="$runtime" \
        run bash -c '
            set -euo pipefail
            HWE_ROOT="$HWE_REPO_ROOT"
            source "$HWE_ROOT/lib/common.sh"
            source "$HWE_ROOT/lib/checkconfig.sh"
            checkconfig_main
        '
    assert_failure
    assert_output --partial "appearance.lua:43: bezier or spring is required"
    refute_output --partial "config OK"
}
