# Disposable VM rehearsal

**English** · [Русский](VM.ru.md) · [Back to the project](../README.md)

`hwe vm up` brings up a **disposable** Arch **or Ubuntu** VM, visible in virt-manager, and
deploys **your local git branch** into it, straight from your own repository. Inside, the
same `hwe install` runs as on bare metal, so it is an honest rehearsal of the installation.

## Commands

```bash
# 0. Check the host (libvirtd, groups, network, KVM)
./bin/hwe doctor vm

# 1. Bring up a VM with the current branch (or name one)
./bin/hwe vm up
./bin/hwe vm up feature-x

# 1b. Or deploy the working tree as it is, before committing anything
./bin/hwe vm up --uncommitted

# 1c. Ubuntu 27.04 (experimental): build the local base image first
./bin/build-ubuntu-cloud
HWE_VM_DISTRO=ubuntu ./bin/hwe vm up --uncommitted

# 2. Get inside (once cloud-init has finished)
./bin/hwe vm ssh
./bin/hwe vm console      # or watch it boot in virt-manager
./bin/hwe vm status       # state + IP

# 3. Rebuild from scratch / tear down
./bin/hwe vm rebuild
./bin/hwe vm destroy
```

By default the VM gets the branch's last commit. `--uncommitted` deploys the working tree
instead — modified, staged, deleted and new files included — so a change can be tested
before it is committed. The snapshot is built through a separate index and a temporary
`--shared` clone: your index, working tree and branches do not move, and no commit appears
in your history. Ignored files stay behind; the guest regenerates them.

Logging into the VM: user **`hwe`**, password **printed by `vm up`** (random, per build).
Your `~/.ssh/id_*.pub` keys are passed into the guest automatically — normally you log in
by key, and the password is left for the console only. Configs inside the VM are deployed
as **symlinks** into the repository, so edits in `~/hwe/config/...` are visible immediately.

## How it works

1. Arch's cloud image is downloaded into `~/.cache/hwe/` and verified against the pinned
   arch-boxes fingerprint. For Ubuntu 27.04, `bin/build-ubuntu-cloud` verifies Canonical's
   signed Ubuntu Base `SHA256SUMS` with a pinned CD-image key, builds the local NoCloud-ready
   image and installs it into the same cache. An input hyprwe cannot authenticate is refused.
2. It makes a `git bundle` of the chosen branch — or, with `--uncommitted`, of a throwaway
   snapshot of your working tree — and puts it on a **NoCloud seed ISO** (`xorriso`).
3. `virt-install --import` creates a **libvirt domain** (visible in virt-manager).
4. `cloud-init` in the guest creates the user, mounts the seed, does a `git clone` from the
   bundle and runs `hwe install` — the machine brings itself up, from image to finished desktop.
   Arch guests fully upgrade the base image before bootstrap packages are installed, avoiding
   unsupported partial upgrades on old cloud snapshots.

## Overrides

| Variable | Default | Purpose |
|---|---|---|
| `HWE_VM_DISTRO` | `arch` | guest distribution: `arch` or `ubuntu` |
| `HWE_VM_UBUNTU_RELEASE` | `27.04` | experimental Ubuntu release to fetch |
| `HWE_HYPR_SOURCE` | `repo` | where the guest's Hyprland comes from: `repo` or `ppa` |
| `HWE_VM_NAME` | per distro | libvirt domain name (`hwe-dev`, `hwe-dev-ubuntu`) |
| `HWE_VM_MEMORY` | `4096` | RAM, MiB |
| `HWE_VM_VCPUS` | `4` | vCPUs |
| `HWE_VM_DISK_SIZE` | `24G` | root disk size |
| `HWE_VM_USER` | `hwe` | user name in the guest |
| `HWE_VM_PASSWORD` | *random* | password (set it to pin one) |
| `HWE_LIBVIRT_URI` | `qemu:///system` | libvirt URI (the virt-manager default) |
| `HWE_VM_NETWORK` | `default` | libvirt network name |
| `HWE_IMAGE_URL` | per distro | base image (signed; an unverifiable one is refused) |

Ubuntu 27.04 remains experimental. The Arch and Ubuntu paths have each been verified
end-to-end in their tested x86_64 libvirt/QEMU configurations, not on every possible host.
