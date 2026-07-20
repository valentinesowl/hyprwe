#!/usr/bin/env bats
# bin/hwe — the CLI's dispatch surface.
#
# Only the subcommands that are safe to run anywhere are exercised end to end;
# the rest (install, vm, power) touch real hardware, packages or the compositor,
# so here we pin dispatch and refusal, and leave behaviour to the VM.

bats_require_minimum_version 1.5.0

setup() {
    load 'helper'
    hwe_setup
}

@test "version prints the version" {
    run "$HWE_ROOT/bin/hwe" version
    assert_success
    assert_output --regexp '^hwe [0-9]+\.[0-9]+\.[0-9]+$'
}

@test "--version and -V match version" {
    run "$HWE_ROOT/bin/hwe" version
    local expected="$output"
    run "$HWE_ROOT/bin/hwe" --version
    assert_output "$expected"
    run "$HWE_ROOT/bin/hwe" -V
    assert_output "$expected"
}

@test "the declared version is a plain semver" {
    # The release tag is cut from this; anything else breaks the workflow's check.
    run bash -c "grep -oP '^HWE_VERSION=\"\K[^\"]+' '$HWE_ROOT/bin/hwe'"
    assert_success
    assert_output --regexp '^[0-9]+\.[0-9]+\.[0-9]+$'
}

@test "bare hwe shows usage" {
    run "$HWE_ROOT/bin/hwe"
    assert_success
    assert_output --partial "Usage:"
}

@test "help, -h and --help all show usage" {
    for flag in help -h --help; do
        run "$HWE_ROOT/bin/hwe" "$flag"
        assert_success
        assert_output --partial "Usage:"
    done
}

@test "usage goes to stderr" {
    # So `hwe | something` never gets a help screen as data.
    run --separate-stderr "$HWE_ROOT/bin/hwe" help
    [ -z "$output" ]
    [[ "$stderr" == *"Usage:"* ]]
}

@test "an unknown command fails and says which" {
    run --separate-stderr "$HWE_ROOT/bin/hwe" definitely-not-a-command
    assert_failure
    [[ "$stderr" == *"unknown command: definitely-not-a-command"* ]]
    [[ "$stderr" == *"Usage:"* ]]
}

@test "every command in the usage text dispatches" {
    # Catches a command documented but never wired into the case statement.
    for cmd in vm install update uninstall doctor theme wall power keys clip record checkconfig version; do
        run bash -c "grep -qE '^\s+$cmd[)|]' '$HWE_ROOT/bin/hwe' || grep -qE '^\s+$cmd\|' '$HWE_ROOT/bin/hwe'"
        assert_success
    done
}

@test "install help shows usage and touches nothing" {
    run --separate-stderr "$HWE_ROOT/bin/hwe" install help
    assert_success
    [[ "$stderr" == *"usage: hwe install"* ]]
}

@test "install rejects stray arguments instead of running" {
    run --separate-stderr "$HWE_ROOT/bin/hwe" install --bogus
    assert_failure
    [[ "$stderr" == *"takes no arguments"* ]]
}

@test "uninstall help shows usage and touches nothing" {
    run --separate-stderr "$HWE_ROOT/bin/hwe" uninstall --help
    assert_success
    [[ "$stderr" == *"usage: hwe uninstall"* ]]
}

@test "uninstall rejects stray arguments instead of running" {
    run --separate-stderr "$HWE_ROOT/bin/hwe" uninstall bogus
    assert_failure
    [[ "$stderr" == *"takes no arguments"* ]]
}

@test "doctor help shows the doctor usage on stderr" {
    run --separate-stderr "$HWE_ROOT/bin/hwe" doctor help
    assert_success
    [[ "$stderr" == *"hwe doctor"* ]]
    [[ "$stderr" == *"host"* ]]
    [[ "$stderr" == *"vm"* ]]
}

@test "an unknown doctor subject fails and says which" {
    run --separate-stderr "$HWE_ROOT/bin/hwe" doctor not-a-subject
    assert_failure
    [[ "$stderr" == *"unknown doctor subject: not-a-subject"* ]]
}

@test "update help shows the update usage on stderr" {
    run --separate-stderr "$HWE_ROOT/bin/hwe" update help
    assert_success
    [[ "$stderr" == *"hwe update"* ]]
    [[ "$stderr" == *"--check"* ]]
}

@test "an unknown update flag fails and says which" {
    run --separate-stderr "$HWE_ROOT/bin/hwe" update --bogus
    assert_failure
    [[ "$stderr" == *"unknown update flag: --bogus"* ]]
}

@test "the CLI resolves its root through a symlink" {
    # `hwe` is meant to be symlinked onto PATH; HWE_ROOT must still find the repo.
    local link="$BATS_TEST_TMPDIR/hwe-link"
    ln -sf "$HWE_ROOT/bin/hwe" "$link"
    run "$link" version
    assert_success
    assert_output --partial "hwe "
}

@test "the CLI works from an unrelated working directory" {
    cd "$BATS_TEST_TMPDIR"
    run "$HWE_ROOT/bin/hwe" version
    assert_success
}
