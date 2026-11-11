#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
    load 'helper'
    hwe_setup
    export HWE_REPO_ROOT="$HWE_ROOT"
    export TEST_HOME="$BATS_TEST_TMPDIR/home"
    export HWE_SCREENSHOT_DIR="$BATS_TEST_TMPDIR/pictures"
    mkdir -p "$TEST_HOME"
}

screenshot_fn() {
    bash -c '
        set -euo pipefail
        HWE_ROOT="$HWE_REPO_ROOT"
        HOME="$TEST_HOME"
        source "$HWE_ROOT/lib/common.sh"
        source "$HWE_ROOT/lib/screenshot.sh"
        need() { :; }
        notify() { printf "notify:%s|%s|%s\n" "$1" "$2" "${3:-}"; }
        grim() {
            [[ "${GRIM_RC:-0}" -eq 0 ]] || return "$GRIM_RC"
            printf "png\n" > "${@: -1}"
        }
        slurp() {
            [[ "${SLURP_RC:-0}" -eq 0 ]] || return "$SLURP_RC"
            printf "1,2 30x40\n"
        }
        wl-copy() { cat >/dev/null; return "${COPY_RC:-0}"; }
        satty() {
            local out="" arg
            while [[ $# -gt 0 ]]; do
                if [[ "$1" == --output-filename ]]; then out="$2"; shift; fi
                shift
            done
            [[ "${SATTY_RC:-0}" -ne 0 ]] && return "$SATTY_RC"
            printf "annotated\n" > "$out"
        }
        screenshot_main "$@"
    ' _ "$@"
}

@test "whole-screen capture copies the image and reports success" {
    run screenshot_fn screen
    assert_success
    assert_output --partial "notify:success|Screenshot copied|"
}

@test "region capture passes slurp geometry to grim" {
    run screenshot_fn region
    assert_success
    assert_output --partial "Screenshot copied"
}

@test "cancelling slurp is not a screenshot success" {
    SLURP_RC=1 run screenshot_fn region
    assert_success
    assert_output --partial "notify:info|Screenshot cancelled|"
    refute_output --partial "Screenshot copied"
}

@test "a grim failure names grim and does not copy" {
    GRIM_RC=7 run screenshot_fn screen
    assert_failure
    assert_output --partial "grim could not capture"
    refute_output --partial "Screenshot copied"
}

@test "a clipboard failure is distinct from a capture failure" {
    COPY_RC=1 run screenshot_fn screen
    assert_failure
    assert_output --partial "Could not copy the image to the clipboard"
}

@test "file capture saves into Pictures and reports the path" {
    run screenshot_fn file
    assert_success
    assert_output --partial "notify:success|Screenshot saved|"
    run ls "$HWE_SCREENSHOT_DIR"
    assert_output --partial ".png"
}

@test "satty cancellation is not reported as a saved annotation" {
    SATTY_RC=1 run screenshot_fn annotate
    assert_success
    assert_output --partial "notify:info|Annotation cancelled|"
    refute_output --partial "Annotated screenshot saved"
}

@test "a satty error reports its exit status" {
    SATTY_RC=2 run screenshot_fn annotate
    assert_failure
    assert_output --partial "satty exited with status 2"
}
