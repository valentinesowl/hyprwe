#!/usr/bin/env bats
# lib/clip.sh — `hwe clip`: the clipboard-history picker.
#
# The one behaviour worth pinning without a compositor is that cancelling the
# picker must NOT touch the clipboard. Fake cliphist/rofi/wl-copy on PATH let us
# observe whether wl-copy was reached.

bats_require_minimum_version 1.5.0

setup() {
    load 'helper'
    hwe_setup

    FAKEBIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$FAKEBIN"
    WLMARK="$BATS_TEST_TMPDIR/wl-copy.ran"

    cat > "$FAKEBIN/cliphist" <<'SH'
#!/usr/bin/env bash
case "$1" in
    list)   printf '1\tfoo\n2\tbar\n' ;;
    decode) cat ;;
    wipe)   : ;;
esac
SH
    # wl-copy records that it ran and with what — its mere presence is the failure.
    cat > "$FAKEBIN/wl-copy" <<SH
#!/usr/bin/env bash
cat > "$WLMARK"
SH
    printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/pgrep"   # no rofi already open
    chmod +x "$FAKEBIN"/*
    export FAKEBIN WLMARK HWE_REPO_ROOT="$HWE_ROOT"
}

# rofi that prints $ROFI_PICK and exits $ROFI_EXIT — a cancelled picker is
# ROFI_EXIT=1 with no output, a real pick is exit 0 with a line.
_fake_rofi() {
    cat > "$FAKEBIN/rofi" <<SH
#!/usr/bin/env bash
[[ -n "\${ROFI_PICK:-}" ]] && printf '%s\n' "\$ROFI_PICK"
exit \${ROFI_EXIT:-0}
SH
    chmod +x "$FAKEBIN/rofi"
}

run_clip() {
    run --separate-stderr bash -c '
        set -euo pipefail
        export PATH="$FAKEBIN:$PATH"
        HWE_ROOT="$HWE_REPO_ROOT"
        source "$HWE_ROOT/lib/common.sh"
        source "$HWE_ROOT/lib/clip.sh"
        clip_main "$@"
    ' _ "$@"
}

@test "a cancelled picker leaves the clipboard untouched" {
    _fake_rofi
    ROFI_EXIT=1 ROFI_PICK="" run_clip show
    assert_success
    [[ ! -e "$WLMARK" ]]
}

@test "a real pick is copied" {
    _fake_rofi
    ROFI_EXIT=0 ROFI_PICK=$'1\tfoo' run_clip show
    assert_success
    [[ -e "$WLMARK" ]]
    assert_equal "$(cat "$WLMARK")" $'1\tfoo'
}

@test "clip help is not an error" {
    run_clip help
    assert_success
    [[ "$stderr" == *"usage: hwe clip"* ]]
}

@test "an unknown clip action fails and says which" {
    run_clip frobnicate
    assert_failure
    [[ "$stderr" == *"unknown clip action: frobnicate"* ]]
}
