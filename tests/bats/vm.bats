#!/usr/bin/env bats
# lib/vm.sh — the git-bundle side of `hwe vm up`.
#
# Everything libvirt touches (domains, disks, networks) is out of scope here; what
# IS testable on any machine is WHICH content ends up on the seed ISO — the branch's
# last commit, or, with --uncommitted, the working tree as it is right now. Each
# test builds a throwaway repo and clones the resulting bundle back out, so the
# assertions are about real bundle content, not about how we built it.

bats_require_minimum_version 1.5.0

setup() {
    load 'helper'
    hwe_setup

    export HWE_REPO_ROOT="$HWE_ROOT"
    REPO="$BATS_TEST_TMPDIR/repo"
    WORK="$BATS_TEST_TMPDIR/work"
    mkdir -p "$REPO" "$WORK"
    git -C "$REPO" init -q -b main
    git -C "$REPO" config user.name "test"
    git -C "$REPO" config user.email "test@example.invalid"
    printf 'committed\n' > "$REPO/tracked.txt"
    printf 'generated.out\n' > "$REPO/.gitignore"
    git -C "$REPO" add -A
    git -C "$REPO" commit -qm init
    export REPO
}

# Call a vm.sh function against the scratch repo, in a subshell. It has to be a
# subshell: lib/common.sh defines its own `run` (the sudo/echo wrapper), which
# would shadow bats' `run` for the whole file if we sourced it here.
hwe_vm() {
    bash -c '
        set -euo pipefail
        HWE_ROOT="$HWE_REPO_ROOT"
        source "$HWE_ROOT/lib/common.sh"
        source "$HWE_ROOT/lib/vm.sh"
        HWE_ROOT="$REPO"          # the helpers resolve it per call
        fn="$1"; shift
        "$fn" "$@"
    ' _ "$@"
}

# Clone the bundle into $1 so we can look at the deployed tree.
extract() {
    git clone -q -b "${2:-main}" "$BATS_TEST_TMPDIR/hwe.bundle" "$1"
}

dirty_the_tree() {
    printf 'edited\n' >> "$REPO/tracked.txt"
    printf 'brand new\n' > "$REPO/untracked.txt"
    printf 'build output\n' > "$REPO/generated.out"
}

@test "without --uncommitted only committed content is bundled" {
    dirty_the_tree
    run hwe_vm _vm_build_bundle main "$BATS_TEST_TMPDIR/hwe.bundle"
    assert_success
    extract "$BATS_TEST_TMPDIR/out"
    assert_equal "$(cat "$BATS_TEST_TMPDIR/out/tracked.txt")" "committed"
    [ ! -e "$BATS_TEST_TMPDIR/out/untracked.txt" ]
}

@test "a dirty tree warns and points at --uncommitted" {
    dirty_the_tree
    run --separate-stderr hwe_vm _vm_build_bundle main "$BATS_TEST_TMPDIR/hwe.bundle"
    assert_success
    [[ "$stderr" == *"uncommitted changes"* ]]
    [[ "$stderr" == *"--uncommitted"* ]]
}

@test "--uncommitted deploys modified, staged and untracked files" {
    dirty_the_tree
    printf 'staged\n' > "$REPO/staged.txt"
    git -C "$REPO" add staged.txt

    run hwe_vm _vm_build_bundle main "$BATS_TEST_TMPDIR/hwe.bundle" 1 "$WORK"
    assert_success
    extract "$BATS_TEST_TMPDIR/out"
    assert_equal "$(cat "$BATS_TEST_TMPDIR/out/tracked.txt")" "$(printf 'committed\nedited')"
    assert_equal "$(cat "$BATS_TEST_TMPDIR/out/untracked.txt")" "brand new"
    assert_equal "$(cat "$BATS_TEST_TMPDIR/out/staged.txt")" "staged"
}

@test "--uncommitted deploys deletions too" {
    rm "$REPO/tracked.txt"
    run hwe_vm _vm_build_bundle main "$BATS_TEST_TMPDIR/hwe.bundle" 1 "$WORK"
    assert_success
    extract "$BATS_TEST_TMPDIR/out"
    [ ! -e "$BATS_TEST_TMPDIR/out/tracked.txt" ]
}

@test "--uncommitted leaves ignored files behind" {
    # config/*/colors.* and friends are generated — the guest builds its own.
    dirty_the_tree
    run hwe_vm _vm_build_bundle main "$BATS_TEST_TMPDIR/hwe.bundle" 1 "$WORK"
    assert_success
    extract "$BATS_TEST_TMPDIR/out"
    [ ! -e "$BATS_TEST_TMPDIR/out/generated.out" ]
}

@test "--uncommitted keeps the branch's history" {
    dirty_the_tree
    run hwe_vm _vm_build_bundle main "$BATS_TEST_TMPDIR/hwe.bundle" 1 "$WORK"
    assert_success
    extract "$BATS_TEST_TMPDIR/out"
    run git -C "$BATS_TEST_TMPDIR/out" log --oneline
    assert_success
    assert_line --index 1 --partial "init"
    run git -C "$BATS_TEST_TMPDIR/out" rev-parse --abbrev-ref HEAD
    assert_output "main"
}

@test "--uncommitted does not touch the repo it snapshots" {
    dirty_the_tree
    local head_before status_before branches_before
    head_before="$(git -C "$REPO" rev-parse HEAD)"
    status_before="$(git -C "$REPO" status --porcelain)"
    branches_before="$(git -C "$REPO" for-each-ref --format='%(refname)')"

    run hwe_vm _vm_build_bundle main "$BATS_TEST_TMPDIR/hwe.bundle" 1 "$WORK"
    assert_success

    assert_equal "$(git -C "$REPO" rev-parse HEAD)" "$head_before"
    assert_equal "$(git -C "$REPO" status --porcelain)" "$status_before"
    assert_equal "$(git -C "$REPO" for-each-ref --format='%(refname)')" "$branches_before"
    # The snapshot must not be staged: `git commit` after a vm up commits nothing new.
    run git -C "$REPO" diff --cached --quiet
    assert_success
}

@test "--uncommitted refuses a branch that is not checked out" {
    git -C "$REPO" branch other
    dirty_the_tree
    run --separate-stderr hwe_vm _vm_build_bundle other "$BATS_TEST_TMPDIR/hwe.bundle" 1 "$WORK"
    assert_failure
    [[ "$stderr" == *"--uncommitted"* ]]
    [[ "$stderr" == *"main"* ]]
}

@test "--uncommitted on a clean tree equals the branch" {
    run --separate-stderr hwe_vm _vm_build_bundle main "$BATS_TEST_TMPDIR/hwe.bundle" 1 "$WORK"
    assert_success
    [[ "$stderr" == *"clean"* ]]
    extract "$BATS_TEST_TMPDIR/out"
    assert_equal "$(git -C "$BATS_TEST_TMPDIR/out" rev-parse HEAD)" "$(git -C "$REPO" rev-parse main)"
}

@test "vm up rejects an unknown flag and a second branch" {
    run --separate-stderr hwe_vm vm_up --uncommited     # note the typo
    assert_failure
    [[ "$stderr" == *"unknown vm up flag"* ]]

    run --separate-stderr hwe_vm vm_up one two
    assert_failure
    [[ "$stderr" == *"at most one branch"* ]]
}

@test "vm usage documents --uncommitted" {
    run --separate-stderr hwe_vm vm_usage
    assert_success
    [[ "$stderr" == *"--uncommitted"* ]]
}

@test "the seed ISO is copied into the pool root-only, the disk with the default mode" {
    # The pool dir is world-traversable and the seed carries the guest password,
    # so it must not be world-readable. A fake sudo runs install as the test user.
    local fakebin="$BATS_TEST_TMPDIR/fakebin"; mkdir -p "$fakebin"
    printf '#!/usr/bin/env bash\nexec "$@"\n' > "$fakebin/sudo"; chmod +x "$fakebin/sudo"
    printf 'x' > "$BATS_TEST_TMPDIR/src"
    export FAKEBIN="$fakebin" T="$BATS_TEST_TMPDIR"
    run --separate-stderr bash -c '
        set -euo pipefail
        export PATH="$FAKEBIN:$PATH"
        HWE_ROOT="$HWE_REPO_ROOT"
        source "$HWE_ROOT/lib/common.sh"
        source "$HWE_ROOT/lib/vm.sh"
        _pool_put "$T/src" "$T/seed" 0600
        _pool_put "$T/src" "$T/disk"
        printf "seed=%s disk=%s\n" "$(stat -c %a "$T/seed")" "$(stat -c %a "$T/disk")"
    '
    assert_success
    assert_output "seed=600 disk=644"
}

@test "vm rebuild confirms, destroys and rebuilds when the VM exists" {
    run --separate-stderr bash -c '
        set -euo pipefail
        HWE_ROOT="$HWE_REPO_ROOT"
        source "$HWE_ROOT/lib/common.sh"
        source "$HWE_ROOT/lib/vm.sh"
        _virsh() { return 0; }                 # the VM exists
        vm_destroy_quiet() { echo DESTROYED; }
        vm_up() { echo "UP $*"; }
        HWE_ASSUME_YES=1 vm_rebuild feature-x
    '
    assert_success
    [[ "$output" == *"DESTROYED"* ]]
    [[ "$output" == *"UP feature-x"* ]]
}

@test "vm rebuild declined destroys nothing and does not build" {
    run --separate-stderr bash -c '
        set -euo pipefail
        HWE_ROOT="$HWE_REPO_ROOT"
        source "$HWE_ROOT/lib/common.sh"
        source "$HWE_ROOT/lib/vm.sh"
        _virsh() { return 0; }                 # the VM exists
        vm_destroy_quiet() { echo DESTROYED; }
        vm_up() { echo "UP $*"; }
        vm_rebuild feature-x </dev/null        # confirm hits EOF -> declines
    '
    assert_success
    [[ "$output" != *"DESTROYED"* ]]
    [[ "$output" != *"UP"* ]]
    [[ "$stderr" == *"cancelled"* ]]
}

@test "vm rebuild with no such VM builds fresh, destroying nothing" {
    run --separate-stderr bash -c '
        set -euo pipefail
        HWE_ROOT="$HWE_REPO_ROOT"
        source "$HWE_ROOT/lib/common.sh"
        source "$HWE_ROOT/lib/vm.sh"
        _virsh() { return 1; }                 # nothing exists
        vm_destroy_quiet() { echo DESTROYED; }
        vm_up() { echo "UP $*"; }
        vm_rebuild </dev/null
    '
    assert_success
    [[ "$output" != *"DESTROYED"* ]]
    [[ "$output" == *"UP"* ]]
    [[ "$stderr" == *"building it fresh"* ]]
}
