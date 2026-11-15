#!/usr/bin/env bats
# bin/build-ubuntu-cloud — safe CLI and artifact boundaries; no root/network here.

bats_require_minimum_version 1.5.0

setup() {
    load 'helper'
    hwe_setup
}

@test "the Ubuntu cloud builder is executable and documents its output" {
    [ -x "$HWE_ROOT/bin/build-ubuntu-cloud" ]
    run "$HWE_ROOT/bin/build-ubuntu-cloud" --help
    assert_success
    assert_output --partial "Ubuntu 27.04"
    assert_output --partial "build/ubuntu-cloud/ubuntu-27.04-server-cloudimg-amd64.img"
    assert_output --partial "installed into HWE's VM cache"
}

@test "the Ubuntu cloud builder rejects unknown arguments before building" {
    run "$HWE_ROOT/bin/build-ubuntu-cloud" --unknown
    assert_failure
    assert_output --partial "unknown argument: --unknown"
}

@test "every Ubuntu cloud build artifact is ignored" {
    local path
    for path in \
        build/ubuntu-cloud/downloads/tenacious-base-amd64.tar.gz \
        build/ubuntu-cloud/work/rootfs/etc/os-release \
        build/ubuntu-cloud/ubuntu-27.04-server-cloudimg-amd64.img \
        build/ubuntu-cloud/ubuntu-27.04-server-cloudimg-amd64.img.manifest; do
        run git -C "$HWE_ROOT" check-ignore -q "$path"
        assert_success
    done
}

@test "the embedded Ubuntu CD key has the pinned fingerprint" {
    mkdir -p "$BATS_TEST_TMPDIR/gnupg"
    chmod 700 "$BATS_TEST_TMPDIR/gnupg"
    run --separate-stderr bash -c "gpg --homedir '$BATS_TEST_TMPDIR/gnupg' --batch --show-keys --with-colons '$HWE_ROOT/provision/ubuntu-cdimage.asc' | awk -F: '\$1 == \"fpr\" {print \$10; exit}'"
    assert_success
    assert_output "843938DF228D22F7B3742BC0D94AA3F0EFE21092"
}

@test "the Ubuntu cloud builder installs the initramfs and resolved services" {
    run grep -F 'systemd-sysv linux-virtual initramfs-tools grub-pc cloud-init cloud-guest-utils' \
        "$HWE_ROOT/bin/build-ubuntu-cloud"
    assert_success
    run grep -F 'openssh-server sudo qemu-guest-agent netplan.io locales systemd-resolved' \
        "$HWE_ROOT/bin/build-ubuntu-cloud"
    assert_success
}

@test "the Ubuntu cloud builder installs the finished image into the VM cache" {
    run grep -F 'run install -Dm644 "$OUTPUT" "$CACHE_IMAGE"' \
        "$HWE_ROOT/bin/build-ubuntu-cloud"
    assert_success
}

@test "the Ubuntu cloud builder validates every file needed for a BIOS boot" {
    local expected
    for expected in \
        '[[ -s "$ROOTFS/boot/$KERNEL" ]] || die "guest kernel is missing: /boot/$KERNEL"' \
        '[[ -s "$ROOTFS/boot/$INITRD" ]] || die "guest initramfs is missing: /boot/$INITRD"' \
        '[[ -s "$ROOTFS/boot/grub/i386-pc/normal.mod" ]]' \
        '[[ -s "$ROOTFS/boot/grub/grub.cfg" ]] || die "generated grub.cfg is empty"' \
        'chroot_run grub-script-check /boot/grub/grub.cfg'; do
        run grep -F "$expected" "$HWE_ROOT/bin/build-ubuntu-cloud"
        assert_success
    done
}

@test "the Ubuntu cloud builder installs the boot files after cleaning the guest" {
    local clean_line grub_line
    clean_line="$(grep -nF 'cloud-init clean --logs --machine-id' "$HWE_ROOT/bin/build-ubuntu-cloud" | cut -d: -f1)"
    grub_line="$(grep -nF 'chroot_run grub-install --target=i386-pc' "$HWE_ROOT/bin/build-ubuntu-cloud" | cut -d: -f1)"
    [ -n "$clean_line" ]
    [ -n "$grub_line" ]
    [ "$clean_line" -lt "$grub_line" ]
}

@test "the Ubuntu cloud builder settles the ext4 journal before exporting the disk" {
    local sync_line unmount_line all_targets_line detach_line fsck_line convert_line
    sync_line="$(grep -nF 'run sudo sync -f "$ROOTFS"' "$HWE_ROOT/bin/build-ubuntu-cloud" | cut -d: -f1)"
    unmount_line="$(grep -nF 'run sudo umount -R "$ROOTFS"' "$HWE_ROOT/bin/build-ubuntu-cloud" | tail -1 | cut -d: -f1)"
    all_targets_line="$(grep -nF 'run sudo umount -A "${LOOP}p2"' "$HWE_ROOT/bin/build-ubuntu-cloud" | cut -d: -f1)"
    detach_line="$(grep -nF 'run sudo losetup -d "$LOOP"' "$HWE_ROOT/bin/build-ubuntu-cloud" | cut -d: -f1)"
    fsck_line="$(grep -nF 'e2fsck -fy "$ROOT_PART"' "$HWE_ROOT/bin/build-ubuntu-cloud" | cut -d: -f1)"
    convert_line="$(grep -nF 'qemu-img convert -f raw -O qcow2' "$HWE_ROOT/bin/build-ubuntu-cloud" | cut -d: -f1)"
    [ -n "$sync_line" ]
    [ -n "$unmount_line" ]
    [ -n "$all_targets_line" ]
    [ -n "$detach_line" ]
    [ -n "$fsck_line" ]
    [ -n "$convert_line" ]
    [ "$sync_line" -lt "$unmount_line" ]
    [ "$unmount_line" -lt "$all_targets_line" ]
    [ "$all_targets_line" -lt "$detach_line" ]
    [ "$detach_line" -lt "$fsck_line" ]
    [ "$fsck_line" -lt "$convert_line" ]
}

@test "the Ubuntu cloud builder verifies GRUB after unmounting the root filesystem" {
    run grep -F "debugfs -R 'stat /boot/grub/i386-pc/normal.mod'" \
        "$HWE_ROOT/bin/build-ubuntu-cloud"
    assert_success
    run grep -F "debugfs -R 'cat /boot/grub/grub.cfg'" \
        "$HWE_ROOT/bin/build-ubuntu-cloud"
    assert_success
}

@test "cloud-init preserves release sources and leaves Netplan to HWE" {
    run grep -Fx '  preserve_sources_list: true' \
        "$HWE_ROOT/provision/cloud-init/user-data.tmpl"
    assert_success
    run grep -F "'  config: disabled'" "$HWE_ROOT/bin/build-ubuntu-cloud"
    assert_success
}

@test "the Ubuntu guest logs boot and cloud-init to both consoles" {
    run grep -F 'ro console=tty0 console=ttyS0,115200n8' \
        "$HWE_ROOT/bin/build-ubuntu-cloud"
    assert_success
    run grep -F 'quiet splash' "$HWE_ROOT/bin/build-ubuntu-cloud"
    assert_failure
}
