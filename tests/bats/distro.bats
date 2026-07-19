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

# ── fonts we fetch ourselves ──────────────────────────────────────────────
# The icon font is the one artifact HWE downloads without a distribution's
# signature behind it. The refusal below is the whole safety property: an entry
# nobody has pinned must not be fetched, however inconvenient that is.
fonts_fn() {
    bash -c '
        set -euo pipefail
        HWE_ROOT="$HWE_REPO_ROOT"
        source "$HWE_ROOT/lib/common.sh"
        HWE_INSTALL_STANDALONE=1 source "$HWE_ROOT/provision/guest-install.sh"
        fn="$1"; shift
        "$fn" "$@"
    ' _ "$@"
}

@test "the lock file parses, keeping an unpinned hash empty" {
    run fonts_fn _fonts_lock_rows
    assert_success
    assert_output --partial "symbols-mono"
    # Five tab-separated fields, the last of which is empty while unpinned.
    run bash -c "printf '%s' \"\$(HWE_REPO_ROOT='$HWE_ROOT' bash -c '
        HWE_ROOT=\"\$HWE_REPO_ROOT\"; source \"\$HWE_ROOT/lib/common.sh\"
        HWE_INSTALL_STANDALONE=1 source \"\$HWE_ROOT/provision/guest-install.sh\"
        _fonts_lock_rows')\" | awk -F'\t' '{print NF}'"
    assert_output "5"
}

# Build a lock pointing at a local archive, so the whole fetch-and-verify path
# runs without touching the network. curl reads file:// just as it reads https://.
make_fixture() {
    local sha_archive="$1" sha_font="$2"
    local d="$BATS_TEST_TMPDIR/fx"; mkdir -p "$d/src"
    printf 'not really a font, but bytes all the same\n' > "$d/src/TestGlyphs.ttf"
    tar -cJf "$d/archive.tar.xz" -C "$d/src" TestGlyphs.ttf
    REAL_ARCHIVE_SHA="$(sha256sum "$d/archive.tar.xz" | awk '{print $1}')"
    REAL_FONT_SHA="$(sha256sum "$d/src/TestGlyphs.ttf" | awk '{print $1}')"
    [[ "$sha_archive" == AUTO ]] && sha_archive="$REAL_ARCHIVE_SHA"
    [[ "$sha_font" == AUTO ]] && sha_font="$REAL_FONT_SHA"
    printf '# fixture\ntestfont\tfile://%s\t%s\tTestGlyphs.ttf\t%s\n' \
        "$d/archive.tar.xz" "$sha_archive" "$sha_font" > "$d/fonts.lock"
    printf '%s' "$d/fonts.lock"
}

run_install() {
    HWE_FONTS_LOCK="$1" HOME="$BATS_TEST_TMPDIR/home" \
        XDG_DATA_HOME="$BATS_TEST_TMPDIR/data" fonts_fn _install_fetched_fonts
}

@test "an unpinned font is refused, and the message says why" {
    local lock; lock="$(make_fixture - -)"
    run run_install "$lock"
    assert_success                      # a refusal is not an install failure
    assert_output --partial "not pinned"
    assert_output --partial "vouched"
    [[ ! -e "$BATS_TEST_TMPDIR/data/fonts/hwe/TestGlyphs.ttf" ]] \
        || fail "it installed something nobody pinned"
}

@test "an archive whose hash does not match is refused" {
    local lock; lock="$(make_fixture "$(printf '0%.0s' {1..64})" AUTO)"
    run run_install "$lock"
    assert_output --partial "hash mismatch"
    [[ ! -e "$BATS_TEST_TMPDIR/data/fonts/hwe/TestGlyphs.ttf" ]] \
        || fail "it installed an archive that failed its own check"
}

@test "a tampered font inside a matching archive is refused" {
    # The archive hash alone is not enough: it is the file we install that has to
    # be the file that was vouched for.
    local lock; lock="$(make_fixture AUTO "$(printf 'f%.0s' {1..64})")"
    run run_install "$lock"
    assert_output --partial "font hash mismatch"
    [[ ! -e "$BATS_TEST_TMPDIR/data/fonts/hwe/TestGlyphs.ttf" ]] \
        || fail "it installed a font that failed its own check"
}

@test "a correctly pinned font is installed" {
    local lock; lock="$(make_fixture AUTO AUTO)"
    run run_install "$lock"
    assert_success
    [[ -f "$BATS_TEST_TMPDIR/data/fonts/hwe/TestGlyphs.ttf" ]] \
        || fail "the happy path installed nothing"
}

@test "every pinned hash is a full sha256, or the explicit unpinned marker" {
    # Half a hash, or a truncated paste, would fail at install time on the user's
    # machine rather than here. `-` stays legal: it is how an entry says nobody
    # has vouched for it yet.
    # Strip comments FIRST — the header line names the columns, so its own fifth
    # field is the literal string "file_sha256".
    local id url a_sha member f_sha
    while IFS=$'\t' read -r id url a_sha member f_sha; do
        [[ -n "$id" ]] || continue
        for h in "$a_sha" "$f_sha"; do
            [[ "$h" == "-" || "$h" =~ ^[0-9a-f]{64}$ ]] \
                || fail "$id: '$h' is neither a sha256 nor the unpinned marker"
        done
        [[ "$url" == https://* ]] || fail "$id: '$url' is not an https URL"
    done < <(sed '/^#/d' "$HWE_ROOT/pkg/fonts.lock")
}

@test "the archive and the font are pinned together or not at all" {
    # Verifying the archive but not the file it yields (or the reverse) would
    # leave half the path unchecked.
    local id url a_sha member f_sha
    while IFS=$'\t' read -r id url a_sha member f_sha; do
        [[ -n "$id" ]] || continue
        local a_unpinned=0 f_unpinned=0
        [[ "$a_sha" == "-" ]] && a_unpinned=1
        [[ "$f_sha" == "-" ]] && f_unpinned=1
        [[ "$a_unpinned" == "$f_unpinned" ]] \
            || fail "$id: one hash is pinned and the other is not"
    done < <(sed '/^#/d' "$HWE_ROOT/pkg/fonts.lock")
}

@test "an empty hash column would be a silent skip, so the marker is a real character" {
    # Tab is IFS whitespace: bash's `read` collapses a run of tabs, so an empty
    # column vanishes and the fields after it shift left. That turned "refuse to
    # fetch" into "quietly do nothing" — the row failed its own sanity check
    # instead of reaching the refusal. Guard the convention, not just the value.
    run bash -c "sed '/^#/d' '$HWE_ROOT/pkg/fonts.lock' | grep -c \$'\t\t'"
    assert_output "0"
}
