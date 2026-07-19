#!/usr/bin/env bats
# lib/distro.sh — the layer that knows HWE runs on more than Arch.
#
# The detection and the name map are pure functions of their inputs, so they are
# tested here in full. The _pm_* verbs shell out to a real package manager and
# belong to the VM.

bats_require_minimum_version 1.5.0

setup() {
    load 'helper'
    hwe_setup
    export HWE_REPO_ROOT="$HWE_ROOT"
}

# Subshell, as everywhere: common.sh defines its own `run`.
distro_fn() {
    bash -c '
        set -euo pipefail
        HWE_ROOT="$HWE_REPO_ROOT"
        source "$HWE_ROOT/lib/common.sh"
        fn="$1"; shift
        "$fn" "$@"
    ' _ "$@"
}

# ── detection ─────────────────────────────────────────────────────────────
@test "an explicit HWE_DISTRO is respected" {
    HWE_DISTRO=debian run distro_fn _distro_family
    assert_success
    assert_output "apt"
}

@test "arch maps to pacman, ubuntu and debian to apt" {
    HWE_DISTRO=arch   run distro_fn _distro_family; assert_output "pacman"
    HWE_DISTRO=debian run distro_fn _distro_family; assert_output "apt"
}

@test "an unknown distro is refused, and the message names it" {
    HWE_DISTRO=plan9 run distro_fn _distro_supported
    assert_failure
    assert_output --partial "plan9"
}

@test "arch and debian are both supported" {
    HWE_DISTRO=arch   run distro_fn _distro_supported; assert_success
    HWE_DISTRO=debian run distro_fn _distro_supported; assert_success
}

# ── name translation ──────────────────────────────────────────────────────
translate() {
    printf '%s\n' "$@" | HWE_DISTRO=debian distro_fn _pm_translate
}

@test "an unmapped name passes through unchanged" {
    # The common case: 65 of our 96 packages are spelled the same on both sides.
    run translate hyprland waybar kitty
    assert_success
    assert_output $'hyprland\nwaybar\nkitty'
}

@test "a renamed package becomes its local name" {
    run translate mako
    assert_output "mako-notifier"
}

@test "one name can map to several packages" {
    run translate openssh
    assert_output $'openssh-client\nopenssh-server'
}

@test "a package marked '-' is dropped, not passed through" {
    run translate pacman-contrib
    assert_success
    assert_output ""
}

@test "translation preserves order and mixes mapped with unmapped" {
    run translate kitty polkit waybar
    assert_output $'kitty\npolkitd\nwaybar'
}

@test "on arch nothing is translated at all" {
    # There is no pkg/map/pacman.map: Arch names ARE the canonical vocabulary, so
    # translation there must be an exact pass-through, drops included.
    printf 'mako\npacman-contrib\n' > "$BATS_TEST_TMPDIR/in"
    run bash -c "
        export HWE_REPO_ROOT='$HWE_ROOT' HWE_DISTRO=arch
        $(declare -f distro_fn)
        distro_fn _pm_translate < '$BATS_TEST_TMPDIR/in'"
    assert_success
    assert_output $'mako\npacman-contrib'
}

# ── the map as a document ─────────────────────────────────────────────────
@test "every mapped name is one HWE actually asks for" {
    # A map entry for a package no list names is dead weight — and usually a typo
    # in the Arch name, which would silently do nothing.
    local lists; lists="$(cat "$HWE_ROOT"/pkg/*.lst)"
    local from
    while IFS=$'\t' read -r from _; do
        [[ -z "$from" || "$from" == \#* ]] && continue
        grep -qE "^[[:space:]]*${from}([[:space:]]|#|$)" <<<"$lists" \
            || fail "apt.map maps '$from', which no pkg/*.lst names"
    done < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$HWE_ROOT/pkg/map/apt.map")
}

@test "the map has no duplicate left-hand sides" {
    run bash -c "sed -e 's/#.*//' -e '/^[[:space:]]*\$/d' '$HWE_ROOT/pkg/map/apt.map' \
                 | cut -f1 | sort | uniq -d"
    assert_success
    assert_output ""
}

@test "every nerd font is mapped, since none are packaged" {
    # Leaving one unmapped would try to apt-install an Arch font name and fail
    # the whole transaction.
    local f
    for f in $(grep -oE '^(ttf|otf)-[a-z0-9-]+-nerd' "$HWE_ROOT/pkg/core.lst"); do
        grep -qP "^\Q$f\E\t" "$HWE_ROOT/pkg/map/apt.map" || fail "$f is not in apt.map"
    done
}
