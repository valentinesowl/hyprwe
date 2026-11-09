#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
    load 'helper'
    hwe_setup
    export HWE_REPO_ROOT="$HWE_ROOT"
}

hypr_fn() {
    bash -c '
        set -euo pipefail
        HWE_ROOT="$HWE_REPO_ROOT"
        source "$HWE_ROOT/lib/common.sh"
        fn="$1"; shift
        "$fn" "$@"
    ' _ "$@"
}

@test "version comparison accepts 0.57 and rejects the legacy series" {
    run hypr_fn _hypr_version_at_least 0.57.0
    assert_success
    run hypr_fn _hypr_version_at_least 0.57.1
    assert_success
    run hypr_fn _hypr_version_at_least 0.56.9
    assert_failure
}

@test "installed version is parsed from hyprctl when the binary is unavailable" {
    local fakebin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$fakebin"
    printf '#!/usr/bin/env bash\nprintf "Hyprland 0.57.1 built from branch main\\n"\n' > "$fakebin/hyprctl"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/Hyprland"
    chmod +x "$fakebin/hyprctl" "$fakebin/Hyprland"
    PATH="$fakebin:$PATH" run hypr_fn _hypr_installed_version
    assert_output "0.57.1"
}

@test "an old installed compositor is refused before reconciliation" {
    local fakebin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$fakebin"
    printf '#!/usr/bin/env bash\nprintf "Hyprland 0.53.3 built from branch stable\\n"\n' > "$fakebin/hyprctl"
    printf '#!/usr/bin/env bash\nprintf "Hyprland 0.53.3 built from branch stable\\n"\n' > "$fakebin/Hyprland"
    chmod +x "$fakebin/hyprctl" "$fakebin/Hyprland"
    PATH="$fakebin:$PATH" run hypr_fn _hypr_require_installed
    assert_failure
    assert_output --partial "0.53.3"
    assert_output --partial "legacy-conf"
}

@test "pacman candidate strips the package release" {
    local fakebin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$fakebin"
    printf '#!/usr/bin/env bash\nprintf "Version         : 0.57.1-2\\n"\n' > "$fakebin/pacman"
    chmod +x "$fakebin/pacman"
    PATH="$fakebin:$PATH" HWE_DISTRO=arch run hypr_fn _hypr_candidate_version
    assert_output "0.57.1"
}

@test "apt candidate strips an epoch" {
    local fakebin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$fakebin"
    printf '#!/usr/bin/env bash\nprintf "  Installed: (none)\\n  Candidate: 1:0.57.0-1ubuntu1\\n"\n' > "$fakebin/apt-cache"
    chmod +x "$fakebin/apt-cache"
    PATH="$fakebin:$PATH" HWE_DISTRO=debian run hypr_fn _hypr_candidate_version
    assert_output "0.57.0"
}

@test "a missing apt candidate is an error, not a silent pass" {
    local fakebin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$fakebin"
    printf '#!/usr/bin/env bash\nprintf "  Candidate: (none)\\n"\n' > "$fakebin/apt-cache"
    chmod +x "$fakebin/apt-cache"
    PATH="$fakebin:$PATH" HWE_DISTRO=debian run hypr_fn _hypr_require_candidate
    assert_failure
    assert_output --partial "required"
}

@test "installed version discovers the instance without caller session env" {
    local fakebin="$BATS_TEST_TMPDIR/bin" runtime="$BATS_TEST_TMPDIR/runtime"
    mkdir -p "$fakebin" "$runtime/hypr/test-sig"
    printf '#!/usr/bin/env bash\n[[ "${HYPRLAND_INSTANCE_SIGNATURE:-}" == test-sig ]] || exit 1\nprintf "Hyprland 0.57.1 built from branch main\\n"\n' > "$fakebin/hyprctl"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/Hyprland"
    chmod +x "$fakebin/hyprctl" "$fakebin/Hyprland"
    PATH="$fakebin:$PATH" HYPRLAND_INSTANCE_SIGNATURE= XDG_RUNTIME_DIR="$runtime" \
        run hypr_fn _hypr_installed_version
    assert_success
    assert_output "0.57.1"
}

@test "installed version falls back to the binary without a running session" {
    local fakebin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$fakebin"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/hyprctl"
    printf '#!/usr/bin/env bash\nprintf "Hyprland 0.57.1 built from branch main\\n"\n' > "$fakebin/Hyprland"
    chmod +x "$fakebin/hyprctl" "$fakebin/Hyprland"
    PATH="$fakebin:$PATH" HYPRLAND_INSTANCE_SIGNATURE= XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/empty" \
        run hypr_fn _hypr_installed_version
    assert_success
    assert_output "0.57.1"
}

@test "an upgraded binary is not masked by the old running session" {
    local fakebin="$BATS_TEST_TMPDIR/bin" runtime="$BATS_TEST_TMPDIR/runtime"
    mkdir -p "$fakebin" "$runtime/hypr/test-sig"
    printf '#!/usr/bin/env bash\n[[ "${HYPRLAND_INSTANCE_SIGNATURE:-}" == test-sig ]] || exit 1\nprintf "Hyprland 0.56.2 built from branch stable\\n"\n' > "$fakebin/hyprctl"
    printf '#!/usr/bin/env bash\nprintf "Hyprland 0.57.2 built from branch stable\\n"\n' > "$fakebin/Hyprland"
    chmod +x "$fakebin/hyprctl" "$fakebin/Hyprland"
    PATH="$fakebin:$PATH" HYPRLAND_INSTANCE_SIGNATURE= XDG_RUNTIME_DIR="$runtime" \
        run hypr_fn _hypr_installed_version
    assert_success
    assert_output "0.57.2"
}

@test "config verifier accepts a clean Lua config without leaking debug output" {
    local fakebin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$fakebin"
    printf '#!/usr/bin/env bash\nprintf "\\033[1;32mDEBUG\\033[0m: setup\\n======== Config parsing result:\\n\\nconfig ok\\n"\n' > "$fakebin/Hyprland"
    chmod +x "$fakebin/Hyprland"
    PATH="$fakebin:$PATH" run hypr_fn _hypr_verify_config
    assert_success
    assert_output ""
}

@test "config verifier returns Lua parser errors and strips colours and noise" {
    local fakebin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$fakebin"
    printf '#!/usr/bin/env bash\nprintf "\\033[1;32mDEBUG\\033[0m: setup\\n======== Config parsing result:\\n\\n/home/hwe/.config/hypr/theme.lua:33: bezier or spring is required\\n"\nexit 1\n' > "$fakebin/Hyprland"
    chmod +x "$fakebin/Hyprland"
    PATH="$fakebin:$PATH" run hypr_fn _hypr_verify_config
    assert_failure
    assert_output "/home/hwe/.config/hypr/theme.lua:33: bezier or spring is required"
    refute_output --partial "DEBUG"
}
