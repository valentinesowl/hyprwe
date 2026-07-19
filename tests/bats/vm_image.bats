#!/usr/bin/env bats
# lib/vm.sh — choosing a guest distribution, and refusing an image nobody signed.
#
# Ubuntu publishes authenticity differently from Arch: one SHA256SUMS covering a
# whole release directory, detached-signed as SHA256SUMS.gpg. An image is
# therefore authentic only when BOTH hold — the signature verifies, and the
# image's own line is in the file that was signed. Each half is tested by
# breaking it, because a check whose failure you have never seen is not a check.
#
# Entirely offline: the tests mint their own signing key and sign their own
# SHA256SUMS, so what is under test is our logic, not Canonical's uptime.

bats_require_minimum_version 1.5.0

setup() {
    load 'helper'
    hwe_setup
    export HWE_REPO_ROOT="$HWE_ROOT"
    export RING="$BATS_TEST_TMPDIR/signer"
    mkdir -p "$RING"; chmod 700 "$RING"
}

# Run a vm.sh function in a subshell, as tests/bats/vm.bats does and for the same
# reason: lib/common.sh defines its own `run`, which would shadow bats' `run`.
hwe_vm() {
    bash -c '
        set -uo pipefail
        HWE_ROOT="$HWE_REPO_ROOT"
        source "$HWE_ROOT/lib/common.sh"
        source "$HWE_ROOT/lib/vm.sh"
        HWE_GNUPGHOME="$TEST_GNUPGHOME"
        HWE_VM_KEY_FP="$TEST_FP"
        HWE_VM_KEY_FILE="$TEST_KEYFILE"
        HWE_VM_KEY_NAME="test signer"
        HWE_VM_KEYSERVERS=""        # no network: a refusal must not hang on DNS
        fn="$1"; shift
        "$fn" "$@"
    ' _ "$@"
}

# Read a vm.sh variable under a given HWE_VM_DISTRO, without running anything.
vm_var() {
    HWE_VM_DISTRO="$1" bash -c '
        set -uo pipefail
        HWE_ROOT="$HWE_REPO_ROOT"
        source "$HWE_ROOT/lib/common.sh"
        source "$HWE_ROOT/lib/vm.sh"
        printf "%s\n" "${!1}"
    ' _ "$2"
}

# A throwaway signing key + a SHA256SUMS it signs, covering $1 (a real file).
make_signed_sums() {
    local target="$1"
    gpg --homedir "$RING" --batch --no-tty --passphrase '' \
        --quick-gen-key 'HWE Test Signer <test@example.invalid>' default default never >/dev/null 2>&1
    TEST_FP="$(gpg --homedir "$RING" --batch --with-colons --list-keys \
        | awk -F: '/^fpr:/ {print $10; exit}')"
    TEST_KEYFILE="$BATS_TEST_TMPDIR/signer.asc"
    gpg --homedir "$RING" --batch --no-tty --armor --export "$TEST_FP" > "$TEST_KEYFILE"

    SUMS="$BATS_TEST_TMPDIR/SHA256SUMS"
    # sha256sum's binary-mode spelling, which is what Ubuntu publishes.
    printf '%s *%s\n' "$(sha256sum "$target" | awk '{print $1}')" "$(basename "$target")" > "$SUMS"
    printf '%s *%s\n' "0000000000000000000000000000000000000000000000000000000000000000" "some-other-image.img" >> "$SUMS"
    gpg --homedir "$RING" --batch --no-tty --detach-sign --output "$SUMS.gpg" "$SUMS" 2>/dev/null

    TEST_GNUPGHOME="$BATS_TEST_TMPDIR/verify-ring"
    export TEST_FP TEST_KEYFILE TEST_GNUPGHOME SUMS
}

@test "each distro gets its own domain, so both can exist at once" {
    assert_equal "$(vm_var arch HWE_VM_NAME)" "hwe-dev"
    assert_equal "$(vm_var ubuntu HWE_VM_NAME)" "hwe-dev-ubuntu"
}

@test "each distro declares how its image is authenticated" {
    assert_equal "$(vm_var arch HWE_VM_SIGSTYLE)" "detached"
    assert_equal "$(vm_var ubuntu HWE_VM_SIGSTYLE)" "sumsfile"
}

@test "the pinned key each distro names is actually shipped" {
    local d
    for d in arch ubuntu; do
        [ -f "$(vm_var "$d" HWE_VM_KEY_FILE)" ]
    done
}

@test "the shipped Ubuntu key file contains the fingerprint vm.sh pins" {
    local fp file
    fp="$(vm_var ubuntu HWE_VM_KEY_FP)"
    file="$(vm_var ubuntu HWE_VM_KEY_FILE)"
    run gpg --batch --no-tty --no-default-keyring --show-keys --with-colons "$file"
    assert_success
    [[ "$output" == *"$fp"* ]]
}

@test "an unknown guest distro is refused rather than quietly treated as Arch" {
    run env HWE_VM_DISTRO=nosuchdistro "$HWE_REPO_ROOT/bin/hwe" vm status
    assert_failure
    [[ "$output" == *"nosuchdistro"* ]]
}

@test "a genuine image passes: valid signature and its line in the signed file" {
    printf 'pretend cloud image\n' > "$BATS_TEST_TMPDIR/img.img"
    make_signed_sums "$BATS_TEST_TMPDIR/img.img"
    HWE_IMAGE_URL="https://example.invalid/img.img" \
        run hwe_vm _vm_verify_sums "$BATS_TEST_TMPDIR/img.img" "$SUMS" "$SUMS.gpg"
    assert_success
}

@test "an image whose bytes changed is refused" {
    printf 'pretend cloud image\n' > "$BATS_TEST_TMPDIR/img.img"
    make_signed_sums "$BATS_TEST_TMPDIR/img.img"
    printf 'tampered\n' >> "$BATS_TEST_TMPDIR/img.img"
    HWE_IMAGE_URL="https://example.invalid/img.img" \
        run hwe_vm _vm_verify_sums "$BATS_TEST_TMPDIR/img.img" "$SUMS" "$SUMS.gpg"
    assert_failure
    [[ "$output" == *"mismatch"* ]]
}

# The one that matters most: the signature is perfectly valid, and says nothing
# whatsoever about this image. Left implicit, a lookup that finds no line reads
# exactly like a check that found nothing wrong.
@test "an image absent from the signed file is refused, not silently accepted" {
    printf 'pretend cloud image\n' > "$BATS_TEST_TMPDIR/img.img"
    make_signed_sums "$BATS_TEST_TMPDIR/img.img"
    HWE_IMAGE_URL="https://example.invalid/never-listed.img" \
        run hwe_vm _vm_verify_sums "$BATS_TEST_TMPDIR/img.img" "$SUMS" "$SUMS.gpg"
    assert_failure
    [[ "$output" == *"no line in the signed SHA256SUMS"* ]]
}

@test "a tampered SHA256SUMS is refused before its numbers are believed" {
    printf 'pretend cloud image\n' > "$BATS_TEST_TMPDIR/img.img"
    make_signed_sums "$BATS_TEST_TMPDIR/img.img"
    # Swap in the real hash of a DIFFERENT file: the numbers now "match" the
    # image we are about to check, but nobody signed this version of the list.
    printf '%s *%s\n' "$(sha256sum "$BATS_TEST_TMPDIR/img.img" | awk '{print $1}')" "img.img" > "$SUMS"
    HWE_IMAGE_URL="https://example.invalid/img.img" \
        run hwe_vm _vm_verify_sums "$BATS_TEST_TMPDIR/img.img" "$SUMS" "$SUMS.gpg"
    assert_failure
    [[ "$output" == *"not signed by the pinned"* ]]
}

@test "verification fails closed when the pinned key cannot be obtained" {
    printf 'pretend cloud image\n' > "$BATS_TEST_TMPDIR/img.img"
    make_signed_sums "$BATS_TEST_TMPDIR/img.img"
    TEST_KEYFILE="$BATS_TEST_TMPDIR/nonexistent.asc"   # and no keyservers
    HWE_IMAGE_URL="https://example.invalid/img.img" \
        run hwe_vm _vm_verify_sums "$BATS_TEST_TMPDIR/img.img" "$SUMS" "$SUMS.gpg"
    assert_failure
    [[ "$output" == *"could not obtain the pinned"* ]]
}

# ── finding the VM you meant ──────────────────────────────────────────────
# One VM per distro means the domain name is no longer a constant. Forgetting
# HWE_VM_DISTRO used to produce a raw libvirt error naming a domain the user
# never asked about. Resolution fixes that — but it must never resolve ACROSS an
# explicit choice, since this code path also reaches `destroy`.

# Run _vm_resolve_target against a simulated set of existing domains. $1 is that
# set; $2 (optional) overrides which names HWE considers its own.
resolve_against() {
    EXISTING="$1" NAMES="${2:-}" bash -c '
        set -uo pipefail
        HWE_ROOT="$HWE_REPO_ROOT"
        source "$HWE_ROOT/lib/common.sh"
        source "$HWE_ROOT/lib/vm.sh"
        [[ -n "$NAMES" ]] && HWE_VM_NAMES_ALL="$NAMES"
        # Stand in for libvirt: a domain exists iff it is in $EXISTING.
        _virsh() {
            [[ "${1:-}" == dominfo ]] || return 1
            local d
            for d in $EXISTING; do [[ "$d" == "${2:-}" ]] && return 0; done
            return 1
        }
        _vm_resolve_target status || exit 1
        printf "RESOLVED=%s\n" "$HWE_VM_NAME"
    ' _
}

@test "with one VM and no choice made, that VM is the one acted on" {
    run resolve_against "hwe-dev-ubuntu"
    assert_success
    [[ "$output" == *"RESOLVED=hwe-dev-ubuntu"* ]]
    [[ "$output" == *"using the one that exists"* ]]
}

@test "an explicitly chosen VM is never silently swapped for another" {
    HWE_VM_DISTRO=arch run resolve_against "hwe-dev-ubuntu"
    assert_failure
    [[ "$output" == *"hwe-dev"* ]]
    [[ "$output" != *"RESOLVED="* ]]
}

@test "an explicit HWE_VM_NAME is honoured the same way" {
    HWE_VM_NAME=hwe-dev-ubuntu run resolve_against "hwe-dev-ubuntu"
    assert_success
    [[ "$output" == *"RESOLVED=hwe-dev-ubuntu"* ]]
    # It existed, so nothing was resolved on the user's behalf.
    [[ "$output" != *"using the one that exists"* ]]
}

@test "when the default VM exists it is used, not second-guessed" {
    run resolve_against "hwe-dev hwe-dev-ubuntu"
    assert_success
    [[ "$output" == *"RESOLVED=hwe-dev"* ]]
}

# Unreachable with two distros — the default name IS one of the two — but this is
# the branch that decides behaviour the day a third arrives, and an untested
# branch is where the wrong default hides.
@test "with several candidates and no choice made, it refuses and lists them" {
    # The default target (hwe-dev) is deliberately absent, so resolution has to
    # choose between the two that do exist — and must decline to.
    run resolve_against \
        "hwe-dev-ubuntu hwe-dev-fedora" "hwe-dev hwe-dev-ubuntu hwe-dev-fedora"
    assert_failure
    [[ "$output" != *"RESOLVED="* ]]
    [[ "$output" == *"several HWE VMs exist"* ]]
    [[ "$output" == *"hwe-dev-ubuntu"* ]]
    [[ "$output" == *"hwe-dev-fedora"* ]]
}

@test "with no VM at all it says how to make one" {
    run resolve_against ""
    assert_failure
    [[ "$output" == *"no HWE VM exists yet"* ]]
    [[ "$output" == *"hwe vm up"* ]]
}
