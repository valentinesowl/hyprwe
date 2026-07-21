#!/usr/bin/env bats
# lib/wall.sh — name resolution in `hwe wall set`.
#
# The compositor side (hyprpaper, the live swap) is out of scope; what IS
# testable anywhere is which FILE a name resolves to — in particular that a
# stem two files answer to (sunset.jpg beside sunset.png) is refused with both
# named, not resolved to whichever `sort` happens to put first.

bats_require_minimum_version 1.5.0

setup() {
    load 'helper'
    hwe_setup

    export HWE_REPO_ROOT="$HWE_ROOT"
    # Scratch user layer: the remembered-choice marker lives there now, and a
    # test run must never write into the real ~/.config of whoever runs it.
    export HWE_USER_CONFIG="$BATS_TEST_TMPDIR/user-config"
    THEME_DIR="$BATS_TEST_TMPDIR/theme"
    mkdir -p "$THEME_DIR/wallpapers"
    printf 'jpg\n' > "$THEME_DIR/wallpapers/sunset.jpg"
    printf 'png\n' > "$THEME_DIR/wallpapers/sunset.png"
    printf 'png\n' > "$THEME_DIR/wallpapers/dawn.png"
    printf 'png\n' > "$THEME_DIR/wallpaper.png"   # the generated fallback
    export THEME_DIR
}

# Subshell for the same reason as vm.bats: common.sh defines its own `run`,
# which would shadow bats' `run` if sourced into this file. The activation
# side is stubbed to print its target — the test is about resolution only.
hwe_wall() {
    bash -c '
        set -euo pipefail
        HWE_ROOT="$HWE_REPO_ROOT"
        source "$HWE_ROOT/lib/common.sh"
        source "$HWE_ROOT/lib/wall.sh"
        _theme_dir() { printf "%s\n" "$THEME_DIR"; }
        _wall_theme() { echo testtheme; }
        _wall_activate() { echo "activate:$1"; }
        _wall_remember() { :; }
        fn="$1"; shift
        "$fn" "$@"
    ' _ "$@"
}

@test "an unambiguous stem resolves to its one file" {
    run hwe_wall wall_set dawn
    assert_success
    [[ "$output" == *"activate:$THEME_DIR/wallpapers/dawn.png"* ]]
}

@test "a stem shared by two files is refused with both named" {
    run hwe_wall wall_set sunset
    assert_failure
    [[ "$output" == *"ambiguous"* ]]
    [[ "$output" == *"sunset.jpg"* ]]
    [[ "$output" == *"sunset.png"* ]]
    [[ "$output" != *"activate:"* ]]
}

@test "the full basename stays an exact, unambiguous answer" {
    run hwe_wall wall_set sunset.png
    assert_success
    [[ "$output" == *"activate:$THEME_DIR/wallpapers/sunset.png"* ]]
}

@test "an unknown name is not found, not silently defaulted" {
    run hwe_wall wall_set nothere
    assert_failure
    [[ "$output" == *"wallpaper not found"* ]]
}

# --- the remembered choice's move out of the checkout (1.3.2) ----------------

@test "a wallpaper choice from before the move migrates to the user layer" {
    printf '%s\n' "$THEME_DIR/wallpapers/dawn.png" > "$THEME_DIR/.current_wallpaper"
    run hwe_wall _wall_default testtheme
    assert_success
    assert_output "$THEME_DIR/wallpapers/dawn.png"
    run cat "$HWE_USER_CONFIG/themes/testtheme/wallpapers/.current_wallpaper"
    assert_output "$THEME_DIR/wallpapers/dawn.png"
}

@test "the user-layer wallpaper choice wins over a stale checkout one" {
    mkdir -p "$HWE_USER_CONFIG/themes/testtheme/wallpapers"
    printf '%s\n' "$THEME_DIR/wallpapers/dawn.png"   > "$HWE_USER_CONFIG/themes/testtheme/wallpapers/.current_wallpaper"
    printf '%s\n' "$THEME_DIR/wallpapers/sunset.png" > "$THEME_DIR/.current_wallpaper"
    run hwe_wall _wall_default testtheme
    assert_success
    assert_output "$THEME_DIR/wallpapers/dawn.png"
}

@test "remembering a choice writes the user layer and leaves the checkout alone" {
    run bash -c '
        set -euo pipefail
        HWE_ROOT="$HWE_REPO_ROOT"
        source "$HWE_ROOT/lib/common.sh"
        source "$HWE_ROOT/lib/wall.sh"
        _theme_dir() { printf "%s\n" "$THEME_DIR"; }
        _wall_remember testtheme "$THEME_DIR/wallpapers/dawn.png"
    '
    assert_success
    run cat "$HWE_USER_CONFIG/themes/testtheme/wallpapers/.current_wallpaper"
    assert_output "$THEME_DIR/wallpapers/dawn.png"
    [[ ! -e "$THEME_DIR/.current_wallpaper" ]]
}

# ── restore actually restores ─────────────────────────────────────────────
@test "restore retries the apply until hyprpaper answers, then stops" {
    # The old code waited for the SOCKET FILE — which a dead daemon's corpse
    # satisfies while the connection is refused. The contract now is: retry the
    # apply itself until it lands. Simulated: two refusals, then success.
    printf 'img\n' > "$BATS_TEST_TMPDIR/w.png"
    ln -s "$BATS_TEST_TMPDIR/w.png" "$BATS_TEST_TMPDIR/current.wall"
    run bash -c '
        set -euo pipefail
        HWE_ROOT="$HWE_REPO_ROOT"
        source "$HWE_ROOT/lib/common.sh"
        source "$HWE_ROOT/lib/wall.sh"
        HWE_WALL_LINK="$BATS_TEST_TMPDIR/current.wall"
        XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"
        hyprpaper() { :; }              # the daemon itself is out of scope here
        n=0
        _wall_apply() { n=$((n+1)); echo "attempt $n"; [[ $n -ge 3 ]]; }
        wall_restore
    '
    assert_success
    assert_output --partial "attempt 3"
    refute_output --partial "attempt 4"
}

@test "restore gives up loudly and points at the hyprpaper log" {
    printf 'img\n' > "$BATS_TEST_TMPDIR/w.png"
    ln -s "$BATS_TEST_TMPDIR/w.png" "$BATS_TEST_TMPDIR/current.wall"
    run --separate-stderr bash -c '
        set -euo pipefail
        HWE_ROOT="$HWE_REPO_ROOT"
        source "$HWE_ROOT/lib/common.sh"
        source "$HWE_ROOT/lib/wall.sh"
        HWE_WALL_LINK="$BATS_TEST_TMPDIR/current.wall"
        XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"
        hyprpaper() { :; }
        _wall_apply() { sleep 0; return 1; }
        sleep() { :; }                   # 50 refusals should not cost 10 real seconds
        wall_restore
    '
    assert_failure
    [[ "$stderr" == *"hyprpaper.log"* ]]
}
