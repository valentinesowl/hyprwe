#!/usr/bin/env bats
# lib/update.sh — the git side of `hwe update`.
#
# Reconciling packages, configs and the theme needs a live machine and is out of
# scope here. The pull is not: it decides whether the rest of the update runs at
# all, and every one of its refusals is a state the user has to be told how to
# leave. Each test builds a throwaway repo (and, where it matters, a bare remote)
# so the assertions are about real git behaviour.

bats_require_minimum_version 1.5.0

setup() {
    load 'helper'
    hwe_setup

    export HWE_REPO_ROOT="$HWE_ROOT"
    ORIGIN="$BATS_TEST_TMPDIR/origin.git"
    REPO="$BATS_TEST_TMPDIR/repo"
    git init -q --bare -b main "$ORIGIN"

    # Seed the remote through a scratch clone, so $REPO can be made either way:
    # cloned (tracking set) or built by hand (no tracking) per test.
    local seed="$BATS_TEST_TMPDIR/seed"
    git clone -q "$ORIGIN" "$seed"
    git -C "$seed" config user.name "test"
    git -C "$seed" config user.email "test@example.invalid"
    printf 'v1\n' > "$seed/tracked.txt"
    printf 'generated.out\n' > "$seed/.gitignore"
    git -C "$seed" add -A
    git -C "$seed" commit -qm init
    git -C "$seed" push -q origin main
    export ORIGIN REPO SEED="$seed"
}

# Call an update.sh function against the scratch repo, in a subshell. It has to
# be a subshell: lib/common.sh defines its own `run` (the sudo/echo wrapper),
# which would shadow bats' `run` for the whole file if we sourced it here.
hwe_update() {
    bash -c '
        set -euo pipefail
        HWE_ROOT="$HWE_REPO_ROOT"
        source "$HWE_ROOT/lib/common.sh"
        source "$HWE_ROOT/lib/update.sh"
        HWE_ROOT="$REPO"          # the helpers resolve it per call
        fn="$1"; shift
        "$fn" "$@"
    ' _ "$@"
}

# A working copy that tracks the remote — what `git clone` gives everyone.
clone_repo() {
    git clone -q "$ORIGIN" "$REPO"
    git -C "$REPO" config user.name "test"
    git -C "$REPO" config user.email "test@example.invalid"
}

# A working copy with the same content and remote, but no tracking config —
# what you get by building the repo locally and pushing without -u.
untracked_repo() {
    clone_repo
    git -C "$REPO" config --unset branch.main.remote
    git -C "$REPO" config --unset branch.main.merge
}

# Move the remote one commit ahead.
advance_origin() {
    printf 'v2\n' > "$SEED/tracked.txt"
    git -C "$SEED" commit -qam v2
    git -C "$SEED" push -q origin main
}

@test "a tracked branch fast-forwards onto the remote" {
    clone_repo
    advance_origin
    run hwe_update _update_pull
    assert_success
    assert_equal "$(cat "$REPO/tracked.txt")" "v2"
}

@test "no upstream names the command that sets one" {
    untracked_repo
    run --separate-stderr hwe_update _update_pull
    assert_failure
    [[ "$stderr" == *"no upstream"* ]]
    [[ "$stderr" == *"branch --set-upstream-to=origin/main main"* ]]
}

@test "the suggested set-upstream command actually works" {
    untracked_repo
    advance_origin
    git -C "$REPO" branch --set-upstream-to=origin/main main >/dev/null
    run hwe_update _update_pull
    assert_success
    assert_equal "$(cat "$REPO/tracked.txt")" "v2"
}

@test "a remote without the branch is not sent to set-upstream" {
    untracked_repo
    git -C "$REPO" update-ref -d refs/remotes/origin/main
    run --separate-stderr hwe_update _update_pull
    assert_failure
    [[ "$stderr" == *"no branch 'main'"* ]]
    [[ "$stderr" != *"--set-upstream-to"* ]]
}

@test "a repo with no remote says so" {
    untracked_repo
    git -C "$REPO" remote remove origin
    run --separate-stderr hwe_update _update_pull
    assert_failure
    [[ "$stderr" == *"no remote at all"* ]]
    [[ "$stderr" != *"--set-upstream-to"* ]]
}

@test "uncommitted tracked changes stop the pull" {
    clone_repo
    advance_origin
    printf 'mine\n' >> "$REPO/tracked.txt"
    run --separate-stderr hwe_update _update_pull
    assert_failure
    [[ "$stderr" == *"uncommitted changes"* ]]
    assert_equal "$(head -n1 "$REPO/tracked.txt")" "v1"
}

@test "generated files the repo ignores do not stop the pull" {
    clone_repo
    advance_origin
    printf 'build output\n' > "$REPO/generated.out"
    run hwe_update _update_pull
    assert_success
    assert_equal "$(cat "$REPO/tracked.txt")" "v2"
}

@test "a detached HEAD is refused before anything is pulled" {
    clone_repo
    git -C "$REPO" checkout -q --detach HEAD
    run --separate-stderr hwe_update _update_pull
    assert_failure
    [[ "$stderr" == *"detached"* ]]
}

@test "a diverged branch is refused with a way out" {
    clone_repo
    advance_origin
    printf 'local\n' > "$REPO/tracked.txt"
    git -C "$REPO" commit -qam local
    run --separate-stderr hwe_update _update_pull
    assert_failure
    [[ "$stderr" == *"diverged"* ]]
    [[ "$stderr" == *"rebase"* ]]
    assert_equal "$(cat "$REPO/tracked.txt")" "local"
}

@test "a directory that is not a git checkout is named as such" {
    mkdir -p "$REPO"
    run --separate-stderr hwe_update _update_pull
    assert_failure
    [[ "$stderr" == *"not a git checkout"* ]]
}
