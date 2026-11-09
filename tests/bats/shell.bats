#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
    load 'helper'
    hwe_setup
    export HWE_REPO_ROOT="$HWE_ROOT"
    export TEST_HOME="$BATS_TEST_TMPDIR/home"
    export TEST_CONFIG="$BATS_TEST_TMPDIR/config"
    mkdir -p "$TEST_HOME"
}

shell_fn() {
    bash -c '
        set -euo pipefail
        HWE_ROOT="$HWE_REPO_ROOT"
        HOME="$TEST_HOME"
        HWE_USER_CONFIG="$TEST_CONFIG"
        export HWE_USER_CONFIG
        source "$HWE_ROOT/lib/common.sh"
        HWE_INSTALL_STANDALONE=1 source "$HWE_ROOT/provision/guest-install.sh"
        fn="$1"; shift
        "$fn" "$@"
    ' _ "$@"
}

@test "install preserves an existing zshenv and saves a backup" {
    printf 'export BEFORE=1\nexport AFTER=2\n' > "$TEST_HOME/.zshenv"
    run shell_fn _zshenv_install_block
    assert_success
    assert_output --partial "hwe-bak"
    run cat "$TEST_HOME/.zshenv"
    assert_output --partial "export BEFORE=1"
    assert_output --partial "export AFTER=2"
    assert_output --partial 'export ZDOTDIR="$HOME/.config/zsh"'
    run cat "$TEST_HOME"/.zshenv.hwe-bak.*
    assert_output $'export BEFORE=1\nexport AFTER=2'
}

@test "repeat install replaces only the managed block" {
    printf 'export BEFORE=1\n' > "$TEST_HOME/.zshenv"
    shell_fn _zshenv_install_block
    printf 'export AFTER=2\n' >> "$TEST_HOME/.zshenv"
    run shell_fn _zshenv_install_block
    assert_success
    run cat "$TEST_HOME/.zshenv"
    assert_output --partial "export BEFORE=1"
    assert_output --partial "export AFTER=2"
    [[ "$(grep -Fxc '# >>> HWE zsh >>>' "$TEST_HOME/.zshenv")" == 1 ]]
}

@test "uninstall removes only the managed block and later user edits survive" {
    printf 'export BEFORE=1\n' > "$TEST_HOME/.zshenv"
    shell_fn _zshenv_install_block
    printf 'export AFTER=2\n' >> "$TEST_HOME/.zshenv"
    run shell_fn _zshenv_remove_block
    assert_success
    run cat "$TEST_HOME/.zshenv"
    assert_output --partial "export BEFORE=1"
    assert_output --partial "export AFTER=2"
    refute_output --partial "HWE zsh"
    compgen -G "$TEST_HOME/.zshenv.hwe-bak.*" >/dev/null
}

@test "a file created by HWE is removed when it still contains only the block" {
    shell_fn _zshenv_install_block
    run shell_fn _zshenv_remove_block
    assert_success
    [[ ! -e "$TEST_HOME/.zshenv" ]]
}

@test "an empty pre-existing file is not treated as created by HWE" {
    : > "$TEST_HOME/.zshenv"
    shell_fn _zshenv_install_block
    run shell_fn _zshenv_remove_block
    assert_success
    [[ -f "$TEST_HOME/.zshenv" ]]
    [[ ! -s "$TEST_HOME/.zshenv" ]]
}

@test "malformed markers leave the original file untouched" {
    printf '# >>> HWE zsh >>>\nexport MINE=1\n' > "$TEST_HOME/.zshenv"
    run shell_fn _zshenv_install_block
    assert_failure
    assert_output --partial "leaving it unchanged"
    run cat "$TEST_HOME/.zshenv"
    assert_output $'# >>> HWE zsh >>>\nexport MINE=1'
}

@test "HWE_NO_ZSH persists the shell choice without executing state" {
    HWE_NO_ZSH=1 run shell_fn _setup_shell
    assert_success
    assert_output --partial "remembered"
    run cat "$TEST_CONFIG/settings.conf"
    assert_output --partial "shell=preserve"
    printf 'shell=$(touch /tmp/should-not-run)\n' > "$TEST_CONFIG/settings.conf"
    run shell_fn _hwe_state_get shell
    assert_failure
    [[ ! -e /tmp/should-not-run ]]
}
