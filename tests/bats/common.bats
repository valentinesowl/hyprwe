#!/usr/bin/env bats
# lib/common.sh — the helpers every other module is built on.
#
# These are small functions, but they are the ones that decide whether a
# privileged install prompts, proceeds, or dies — so they are worth pinning.

bats_require_minimum_version 1.5.0

setup() {
    load 'helper'
    hwe_setup
}

# --- log helpers -----------------------------------------------------------

@test "log helpers write to stderr, never stdout" {
    # Anything on stdout would corrupt the functions that capture command output.
    source_common
    run --separate-stderr bash -c "
        source '$HWE_ROOT/lib/common.sh'
        log hello; info hello; ok hello; warn hello; err hello
    "
    assert_success
    [ -z "$output" ]          # stdout empty
    [ -n "$stderr" ]
}

@test "log helpers print the message they are given" {
    source_common
    run --separate-stderr bash -c "source '$HWE_ROOT/lib/common.sh'; warn 'disk is full'"
    assert_success
    [[ "$stderr" == *"disk is full"* ]]
}

@test "die reports the message and exits non-zero" {
    run --separate-stderr bash -c "source '$HWE_ROOT/lib/common.sh'; die 'no kvm'; echo UNREACHABLE"
    assert_failure
    [[ "$stderr" == *"no kvm"* ]]
    [[ "$output" != *"UNREACHABLE"* ]]
}

# --- colour ----------------------------------------------------------------

@test "colour is disabled when stderr is not a tty" {
    # Captured output must stay clean for logs, pipes and CI.
    run --separate-stderr bash -c "source '$HWE_ROOT/lib/common.sh'; err 'plain'"
    refute_output_contains_escape "$stderr"
}

@test "NO_COLOR is honoured" {
    run --separate-stderr env NO_COLOR=1 bash -c "source '$HWE_ROOT/lib/common.sh'; echo \"[\$C_RED]\""
    assert_success
    assert_output "[]"
}

# --- confirm ---------------------------------------------------------------

@test "confirm accepts y" {
    run bash -c "source '$HWE_ROOT/lib/common.sh'; echo y | confirm 'go?'"
    assert_success
}

@test "confirm accepts uppercase Y" {
    run bash -c "source '$HWE_ROOT/lib/common.sh'; echo Y | confirm 'go?'"
    assert_success
}

@test "confirm defaults to no on a bare enter" {
    # The default must be the safe one: these prompts guard destructive steps.
    run bash -c "source '$HWE_ROOT/lib/common.sh'; echo '' | confirm 'go?'"
    assert_failure
}

@test "confirm rejects anything else" {
    run bash -c "source '$HWE_ROOT/lib/common.sh'; echo yes-please | confirm 'go?'"
    assert_failure
}

@test "HWE_ASSUME_YES skips the prompt entirely" {
    # Unattended installs rely on this: no stdin is read at all.
    run bash -c "source '$HWE_ROOT/lib/common.sh'; HWE_ASSUME_YES=1 confirm 'go?' </dev/null"
    assert_success
}

# --- need ------------------------------------------------------------------

@test "need succeeds for a command that exists" {
    run bash -c "source '$HWE_ROOT/lib/common.sh'; need bash"
    assert_success
}

@test "need fails for a missing command" {
    run bash -c "source '$HWE_ROOT/lib/common.sh'; need definitely-not-installed-xyz"
    assert_failure
}

@test "need prints the install hint it is given" {
    run --separate-stderr bash -c "
        source '$HWE_ROOT/lib/common.sh'
        need definitely-not-installed-xyz 'sudo pacman -S xyz'
    "
    assert_failure
    [[ "$stderr" == *"sudo pacman -S xyz"* ]]
}

@test "need does not exit its caller" {
    # need returns; only the caller decides whether a missing tool is fatal.
    run bash -c "source '$HWE_ROOT/lib/common.sh'; need nope-xyz 2>/dev/null; echo REACHED"
    assert_output --partial "REACHED"
}

# --- run -------------------------------------------------------------------

@test "run executes the command it echoes" {
    run --separate-stderr bash -c "source '$HWE_ROOT/lib/common.sh'; run echo executed"
    assert_success
    assert_output "executed"
    [[ "$stderr" == *"echo executed"* ]]   # the command is shown for transparency
}

@test "run propagates a failure" {
    run bash -c "source '$HWE_ROOT/lib/common.sh'; run false"
    assert_failure
}

@test "run passes arguments through untouched" {
    run --separate-stderr bash -c "source '$HWE_ROOT/lib/common.sh'; run printf '%s|%s' 'a b' 'c'"
    assert_success
    assert_output "a b|c"
}

# --- contract --------------------------------------------------------------

@test "common.sh refuses to load without HWE_ROOT" {
    # Every path in the toolchain is resolved from it; an empty HWE_ROOT would
    # silently turn "$HWE_ROOT/themes" into "/themes".
    #
    # Deliberately not `run`: `${HWE_ROOT:?}` aborts the shell with 127, which
    # bats flags as a probable command-not-found (BW01). Pinning `run -127` would
    # instead hardcode a bash implementation detail we do not actually care about.
    # What we assert is what the contract promises: it fails, and it says why.
    local err="$BATS_TEST_TMPDIR/stderr"
    local status=0
    env -u HWE_ROOT bash -c "source '$HWE_ROOT/lib/common.sh'" 2>"$err" || status=$?
    [ "$status" -ne 0 ]
    grep -q "HWE_ROOT must be set" "$err"
}

@test "HWE_CACHE follows XDG_CACHE_HOME" {
    run bash -c "
        export XDG_CACHE_HOME=/tmp/xdg-cache
        source '$HWE_ROOT/lib/common.sh'
        echo \"\$HWE_CACHE\"
    "
    assert_output "/tmp/xdg-cache/hwe"
}

@test "HWE_CACHE falls back to ~/.cache" {
    run bash -c "
        unset XDG_CACHE_HOME
        HOME=/home/tester
        source '$HWE_ROOT/lib/common.sh'
        echo \"\$HWE_CACHE\"
    "
    assert_output "/home/tester/.cache/hwe"
}
