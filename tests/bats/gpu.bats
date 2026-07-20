#!/usr/bin/env bats
# provision/guest-install.sh — the NVIDIA setup logic.
#
# The install itself touches packages and the boot chain, so it lives in the VM,
# not here. But the two decisions that decide whether a stranger's NVIDIA machine
# boots — which driver package, and how MODULES gets edited — are pure functions,
# and pure functions we can pin without any NVIDIA hardware or root. That is the
# whole point of factoring them out: the untestable path gets a tested core.

bats_require_minimum_version 1.5.0

setup() {
    load 'helper'
    hwe_setup
}

# Sourcing guest-install.sh with HWE_ROOT already set skips its bootstrap block
# and (via the BASH_SOURCE guard) never runs install_main — we just get the
# function definitions. The pure functions below use only case/grep/sed.
load_install() {
    source "$HWE_ROOT/provision/guest-install.sh"
}

# --- driver selection ------------------------------------------------------

@test "Turing and newer codenames select the open kernel modules" {
    load_install
    for cn in TU116 GA104 AD102 GH100 GB202; do
        run _nvidia_driver_for_codename "$cn"
        assert_success
        assert_output "nvidia-open-dkms"
    done
}

@test "pre-Turing codenames (incl. Volta) select the proprietary series" {
    load_install
    for cn in GP104 GM206 GK110 GF119 GV100; do
        run _nvidia_driver_for_codename "$cn"
        assert_success
        assert_output "nvidia-dkms"
    done
}

@test "codename matching is case-insensitive" {
    load_install
    run _nvidia_driver_for_codename "ga104"
    assert_success
    assert_output "nvidia-open-dkms"
}

@test "an unknown or blank codename falls back to the broad package, non-zero status" {
    load_install
    run _nvidia_driver_for_codename ""
    assert_failure
    assert_output "nvidia-dkms"
    run _nvidia_driver_for_codename "XX999"
    assert_failure
    assert_output "nvidia-dkms"
}

# --- mkinitcpio MODULES edit ----------------------------------------------

@test "modules are added to an empty MODULES line" {
    load_install
    local f="$BATS_TEST_TMPDIR/mkinitcpio.conf"
    printf 'MODULES=()\nHOOKS=(base udev)\n' > "$f"
    run _mkinitcpio_add_nvidia_modules "$f"
    assert_success
    run grep -E '^MODULES=\(.*nvidia nvidia_modeset nvidia_uvm nvidia_drm.*\)$' "$f"
    assert_success
    # HOOKS and everything else is left alone.
    run grep -qx 'HOOKS=(base udev)' "$f"
    assert_success
}

@test "existing modules are preserved" {
    load_install
    local f="$BATS_TEST_TMPDIR/mkinitcpio.conf"
    printf 'MODULES=(ext4 foo)\n' > "$f"
    _mkinitcpio_add_nvidia_modules "$f"
    run grep -q 'MODULES=(ext4 foo nvidia nvidia_modeset nvidia_uvm nvidia_drm)' "$f"
    assert_success
}

@test "the edit is idempotent — a second run is a no-op with status 2" {
    load_install
    local f="$BATS_TEST_TMPDIR/mkinitcpio.conf"
    printf 'MODULES=()\n' > "$f"
    _mkinitcpio_add_nvidia_modules "$f"
    run _mkinitcpio_add_nvidia_modules "$f"
    assert_equal "$status" 2
    run grep -c 'nvidia_drm' "$f"
    assert_output "1"
}

@test "a missing MODULES line is left untouched and reported (status 1)" {
    load_install
    local f="$BATS_TEST_TMPDIR/mkinitcpio.conf"
    printf 'HOOKS=(base udev)\n' > "$f"
    run _mkinitcpio_add_nvidia_modules "$f"
    assert_equal "$status" 1
    run grep -q nvidia "$f"
    assert_failure
}

# --- the caller's errexit safety (regression) ------------------------------
# The pure functions above return non-zero on their fallback paths BY DESIGN.
# _setup_nvidia runs under `set -e` (from bin/hwe), so a bare `cn=$(_nvidia_
# codename)` or `f; rc=$?` used to abort the whole install on exactly the
# machines those fallbacks exist for. These pin that the caller absorbs it.

@test "an empty codename drives _setup_nvidia to its default arm, not an abort" {
    run bash -c '
        set -euo pipefail
        HWE_ROOT="'"$HWE_ROOT"'"
        source "$HWE_ROOT/lib/common.sh"       # warn/info/confirm/run live here
        source "$HWE_ROOT/provision/guest-install.sh"
        systemd-detect-virt() { return 1; }   # pretend bare metal
        _nvidia_gpu_present()  { return 0; }
        _distro_family()       { echo pacman; }
        _nvidia_codename()     { return 1; }   # old hwdata: empty codename, non-zero status
        _setup_nvidia </dev/null               # confirm hits EOF, declines, returns 0 cleanly
    '
    assert_success
    [[ "$output" == *"generation is unreadable"* ]]
}

@test "a pinned HWE_NVIDIA_DRIVER selects it without probing the codename" {
    run bash -c '
        set -euo pipefail
        HWE_ROOT="'"$HWE_ROOT"'"
        export HWE_NVIDIA_DRIVER=nvidia-open-dkms
        source "$HWE_ROOT/lib/common.sh"
        source "$HWE_ROOT/provision/guest-install.sh"
        systemd-detect-virt() { return 1; }
        _nvidia_gpu_present()  { return 0; }
        _distro_family()       { echo pacman; }
        _nvidia_codename()     { echo "SHOULD-NOT-BE-CALLED"; }
        _setup_nvidia </dev/null
    '
    assert_success
    [[ "$output" == *"nvidia-open-dkms"* ]]
    [[ "$output" != *"SHOULD-NOT-BE-CALLED"* ]]
}
