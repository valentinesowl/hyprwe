#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
    load 'helper'
    hwe_setup
    export HWE_REPO_ROOT="$HWE_ROOT"
    export TEST_HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$TEST_HOME"
}

record_fn() {
    bash -c '
        set -euo pipefail
        HWE_ROOT="$HWE_REPO_ROOT"
        HOME="$TEST_HOME"
        source "$HWE_ROOT/lib/common.sh"
        source "$HWE_ROOT/lib/record.sh"
        need() { :; }
        notify() { printf "notify:%s|%s|%s\n" "$1" "$2" "${3:-}"; }
        pgrep() { return 1; }
        slurp() { return 1; }
        disown() { :; }
        wf-recorder() { :; }
        record_main "$@"
    ' _ "$@"
}

@test "cancelling a recording region gives cancellation feedback" {
    run record_fn region
    assert_success
    assert_output --partial "notify:info|Recording cancelled|"
    refute_output --partial "Recording started"
}
