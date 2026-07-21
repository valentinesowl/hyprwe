#!/usr/bin/env bats
# The personal layer — ~/.config/hwe, the settings that are the user's and not
# the repo's (lib/common.sh: HWE_USER_CONFIG).
#
# Two properties carry the whole design and both are tested here: the layer is
# CREATED so an empty machine shows you where your settings go, and it is NEVER
# OVERWRITTEN, so an update cannot cost you them. Everything runs against a
# throwaway HWE_USER_CONFIG — nothing here touches the real ~/.config.

bats_require_minimum_version 1.5.0

setup() {
    load 'helper'
    hwe_setup

    export HWE_REPO_ROOT="$HWE_ROOT"
    export USER_CONFIG="$BATS_TEST_TMPDIR/userconfig"
    export SKEL="$HWE_ROOT/provision/userlayer"
    # The bridge is deploy output written next to HWE_ROOT — scratch it, so a
    # test run never plants a symlink in the real checkout.
    export HWE_SUNSET_BRIDGE="$BATS_TEST_TMPDIR/bridge.conf"
}

# Call an install/doctor function against the scratch layer, in a subshell: both
# lib/common.sh and guest-install.sh define their own `run`, which would shadow
# bats' `run` for the rest of the file if sourced here.
hwe_fn() {
    bash -c '
        set -euo pipefail
        HWE_ROOT="$HWE_REPO_ROOT"
        HWE_USER_CONFIG="$USER_CONFIG"
        export HWE_USER_CONFIG
        source "$HWE_ROOT/lib/common.sh"
        HWE_INSTALL_STANDALONE=1 source "$HWE_ROOT/provision/guest-install.sh"
        source "$HWE_ROOT/lib/doctor.sh"
        fn="$1"; shift
        "$fn" "$@"
    ' _ "$@"
}

# ── creation ──────────────────────────────────────────────────────────────
@test "deploy creates every skeleton file in the layer" {
    run hwe_fn _deploy_user_layer
    assert_success
    for f in "$SKEL"/*; do
        [[ -f "$USER_CONFIG/${f##*/}" ]] || fail "missing ${f##*/} in the deployed layer"
    done
}

@test "the deployed files are the skeletons verbatim" {
    hwe_fn _deploy_user_layer
    for f in "$SKEL"/*; do
        run cmp -s "$f" "$USER_CONFIG/${f##*/}"
        assert_success
    done
}

@test "deploy is idempotent and silent on the second run" {
    hwe_fn _deploy_user_layer
    run hwe_fn _deploy_user_layer
    assert_success
    refute_output --partial "created"
}

# ── the file is yours ─────────────────────────────────────────────────────
@test "an edited file is never overwritten" {
    hwe_fn _deploy_user_layer
    printf 'monitor = eDP-1, 2560x1600@165, 0x0, 1.6\n' > "$USER_CONFIG/hypr.conf"
    run hwe_fn _deploy_user_layer
    assert_success
    run cat "$USER_CONFIG/hypr.conf"
    assert_output --partial "eDP-1"
}

@test "a deleted file is recreated, the others left alone" {
    hwe_fn _deploy_user_layer
    printf '# mine\nmpv\n' > "$USER_CONFIG/packages.lst"
    rm -f "$USER_CONFIG/hypr.conf"

    run hwe_fn _deploy_user_layer
    assert_success
    assert_output --partial "hypr.conf"
    refute_output --partial "packages.lst"
    run cat "$USER_CONFIG/packages.lst"
    assert_output --partial "mpv"
}

# ── package lists ─────────────────────────────────────────────────────────
@test "the skeleton package lists parse as empty" {
    # Every line is a comment, so a fresh machine asks to install nothing.
    hwe_fn _deploy_user_layer
    run hwe_fn _pkgs_user packages.lst
    assert_success
    assert_output ""
    run hwe_fn _pkgs_user packages-aur.lst
    assert_output ""
}

@test "a user list yields its packages, comments stripped" {
    mkdir -p "$USER_CONFIG"
    printf '# stuff I want\nmpv\nthunderbird   # mail\n\n' > "$USER_CONFIG/packages.lst"
    run hwe_fn _pkgs_user packages.lst
    assert_success
    assert_output $'mpv\nthunderbird'
}

@test "a missing user list is an empty list, not an error" {
    run hwe_fn _pkgs_user packages.lst
    assert_success
    assert_output ""
}

@test "the AUR set is HWE's list plus yours" {
    mkdir -p "$USER_CONFIG"
    printf 'spotify\n' > "$USER_CONFIG/packages-aur.lst"
    run hwe_fn _aur_wanted
    assert_success
    assert_output --partial "spotify"
}

# ── doctor ────────────────────────────────────────────────────────────────
@test "doctor reports an untouched layer as ok" {
    hwe_fn _deploy_user_layer
    run hwe_fn _doctor_user_layer
    assert_success
    assert_output --partial "untouched defaults"
}

@test "doctor counts your own files without calling them drift" {
    hwe_fn _deploy_user_layer
    printf 'monitor = eDP-1, preferred, auto, 1.6\n' > "$USER_CONFIG/hypr.conf"
    run hwe_fn _doctor_user_layer
    assert_success
    assert_output --partial "1 file(s) of your own"
}

@test "doctor fails on a missing hypr.conf and says why it matters" {
    hwe_fn _deploy_user_layer
    rm -f "$USER_CONFIG/hypr.conf"
    run hwe_fn _doctor_user_layer
    assert_failure
    assert_output --partial "hypr.conf"
    assert_output --partial "config error"
}

@test "doctor fails on a layer that was never deployed" {
    run hwe_fn _doctor_user_layer
    assert_failure
    assert_output --partial "hwe update"
}

# ── defaults that can still evolve (userlayer.sums) ───────────────────────
# A scratch skeleton + hash history simulates a default changing between
# releases; HWE_USER_SKEL/HWE_USER_SUMS are overridable for exactly this.

_scratch_skel() {
    export HWE_USER_SKEL="$BATS_TEST_TMPDIR/skel"
    export HWE_USER_SUMS="$BATS_TEST_TMPDIR/skel.sums"
    mkdir -p "$HWE_USER_SKEL"
    printf '# default v1\n' > "$HWE_USER_SKEL/thing.conf"
    sha256sum "$HWE_USER_SKEL/thing.conf" | sed "s|$HWE_USER_SKEL/||" > "$HWE_USER_SUMS"
}

_scratch_skel_evolve() {
    printf '# default v2\n' > "$HWE_USER_SKEL/thing.conf"
    sha256sum "$HWE_USER_SKEL/thing.conf" | sed "s|$HWE_USER_SKEL/||" >> "$HWE_USER_SUMS"
}

@test "an untouched default follows a new shipped default" {
    _scratch_skel
    hwe_fn _deploy_user_layer
    _scratch_skel_evolve
    run hwe_fn _deploy_user_layer
    assert_success
    assert_output --partial "refreshed"
    run cat "$USER_CONFIG/thing.conf"
    assert_output --partial "v2"
}

@test "an edited file stays yours even when the default moves on" {
    _scratch_skel
    hwe_fn _deploy_user_layer
    printf '# mine\n' > "$USER_CONFIG/thing.conf"
    _scratch_skel_evolve
    run hwe_fn _deploy_user_layer
    assert_success
    refute_output --partial "refreshed"
    run cat "$USER_CONFIG/thing.conf"
    assert_output --partial "mine"
}

@test "--reset-defaults restores the shipped file and keeps yours as a backup" {
    _scratch_skel
    hwe_fn _deploy_user_layer
    printf '# mine\n' > "$USER_CONFIG/thing.conf"
    HWE_RESET_DEFAULTS=1 run hwe_fn _deploy_user_layer
    assert_success
    assert_output --partial "reset"
    run cat "$USER_CONFIG/thing.conf"
    assert_output --partial "v1"
    run cat "$USER_CONFIG"/thing.conf.hwe-bak.*
    assert_output --partial "mine"
}

@test "--reset-defaults leaves an untouched layer alone — no backup spam" {
    _scratch_skel
    hwe_fn _deploy_user_layer
    HWE_RESET_DEFAULTS=1 run hwe_fn _deploy_user_layer
    assert_success
    refute_output --partial "reset"
    run bash -c "ls \"$USER_CONFIG\"/*.hwe-bak.* 2>/dev/null | wc -l"
    assert_output "0"
}

@test "every current skeleton is in the shipped hash history" {
    # The refresh mechanism dies silently if a skeleton edit forgets its hash:
    # that file's fresh installs would read as "edited by the user" forever.
    # `just skel-sums` appends what this test says is missing.
    local h f
    while read -r h f; do
        grep -q "^$h  $f\$" "$HWE_ROOT/provision/userlayer.sums" \
            || fail "provision/userlayer.sums lacks the current $f — run: just skel-sums"
    done < <(cd "$HWE_ROOT/provision/userlayer" && sha256sum -- *)
}

# ── the contract with the rest of the repo ────────────────────────────────
@test "hyprland.conf sources the personal hypr.conf" {
    # The source line and the deploy path have to agree: Hyprland reports a
    # missing source as a config error, and doctor would then blame the user.
    run grep -qF 'source = ~/.config/hwe/hypr.conf' "$HWE_ROOT/config/hypr/hyprland.conf"
    assert_success
}

@test "no tracked config file tells the user to edit the repo for their monitors" {
    # monitors.conf is a symlink into the checkout: editing it dirties the tree
    # and blocks the ff-only pull. It must point at the personal layer instead.
    run grep -qF '~/.config/hwe/hypr.conf' "$HWE_ROOT/config/hypr/monitors.conf"
    assert_success
}

@test "the waybar skeleton survives the merge it is written for" {
    # It ships with comments and an empty object: valid JSONC, and a no-op merge.
    local gen="$BATS_TEST_TMPDIR/config.jsonc"
    printf '{"layer": "top", "modules-right": ["clock"]}\n' > "$gen"
    run python3 "$HWE_ROOT/scripts/wbmerge.py" "$gen" "$SKEL/waybar.jsonc"
    assert_success
    assert_output --partial '"clock"'
}
