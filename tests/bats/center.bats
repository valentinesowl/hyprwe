#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
    load 'helper'
    hwe_setup
    export HWE_SESSION_DIR="$BATS_TEST_TMPDIR/sessions"
    export ROFI_INPUT="$BATS_TEST_TMPDIR/rofi-input"
}

center_fn() {
    bash -c '
        set -euo pipefail
        source "$HWE_ROOT/lib/common.sh"
        source "$HWE_ROOT/lib/center.sh"
        need() { :; }
        pgrep() { return 1; }
        notify() { printf "notify:%s|%s|%s\n" "$1" "$2" "$3"; }
        _center_run() { printf "run"; printf " <%s>" "$@"; printf "\n"; }
        _center_terminal() {
            printf "terminal:%s" "${HWE_ASSUME_YES:-0}"
            printf " <%s>" "$@"
            printf "\n"
        }
        center_main "$@"
    ' _ "$@"
}

@test "center help explains the entry point without opening rofi" {
    run --separate-stderr hwe center help
    assert_success
    [[ "$stderr" == *"hwe center [themes|sessions|system|vm|tools]"* ]]
    [[ "$stderr" == *"SUPER+A"* ]]
}

@test "an unknown center section fails instead of opening a menu" {
    run --separate-stderr hwe center somewhere
    assert_failure
    [[ "$stderr" == *"unknown center section: somewhere"* ]]
}

@test "menu dispatch uses the selected index rather than a display label" {
    run bash -c '
        set -euo pipefail
        source "$HWE_ROOT/lib/common.sh"
        source "$HWE_ROOT/lib/center.sh"
        rofi() {
            cat > "$ROFI_INPUT"
            printf "2\n"
        }
        _center_menu "prompt" "message" "first" "second" "third"
    '
    assert_success
    assert_output "2"
    run cat "$ROFI_INPUT"
    assert_output $'first\nsecond\nthird'
}

@test "an out-of-range menu answer is cancellation, not an action" {
    run bash -c '
        set -euo pipefail
        source "$HWE_ROOT/lib/common.sh"
        source "$HWE_ROOT/lib/center.sh"
        rofi() { cat >/dev/null; printf "8\n"; }
        _center_menu "prompt" "message" "only row"
    '
    assert_failure
    assert_output ""
}

@test "closing the root menu runs nothing" {
    run bash -c '
        set -euo pipefail
        source "$HWE_ROOT/lib/common.sh"
        source "$HWE_ROOT/lib/center.sh"
        need() { :; }
        pgrep() { return 1; }
        rofi() { cat >/dev/null; return 1; }
        _center_run() { echo "must-not-run"; }
        center_main
    '
    assert_success
    refute_output --partial "must-not-run"
}

@test "the theme section delegates to the existing theme picker" {
    run bash -c '
        set -euo pipefail
        source "$HWE_ROOT/lib/common.sh"
        source "$HWE_ROOT/lib/center.sh"
        need() { :; }
        pgrep() { return 1; }
        _center_menu() { printf "0\n"; }
        _center_run() { printf "run"; printf " <%s>" "$@"; printf "\n"; }
        center_main themes
    '
    assert_success
    assert_output "run <theme> <pick>"
}

@test "saving a session validates its name before calling the CLI" {
    run bash -c '
        set -euo pipefail
        source "$HWE_ROOT/lib/common.sh"
        source "$HWE_ROOT/lib/center.sh"
        notify() { printf "notify:%s|%s|%s\n" "$1" "$2" "$3"; }
        _center_input() { printf "../escape\n"; }
        _center_run() { echo "must-not-run"; }
        _center_save_session
    '
    assert_failure
    assert_output --partial "notify:error|Invalid session name"
    refute_output --partial "must-not-run"
}

@test "saving a valid new snapshot delegates its exact name" {
    run bash -c '
        set -euo pipefail
        source "$HWE_ROOT/lib/common.sh"
        source "$HWE_ROOT/lib/center.sh"
        _center_input() { printf "work.setup-2\n"; }
        _center_run() { printf "run"; printf " <%s>" "$@"; printf "\n"; }
        _center_save_session
    '
    assert_success
    assert_output "run <session> <save> <work.setup-2>"
}

@test "overwriting a snapshot requires graphical confirmation" {
    mkdir -p "$HWE_SESSION_DIR"
    printf '{}\n' > "$HWE_SESSION_DIR/work.json"
    run bash -c '
        set -euo pipefail
        source "$HWE_ROOT/lib/common.sh"
        source "$HWE_ROOT/lib/center.sh"
        _center_input() { printf "work\n"; }
        _center_confirm() { return 1; }
        _center_run() { echo "must-not-run"; }
        _center_save_session
    '
    assert_success
    refute_output --partial "must-not-run"
}

@test "deleting a snapshot does nothing when confirmation is refused" {
    mkdir -p "$HWE_SESSION_DIR"
    printf '{}\n' > "$HWE_SESSION_DIR/work.json"
    run bash -c '
        set -euo pipefail
        source "$HWE_ROOT/lib/common.sh"
        source "$HWE_ROOT/lib/center.sh"
        need() { :; }
        pgrep() { return 1; }
        _center_menu() { printf "2\n"; }
        _center_session_pick() { printf "work\n"; }
        _center_confirm() { return 1; }
        _center_run() { echo "must-not-run"; }
        center_main sessions
    '
    assert_success
    refute_output --partial "must-not-run"
    [[ -f "$HWE_SESSION_DIR/work.json" ]]
}

@test "a drift report still opens when doctor returns nonzero" {
    run bash -c '
        set -euo pipefail
        source "$HWE_ROOT/lib/common.sh"
        source "$HWE_ROOT/lib/center.sh"
        _center_capture() { printf "drift detected\n"; return 1; }
        rofi() { cat > "$ROFI_INPUT"; return 1; }
        _center_report "System / health" doctor --report
    '
    assert_success
    run cat "$ROFI_INPUT"
    assert_output "drift detected"
}

@test "destroying a VM is cancelled by the graphical guard" {
    run bash -c '
        set -euo pipefail
        source "$HWE_ROOT/lib/common.sh"
        source "$HWE_ROOT/lib/center.sh"
        need() { :; }
        pgrep() { return 1; }
        _center_menu() { printf "5\n"; }
        _center_confirm() { return 1; }
        _center_terminal() { echo "must-not-run"; }
        center_main vm
    '
    assert_success
    refute_output --partial "must-not-run"
}

@test "a confirmed VM rebuild passes exactly one explicit assumption downstream" {
    run bash -c '
        set -euo pipefail
        source "$HWE_ROOT/lib/common.sh"
        source "$HWE_ROOT/lib/center.sh"
        need() { :; }
        pgrep() { return 1; }
        _center_menu() { printf "4\n"; }
        _center_confirm() { return 0; }
        _center_terminal() {
            printf "terminal:%s" "${HWE_ASSUME_YES:-0}"
            printf " <%s>" "$@"
            printf "\n"
        }
        center_main vm
    '
    assert_success
    assert_output "terminal:1 <hyprwe · rebuild VM> <vm> <rebuild> <--uncommitted>"
}

@test "SUPER+A opens the command center without taking the layout shortcut" {
    run grep -F 'bind("SUPER + A", hl.dsp.exec_cmd("hwe center")' "$HWE_ROOT/config/hypr/keybindings.lua"
    assert_success
    run grep -F 'bind("SUPER + SPACE", hl.dsp.exec_cmd("hyprctl switchxkblayout current next")' "$HWE_ROOT/config/hypr/keybindings.lua"
    assert_success
}
