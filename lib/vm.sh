#!/usr/bin/env bash
# lib/vm.sh — libvirt/virt-manager-compatible dev VM for HWE.
#
# Defines a proper libvirt domain via virt-install (shows up in virt-manager) and
# provisions fully automatically via cloud-init. The selected LOCAL git branch is
# shipped into the guest as a git bundle on the NoCloud seed ISO — no GitHub push.
#
# Sourced by bin/hwe; relies on helpers from lib/common.sh.

# --- Tunables (override via environment) ----------------------------------
: "${HWE_LIBVIRT_URI:=qemu:///system}"
: "${HWE_VM_MEMORY:=4096}"          # MiB
: "${HWE_VM_VCPUS:=4}"
: "${HWE_VM_DISK_SIZE:=24G}"        # resized-to size of the root disk
: "${HWE_VM_USER:=hwe}"
# Random per-build password (printed at `vm up`), not a well-known default. Drawn
# from the kernel CSPRNG (/dev/urandom via od), NOT $RANDOM — a 15-bit, non-crypto
# PRNG. od reads the device directly (no pipe SIGPIPE under pipefail); 9 bytes ->
# 18 hex chars ~= 72 bits. With SSH keys shipped, password auth is disabled, so
# this only guards the local console — but a guessable guard is still no guard.
: "${HWE_VM_PASSWORD:=$(od -An -N9 -tx1 /dev/urandom | tr -d ' \n')}"
: "${HWE_VM_NETWORK:=default}"      # libvirt network name (system URI)

# --- Which distribution the guest runs ------------------------------------
# lib/distro.sh is one half of running on more than Arch — what HWE does once it
# is on a machine. This is the other half: which machine it lands on. Each
# distro gets its OWN domain name and disk, so an Arch VM and an Ubuntu one
# coexist; the point of the port is comparing them, which a single VM that gets
# rebuilt into the other distro cannot do.
#
# Everything that differs is gathered here — image URL, how upstream publishes
# authenticity, which key vouches for it, and what to tell libosinfo. Adding a
# third distro is another arm, not another code path.
#
# Record whether the caller NAMED a target before we default one, so the actions
# that operate on an existing VM can tell "you asked for this one" from "you did
# not say" — see _vm_resolve_target.
[[ -n "${HWE_VM_DISTRO+x}" ]] && HWE_VM_TARGET_NAMED=1
[[ -n "${HWE_VM_NAME+x}" ]]   && HWE_VM_TARGET_NAMED=1
: "${HWE_VM_TARGET_NAMED:=}"
: "${HWE_VM_DISTRO:=arch}"
: "${HWE_VM_UBUNTU_RELEASE:=26.04}"

# Every domain name HWE itself creates. Used to find the VM you meant when you
# did not say which — never to guess between two of them.
HWE_VM_NAMES_ALL="hwe-dev hwe-dev-ubuntu"

# Pinned signing keys. A fingerprint is the key's own hash, so pinning it means a
# keyserver can hand us a key but never a DIFFERENT key.
: "${HWE_ARCHBOX_FP:=1B9A16984A4E8CB448712D2AE0B78BF4326C6F8F}"
: "${HWE_UBUNTU_FP:=D2EB44626FDDC30B513D5BB71A5D6C4C7DB87C81}"

case "$HWE_VM_DISTRO" in
    arch)
        : "${HWE_VM_NAME:=hwe-dev}"
        : "${HWE_IMAGE_URL:=https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2}"
        # arch-boxes signs each image with a detached .sig beside it.
        HWE_VM_SIGSTYLE=detached
        HWE_VM_KEY_FP="$HWE_ARCHBOX_FP"
        HWE_VM_KEY_FILE="$HWE_ROOT/provision/arch-boxes.asc"
        HWE_VM_KEY_NAME="arch-boxes"
        HWE_VM_OSINFO=archlinux
        HWE_VM_ADMIN_GROUP=wheel
        HWE_VM_SHELL=/usr/bin/bash
        ;;
    ubuntu)
        : "${HWE_VM_NAME:=hwe-dev-ubuntu}"
        : "${HWE_IMAGE_URL:=https://cloud-images.ubuntu.com/releases/$HWE_VM_UBUNTU_RELEASE/release/ubuntu-$HWE_VM_UBUNTU_RELEASE-server-cloudimg-amd64.img}"
        # Ubuntu signs no image. It signs ONE SHA256SUMS covering the release
        # directory, detached as SHA256SUMS.gpg — so an image is authentic when
        # that signature verifies AND the image's own line is in the signed file.
        HWE_VM_SIGSTYLE=sumsfile
        HWE_VM_KEY_FP="$HWE_UBUNTU_FP"
        HWE_VM_KEY_FILE="$HWE_ROOT/provision/ubuntu-cloudimage.asc"
        HWE_VM_KEY_NAME="Ubuntu cloud images"
        HWE_VM_OSINFO="ubuntu$HWE_VM_UBUNTU_RELEASE"
        HWE_VM_ADMIN_GROUP=sudo
        HWE_VM_SHELL=/bin/bash
        ;;
    *)
        # Not fatal at source time — `hwe theme` should still work on a machine
        # with a typo'd HWE_VM_DISTRO exported. vm_main refuses instead.
        : "${HWE_VM_NAME:=hwe-dev}"
        : "${HWE_IMAGE_URL:=unsupported}"   # never fetched; keeps set -u happy below
        HWE_VM_SIGSTYLE=unsupported
        HWE_VM_ADMIN_GROUP=wheel
        HWE_VM_SHELL=/bin/bash
        ;;
esac

HWE_BASE_IMG="$HWE_CACHE/$(basename "$HWE_IMAGE_URL")"
HWE_POOL_DIR="/var/lib/libvirt/images/hwe"   # where per-VM disks/seed live (system URI)

# Force C locale so field names (Active:/ipv4/…) are parseable regardless of
# the host's language — otherwise localized virsh output breaks our greps.
_virsh() { LC_ALL=C virsh --connect "$HWE_LIBVIRT_URI" "$@"; }

# True if the target network is currently active. `net-list --name` lists only
# active networks by name — names are never localized, so this is locale-proof.
_vm_net_active() {
    _virsh net-list --name 2>/dev/null | grep -qx "$HWE_VM_NETWORK"
}

vm_usage() {
    cat >&2 <<EOF
${C_BOLD}hwe vm${C_RESET} — manage the local Hyprland dev VM

${C_BOLD}Usage:${C_RESET} hwe vm <action> [args]

${C_BOLD}Actions:${C_RESET}
  ${C_CYAN}up${C_RESET} [branch]     Create & boot a VM deploying the given local branch (default: current)
                  ${C_CYAN}--uncommitted${C_RESET}  deploy the working tree as it is now (uncommitted
                  changes and new files included) instead of the branch's last commit
  ${C_CYAN}ssh${C_RESET} [cmd...]    SSH into the running VM (optionally run a command)
  ${C_CYAN}console${C_RESET}         Attach to the serial console (Ctrl+] to detach)
  ${C_CYAN}status${C_RESET}          Show VM state and IP (once the guest agent answers)
  ${C_CYAN}list${C_RESET}           List HWE VMs known to libvirt
  ${C_CYAN}down${C_RESET}            Gracefully shut the VM down
  ${C_CYAN}destroy${C_RESET}        Remove the VM and its disks (irreversible)
  ${C_CYAN}rebuild${C_RESET} [br]    destroy (asks first) + up (fresh provision; takes --uncommitted too)
  ${C_CYAN}doctor${C_RESET}         Check host prerequisites

${C_BOLD}Guest distribution:${C_RESET} ${C_CYAN}HWE_VM_DISTRO${C_RESET}=$HWE_VM_DISTRO  (arch | ubuntu)
  Each distro gets its own domain and disk, so both can run side by side:
    ${C_BOLD}HWE_VM_DISTRO=ubuntu hwe vm up${C_RESET}   → domain 'hwe-dev-ubuntu'

${C_BOLD}Compositor source:${C_RESET} ${C_CYAN}HWE_HYPR_SOURCE${C_RESET}=$HWE_HYPR_SOURCE  (repo | ppa)
  ${C_DIM}repo${C_RESET} = the guest distribution's own Hyprland.
  ${C_DIM}ppa${C_RESET}  = a third-party archive, pinned to the Hyprland stack. Opt-in only.

${C_BOLD}Env overrides:${C_RESET} HWE_VM_NAME=$HWE_VM_NAME  HWE_VM_MEMORY=$HWE_VM_MEMORY
  HWE_VM_VCPUS=$HWE_VM_VCPUS  HWE_LIBVIRT_URI=$HWE_LIBVIRT_URI
EOF
}

vm_main() {
    local action="${1:-}"; shift || true
    # A typo'd HWE_VM_DISTRO must not silently build an Arch VM under an Ubuntu
    # name, nor reach the image code with no way to authenticate anything.
    if [[ "$HWE_VM_SIGSTYLE" == unsupported && "$action" != "" && "$action" != help && "$action" != -h && "$action" != --help ]]; then
        err "unknown HWE_VM_DISTRO='$HWE_VM_DISTRO'"
        info "HWE builds a VM from ${C_BOLD}arch${C_RESET} or ${C_BOLD}ubuntu${C_RESET} cloud images"
        return 1
    fi
    case "$action" in
        up)       vm_up "$@" ;;
        ssh)      vm_ssh "$@" ;;
        console)  _vm_resolve_target console && _virsh console "$HWE_VM_NAME" ;;
        status)   vm_status ;;
        list|ls)  vm_list ;;
        down|stop) _vm_resolve_target down && _virsh shutdown "$HWE_VM_NAME" && ok "shutdown signal sent" ;;
        destroy|rm) vm_destroy ;;
        rebuild)  vm_rebuild "$@" ;;
        doctor)   vm_doctor ;;
        ""|help|-h|--help) vm_usage ;;
        *) err "unknown vm action: $action"; vm_usage; return 1 ;;
    esac
}

# --- Host preflight -------------------------------------------------------
vm_doctor() {
    log "Checking host prerequisites for the HWE VM..."
    local fail=0
    need virt-install virt-install            || fail=1
    need virsh        libvirt                 || fail=1
    need qemu-img     qemu-base               || fail=1
    need xorriso      libisoburn              || fail=1
    need curl         curl                    || fail=1
    need git          git                     || fail=1
    need gpg          gnupg                   || fail=1

    # dnsmasq is an optdepend of libvirt but is required for the default NAT
    # network's DHCP/DNS — without it `virsh net-start default` fails.
    if command -v dnsmasq >/dev/null 2>&1; then
        ok "dnsmasq present (NAT DHCP/DNS)"
    else
        warn "dnsmasq missing — the 'default' NAT network cannot start"
        info "install: ${C_BOLD}sudo pacman -S dnsmasq && sudo systemctl restart libvirtd${C_RESET}"
        fail=1
    fi

    if [[ -r /dev/kvm ]]; then ok "KVM acceleration available"
    else warn "no /dev/kvm — VM will be slow (enable virtualization in firmware)"; fi

    if systemctl is-active --quiet libvirtd 2>/dev/null; then
        ok "libvirtd is running"
    else
        warn "libvirtd is not running"
        info "start it: ${C_BOLD}sudo systemctl enable --now libvirtd${C_RESET}"
        fail=1
    fi

    if _virsh version >/dev/null 2>&1; then
        ok "can talk to $HWE_LIBVIRT_URI"
    else
        warn "cannot reach $HWE_LIBVIRT_URI without extra privileges"
        info "add yourself to the libvirt group: ${C_BOLD}sudo usermod -aG libvirt \$USER${C_RESET} (then re-login)"
        fail=1
    fi

    if _virsh net-info "$HWE_VM_NETWORK" >/dev/null 2>&1; then
        if _vm_net_active; then
            ok "libvirt network '$HWE_VM_NETWORK' is active"
        else
            warn "libvirt network '$HWE_VM_NETWORK' is inactive"
            info "fix it: ${C_BOLD}sudo virsh net-autostart $HWE_VM_NETWORK && sudo virsh net-start $HWE_VM_NETWORK${C_RESET}"
        fi
    else
        warn "libvirt network '$HWE_VM_NETWORK' not defined"
    fi

    # if/else, not `A && B || C`: the latter also runs C when B fails, so a
    # non-zero `ok` would report failure on a host that is in fact ready.
    if [[ $fail -eq 0 ]]; then
        ok "host looks ready"
    else
        err "some prerequisites are missing (see above)"
        return 1
    fi
}

# Ensure libvirt is usable; auto-fix the cheap bits with consent.
_vm_ensure_ready() {
    need virt-install virt-install || return 1
    need qemu-img && need xorriso && need git && need curl || return 1
    need gpg gnupg || return 1   # verify the base image signature

    if ! systemctl is-active --quiet libvirtd 2>/dev/null; then
        warn "libvirtd is not running."
        if confirm "Enable and start libvirtd now (sudo)?"; then
            run sudo systemctl enable --now libvirtd
        else
            die "libvirtd is required."
        fi
    fi
    if ! _virsh version >/dev/null 2>&1; then
        die "cannot access $HWE_LIBVIRT_URI. Add yourself to the 'libvirt' group and re-login, or run: hwe doctor"
    fi
    # The default NAT network needs dnsmasq; fail early with a clear hint.
    if [[ "$HWE_VM_NETWORK" == default ]] && ! command -v dnsmasq >/dev/null 2>&1; then
        die "dnsmasq is required for the 'default' NAT network. Install it: sudo pacman -S dnsmasq && sudo systemctl restart libvirtd"
    fi
    _vm_ensure_network
}

# Make sure the NAT network exists, is active and autostarts (needed for VM IP).
_vm_ensure_network() {
    # Only the built-in 'default' network can be auto-defined from the template.
    if ! _virsh net-info "$HWE_VM_NETWORK" >/dev/null 2>&1; then
        if [[ "$HWE_VM_NETWORK" == default ]]; then
            local tmpl=/usr/share/libvirt/networks/default.xml
            if [[ -f "$tmpl" ]]; then
                info "defining libvirt network 'default'"
                _virsh net-define "$tmpl" >/dev/null 2>&1 || run sudo virsh net-define "$tmpl" || true
            fi
        else
            warn "libvirt network '$HWE_VM_NETWORK' is not defined — define it or set HWE_VM_NETWORK"
            return 0
        fi
    fi
    # Persist autostart first so a later libvirtd restart keeps the net up.
    _virsh net-autostart "$HWE_VM_NETWORK" >/dev/null 2>&1 \
        || sudo virsh net-autostart "$HWE_VM_NETWORK" >/dev/null 2>&1 || true
    if ! _vm_net_active; then
        info "starting libvirt network '$HWE_VM_NETWORK'"
        _virsh net-start "$HWE_VM_NETWORK" >/dev/null 2>&1 || run sudo virsh net-start "$HWE_VM_NETWORK" || true
    fi
}

# --- Base image authenticity ----------------------------------------------
# The cloud image becomes the VM's root disk (which boots with passwordless
# sudo), so a tampered or MITM'd download owns the guest. We refuse any image the
# distro's own key has not vouched for: the PRIMARY fingerprint pinned above +
# the pubkey shipped in-repo (provision/*.asc) so verification works offline.
#
# The two distros publish that vouching differently — arch-boxes signs the image,
# Ubuntu signs a checksum file listing it — so the SHAPE of the evidence differs
# while the rule does not. Everything below the keyring is shared.
HWE_GNUPGHOME="$HWE_CACHE/gnupg"          # isolated keyring — never touches ~/.gnupg

# All image-verification gpg runs go through our private, batch keyring.
_vm_gpg() { gpg --homedir "$HWE_GNUPGHOME" --batch --no-tty "$@"; }

_vm_have_pinned_key() { _vm_gpg --list-keys "$HWE_VM_KEY_FP" >/dev/null 2>&1; }

# Pull the pinned key from a keyserver (recv-keys BY FULL FINGERPRINT: a server
# can't substitute a different key, since the fingerprint is the key's own hash).
# Overridable so the tests can exercise the refusals without reaching the
# network — an empty list makes a refresh fail immediately instead of timing out.
: "${HWE_VM_KEYSERVERS:=hkps://keyserver.ubuntu.com hkps://keys.openpgp.org}"
_vm_refresh_key() {
    local ks
    for ks in $HWE_VM_KEYSERVERS; do
        info "fetching $HWE_VM_KEY_NAME key ${HWE_VM_KEY_FP:(-8)} from $ks"
        _vm_gpg --keyserver "$ks" --recv-keys "$HWE_VM_KEY_FP" >/dev/null 2>&1 && return 0
    done
    return 1
}

# gpg --verify returns 0 only for a good, unexpired signature; owner-trust
# warnings go to stderr and don't affect the exit code. Our keyring holds ONLY
# the pinned key, so a 0 here means "that key signed this exact file".
_vm_verify_sig() { _vm_gpg --verify "$2" "$1" >/dev/null 2>&1; }

# Get the pinned key into the private keyring, from the repo or a keyserver.
_vm_prepare_keyring() {
    mkdir -p "$HWE_GNUPGHOME"; chmod 700 "$HWE_GNUPGHOME"
    [[ -f "$HWE_VM_KEY_FILE" ]] && _vm_gpg --import "$HWE_VM_KEY_FILE" >/dev/null 2>&1 || true
    _vm_have_pinned_key || _vm_refresh_key || true
    _vm_have_pinned_key \
        || { err "could not obtain the pinned $HWE_VM_KEY_NAME key ($HWE_VM_KEY_FP)"; return 1; }
}

# Verify a detached signature, self-healing an upstream subkey rotation: retry
# once against a keyserver copy of the SAME pinned fingerprint. $3 names what is
# being signed, for the message.
_vm_verify_detached_sig() {
    local file="$1" sig="$2" what="${3:-image}"
    _vm_verify_sig "$file" "$sig" && return 0
    warn "$what did not verify with the embedded key — refreshing it (possible upstream key rotation)"
    _vm_refresh_key && _vm_verify_sig "$file" "$sig"
}

# --- Arch's shape: a detached .sig per image ------------------------------
# $sha256 is an optional cheap precheck; the signature is the actual evidence.
_vm_verify_detached() {
    local img="$1" sig="$2" sha="${3:-}"
    if [[ -f "$sha" ]]; then
        local want got
        want="$(awk 'NF{print $1; exit}' "$sha")"
        got="$(sha256sum "$img" | awk '{print $1}')"
        [[ -n "$want" && "$want" == "$got" ]] || { err "SHA256 mismatch on base image"; return 1; }
        info "SHA256 matches the published checksum"
    fi
    _vm_prepare_keyring || return 1
    _vm_verify_detached_sig "$img" "$sig" "image"
}

# --- Ubuntu's shape: one signed SHA256SUMS for the whole directory --------
# Two steps, and BOTH are load-bearing: the signature proves the checksum file is
# Canonical's, and the file's line for our image proves the bytes are the ones it
# vouched for. Verify in that order — a checksum from an unsigned file is a
# number, not evidence.
_vm_verify_sums() {
    local img="$1" sums="$2" sig="$3"
    _vm_prepare_keyring || return 1
    _vm_verify_detached_sig "$sums" "$sig" "SHA256SUMS" \
        || { err "SHA256SUMS is not signed by the pinned $HWE_VM_KEY_NAME key"; return 1; }
    info "SHA256SUMS carries a valid $HWE_VM_KEY_NAME signature"

    # A MISSING line is a refusal, not an absence of evidence. Left implicit,
    # `grep` finding nothing reads exactly like "nothing wrong" — which is how a
    # check comes to pass without having checked anything.
    local name want got
    name="$(basename "$HWE_IMAGE_URL")"
    # sha256sum's own format: "<hash> *<name>" (binary mode) or "<hash>  <name>".
    want="$(awk -v n="$name" '$2 == n || $2 == "*" n {print $1; exit}' "$sums")"
    [[ -n "$want" ]] \
        || { err "$name has no line in the signed SHA256SUMS — refusing an image it does not vouch for"; return 1; }
    got="$(sha256sum "$img" | awk '{print $1}')"
    [[ "$want" == "$got" ]] \
        || { err "SHA256 mismatch: signed $want, downloaded $got"; return 1; }
    info "image matches its SHA-256 in the signed SHA256SUMS"
}

# libosinfo tunes the domain's device defaults from an OS id. A brand-new release
# routinely postdates the host's osinfo-db — 26.04 is absent from a db that stops
# at 25.10 — and virt-install ERRORS on an unknown name rather than ignoring it,
# which would make `vm up` fail on a detail that only picks default hardware.
# Fall back to the newest id of the same family the host actually knows.
_vm_osinfo_name() {
    local want="$HWE_VM_OSINFO" known best family
    command -v osinfo-query >/dev/null 2>&1 || { printf '%s\n' "$want"; return 0; }
    known="$(osinfo-query --fields=short-id os 2>/dev/null | tr -d '[:blank:]')"
    if grep -qx -- "$want" <<<"$known"; then printf '%s\n' "$want"; return 0; fi
    family="${want%%[0-9]*}"                       # ubuntu26.04 -> ubuntu
    best="$(grep -E "^${family}[0-9]" <<<"$known" | sort -V | tail -1)"
    if [[ -n "$best" ]]; then
        warn "libosinfo does not know '$want' — using '$best' (affects device defaults only)"
        printf '%s\n' "$best"
    else
        printf '%s\n' "$want"
    fi
}

# --- Base image -----------------------------------------------------------
_vm_download_base() {
    mkdir -p "$HWE_CACHE"
    if [[ -f "$HWE_BASE_IMG" ]]; then
        info "base image present: ${HWE_BASE_IMG##*/}"
        return 0
    fi
    log "Downloading the $HWE_VM_DISTRO cloud image..."
    info "$HWE_IMAGE_URL"
    local part="$HWE_BASE_IMG.part"
    curl -fL --progress-bar "$HWE_IMAGE_URL" -o "$part"

    # Fetch the evidence and check it BEFORE promoting .part -> final, so a
    # failed verification never leaves a usable image in the cache.
    local -a scratch=("$part")
    local verified=1
    case "$HWE_VM_SIGSTYLE" in
        detached)
            scratch+=("$part.sig" "$part.sha256")
            curl -fsSL "$HWE_IMAGE_URL.sig" -o "$part.sig" \
                || { rm -f "${scratch[@]}"; die "could not fetch the image signature (.sig) — refusing an unverifiable image"; }
            curl -fsSL "$HWE_IMAGE_URL.SHA256" -o "$part.sha256" 2>/dev/null || rm -f "$part.sha256"
            log "Verifying base image signature ($HWE_VM_KEY_NAME)"
            _vm_verify_detached "$part" "$part.sig" "$part.sha256" && verified=0
            ;;
        sumsfile)
            scratch+=("$part.sums" "$part.sums.gpg")
            # SHA256SUMS lives beside the image, not at the image's own URL.
            local dir="${HWE_IMAGE_URL%/*}"
            # if/else, not `A && B || C`: with the latter, C also runs when B
            # fails, so a failed .gpg fetch would report the wrong cause.
            if ! curl -fsSL "$dir/SHA256SUMS" -o "$part.sums" \
                || ! curl -fsSL "$dir/SHA256SUMS.gpg" -o "$part.sums.gpg"; then
                rm -f "${scratch[@]}"
                die "could not fetch SHA256SUMS(.gpg) — refusing an unverifiable image"
            fi
            log "Verifying base image against the signed SHA256SUMS ($HWE_VM_KEY_NAME)"
            _vm_verify_sums "$part" "$part.sums" "$part.sums.gpg" && verified=0
            ;;
        *)
            rm -f "${scratch[@]}"
            die "no authenticity check defined for HWE_VM_DISTRO='$HWE_VM_DISTRO' — refusing to build a VM from an unverified image"
            ;;
    esac
    if [[ $verified -ne 0 ]]; then
        rm -f "${scratch[@]}"
        die "base image failed authenticity check — refusing to build a VM from it (tampered mirror / MITM, or upstream rotated the signing key: regenerate ${HWE_VM_KEY_FILE##*/})"
    fi
    rm -f "${scratch[@]:1}"
    mv "$part" "$HWE_BASE_IMG"
    ok "verified ($HWE_VM_KEY_NAME) + downloaded $(du -h "$HWE_BASE_IMG" | cut -f1) base image"
}

# --- Git bundle of the chosen local branch --------------------------------
# The branch name is interpolated into the guest's cloud-init runcmd, single-
# quoted (`git clone -b '@@BRANCH@@'`). git itself permits ' ; | $ ` in a ref
# name (it only bars space, control chars and ~^:?*[\), any of which would break
# out of those quotes into guest shell. It is your own local branch — but a name
# is data, so pin it to a conservative charset before it can become code. A
# leading dash is barred too, so a ref can't pose as a `git`/`clone` option.
_vm_branch_ok() {
    [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]]
}

_vm_build_bundle() {
    local branch="$1" dest="$2" uncommitted="${3:-0}" workdir="${4:-}"
    git -C "$HWE_ROOT" rev-parse --git-dir >/dev/null 2>&1 \
        || die "$HWE_ROOT is not a git repo. Run: git init && git add -A && git commit -m init"
    git -C "$HWE_ROOT" rev-parse HEAD >/dev/null 2>&1 \
        || die "no commits yet. Commit your work first: git add -A && git commit -m init"
    git -C "$HWE_ROOT" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null \
        || die "local branch '$branch' not found (git branch to list)"

    if [[ "$uncommitted" == 1 ]]; then
        _vm_bundle_uncommitted "$branch" "$dest" "$workdir"
        return
    fi

    info "bundling branch '$branch' from local repo"
    git -C "$HWE_ROOT" bundle create "$dest" "$branch" >/dev/null
    if ! _vm_tree_clean; then
        warn "working tree has uncommitted changes — only committed content of '$branch' is deployed"
        info "to test them anyway: ${C_BOLD}hwe vm up $branch --uncommitted${C_RESET}"
    fi
}

# True when nothing is modified, staged, deleted or newly added (ignored files
# don't count — they are build output the guest regenerates).
_vm_tree_clean() { [[ -z "$(git -C "$HWE_ROOT" status --porcelain 2>/dev/null)" ]]; }

# --- Deploy the working tree as it is right now (--uncommitted) ------------
# Testing a change normally means committing it first. This ships the tree
# instead: the branch's history plus everything uncommitted on top of it —
# modified, staged, deleted and untracked-but-not-ignored files — as one
# throwaway snapshot commit, so the VM boots exactly what you are editing.
#
# Nothing in the real repo moves. `git add -A` runs against an ALTERNATE index
# ($GIT_INDEX_FILE), so the true index and working tree are untouched; the
# snapshot commit is written into a temporary `--shared` clone (objects are read
# through alternates, nothing is copied) and bundled from there, so no ref, no
# branch and no reflog entry of yours ever mentions it. Ignored files stay out —
# `config/*/colors.*` and friends are generated in the guest by `hwe install`.
_vm_bundle_uncommitted() {
    local branch="$1" dest="$2" workdir="$3"
    [[ -d "$workdir" ]] || die "internal: no scratch dir for the uncommitted snapshot"

    # The working tree belongs to whatever HEAD points at, so snapshotting it
    # onto a *different* branch would silently graft unrelated changes.
    local head; head="$(git -C "$HWE_ROOT" symbolic-ref --quiet --short HEAD || true)"
    [[ "$head" == "$branch" ]] || die "--uncommitted deploys the working tree, which belongs to the checked-out branch (${head:-detached HEAD}), not to '$branch'. Check '$branch' out first, or drop --uncommitted."

    # Nothing to snapshot: deploy the branch itself rather than an empty commit.
    if _vm_tree_clean; then
        info "working tree is clean — deploying branch '$branch' as committed"
        git -C "$HWE_ROOT" bundle create "$dest" "$branch" >/dev/null
        return
    fi
    warn "deploying the UNCOMMITTED working tree of '$branch':"
    git -C "$HWE_ROOT" status --short | sed 's/^/    /' >&2

    local index="$workdir/snapshot.index" clone="$workdir/snapshot.git"
    local tree commit

    # A commit needs an identity; borrow the repo's, and fall back to a neutral
    # one so an unconfigured git can't fail the build over a throwaway commit.
    local ident=()
    git -C "$HWE_ROOT" config --get user.email >/dev/null 2>&1 \
        || ident=(-c user.name="hwe vm" -c user.email="hwe-vm@localhost")

    GIT_INDEX_FILE="$index" git -C "$HWE_ROOT" read-tree HEAD
    GIT_INDEX_FILE="$index" git -C "$HWE_ROOT" add -A
    tree="$(GIT_INDEX_FILE="$index" git -C "$HWE_ROOT" write-tree)"
    commit="$(git -C "$HWE_ROOT" "${ident[@]}" commit-tree "$tree" -p HEAD \
        -m "WIP: working tree of $branch (hwe vm --uncommitted)")"

    info "bundling the working-tree snapshot of '$branch'"
    git clone --quiet --shared --no-checkout "$HWE_ROOT" "$clone"
    git -C "$clone" update-ref "refs/heads/$branch" "$commit"
    git -C "$clone" bundle create "$dest" "$branch" >/dev/null
}

# --- cloud-init seed ------------------------------------------------------
_vm_collect_ssh_keys() {
    # Emit YAML list items (indented 6 spaces) for every host public key found.
    local found=0 k
    for k in "$HOME"/.ssh/id_*.pub; do
        [[ -f "$k" ]] || continue
        printf '      - %s\n' "$(cat "$k")"
        found=1
    done
    [[ $found -eq 0 ]] && warn "no ~/.ssh/id_*.pub found — SSH will rely on password '$HWE_VM_PASSWORD'" >&2
    return 0
}

_vm_render_seed() {
    local branch="$1" workdir="$2" uncommitted="${3:-0}"
    local ci="$workdir/cloud-init"
    mkdir -p "$ci"

    local ssh_keys; ssh_keys="$(_vm_collect_ssh_keys)"
    # Password SSH only when we shipped NO key — else disable it so the password
    # isn't a network login path (console still works).
    local pwauth=true
    [[ -n "${ssh_keys//[[:space:]]/}" ]] && pwauth=false
    # instance-id changes per build so cloud-init always re-runs on rebuild.
    local instance_id; instance_id="hwe-$(date +%s 2>/dev/null || echo build)"

    _vm_subst "$HWE_ROOT/provision/cloud-init/user-data.tmpl" "$ci/user-data" \
        HOSTNAME="$HWE_VM_NAME" USER="$HWE_VM_USER" PASSWORD="$HWE_VM_PASSWORD" \
        BRANCH="$branch" SSH_KEYS="$ssh_keys" SSH_PWAUTH="$pwauth" \
        ADMIN_GROUP="$HWE_VM_ADMIN_GROUP" SHELL="$HWE_VM_SHELL" \
        HYPR_SOURCE="$HWE_HYPR_SOURCE"
    _vm_subst "$HWE_ROOT/provision/cloud-init/meta-data.tmpl" "$ci/meta-data" \
        HOSTNAME="$HWE_VM_NAME" INSTANCE_ID="$instance_id"

    _vm_build_bundle "$branch" "$ci/hwe.bundle" "$uncommitted" "$workdir"

    local seed="$workdir/seed.iso"
    info "building NoCloud seed ISO"
    xorriso -as mkisofs -quiet -output "$seed" -volid CIDATA -joliet -rock \
        "$ci/user-data" "$ci/meta-data" "$ci/hwe.bundle"
    printf '%s\n' "$seed"
}

# Token-substitute @@KEY@@ -> value (multiline SSH_KEYS included). Value goes via
# the environment, NOT awk -v: -v processes C escapes (\n, \\) and would mangle a
# password/key; ENVIRON[] + index/substr keep both match and replacement literal.
_vm_subst() {
    local src="$1" out="$2"; shift 2
    cp "$src" "$out"
    local pair key
    for pair in "$@"; do
        key="${pair%%=*}"
        _hwe_subst_v="${pair#*=}" awk -v k="@@${key}@@" '
            { while ((i=index($0,k))>0) $0=substr($0,1,i-1) ENVIRON["_hwe_subst_v"] substr($0,i+length(k)) }
            { print }
        ' "$out" > "$out.tmp" && mv "$out.tmp" "$out"
    done
}

# --- Privileged pool helpers (system URI needs root to write the pool dir) --
_pool_prepare() { run sudo install -d -m 0711 "$HWE_POOL_DIR"; }
# Copy with an EXPLICIT mode rather than cp's inherited one: the pool dir is
# world-traversable (0711) at a predictable path, and the seed ISO carries the
# guest's plain_text_passwd, so it must not land world-readable. libvirt chowns
# the disk to qemu at start, so its group/owner here is immaterial.
_pool_put()     { run sudo install -m "${3:-0644}" "$1" "$2"; }

# --- Create & boot --------------------------------------------------------
vm_up() {
    local branch="" uncommitted=0 arg
    for arg in "$@"; do
        case "$arg" in
            --uncommitted) uncommitted=1 ;;
            -*) err "unknown vm up flag: $arg"; vm_usage; return 1 ;;
            *)  [[ -n "$branch" ]] && { err "vm up takes at most one branch (got '$branch' and '$arg')"; return 1; }
                branch="$arg" ;;
        esac
    done
    [[ -z "$branch" ]] && branch="$(git -C "$HWE_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo master)"
    _vm_branch_ok "$branch" \
        || die "refusing branch name '$branch' — letters, digits and . _ / - only (it is interpolated into the guest's cloud-init)"

    # Same reasoning as the branch name: this reaches the guest inside a single-
    # quoted shell word, so it is data that could become code. It also happens to
    # be a closed set, which makes the check free.
    case "$HWE_HYPR_SOURCE" in
        repo|ppa) ;;
        *) die "refusing HWE_HYPR_SOURCE='$HWE_HYPR_SOURCE' — expected 'repo' or 'ppa'" ;;
    esac

    if _virsh dominfo "$HWE_VM_NAME" >/dev/null 2>&1; then
        die "VM '$HWE_VM_NAME' already exists. Use 'hwe vm rebuild $branch' or 'hwe vm destroy' first."
    fi

    _vm_ensure_ready || return 1
    _vm_download_base

    local work; work="$(mktemp -d "${TMPDIR:-/tmp}/hwe-vm.XXXXXX")"
    # Unbound-safe: this RETURN trap can fire again as outer functions return,
    # by which point `work` is out of scope (set -u would otherwise abort).
    trap 'rm -rf "${work:-}"' RETURN
    local seed; seed="$(_vm_render_seed "$branch" "$work" "$uncommitted")"

    local what="branch: $branch"
    [[ "$uncommitted" == 1 ]] && what="working tree of $branch"
    log "Provisioning VM '$HWE_VM_NAME' ($what)"
    _pool_prepare
    local disk="$HWE_POOL_DIR/$HWE_VM_NAME.qcow2"
    local seed_dst="$HWE_POOL_DIR/$HWE_VM_NAME-seed.iso"

    info "creating root disk ($HWE_VM_DISK_SIZE) from base image"
    local tmpdisk="$work/disk.qcow2"
    qemu-img convert -O qcow2 "$HWE_BASE_IMG" "$tmpdisk"
    qemu-img resize "$tmpdisk" "$HWE_VM_DISK_SIZE" >/dev/null
    _pool_put "$tmpdisk" "$disk"
    _pool_put "$seed" "$seed_dst" 0600

    local cpu_arg=host-passthrough
    [[ -r /dev/kvm ]] || cpu_arg=qemu64

    info "defining libvirt domain (virt-manager will see it as '$HWE_VM_NAME')"
    virt-install \
        --connect "$HWE_LIBVIRT_URI" \
        --name "$HWE_VM_NAME" \
        --memory "$HWE_VM_MEMORY" \
        --vcpus "$HWE_VM_VCPUS" \
        --cpu "$cpu_arg" \
        --import \
        --disk "path=$disk,format=qcow2,bus=virtio" \
        --disk "path=$seed_dst,device=cdrom" \
        --osinfo "detect=on,require=off,name=$(_vm_osinfo_name)" \
        --network "network=$HWE_VM_NETWORK,model=virtio" \
        --graphics spice,gl.enable=yes,listen=none \
        --video model.type=virtio,model.acceleration.accel3d=yes \
        --channel unix,target.type=virtio,target.name=org.qemu.guest_agent.0 \
        --rng /dev/urandom \
        --noautoconsole

    ok "VM '$HWE_VM_NAME' defined and booting"
    echo
    log "cloud-init is now installing Hyprland + the dev toolchain (a few minutes)."
    log "when it finishes the VM reboots once, landing straight in the Hyprland session."
    info "watch progress:   ${C_BOLD}hwe vm console${C_RESET}   (or open it in virt-manager)"
    info "get a shell:      ${C_BOLD}hwe vm ssh${C_RESET}       (key-based; no password needed)"
    info "check state/IP:   ${C_BOLD}hwe vm status${C_RESET}"
    info "console fallback: ${C_BOLD}$HWE_VM_USER / $HWE_VM_PASSWORD${C_RESET}   (only if autologin fails)"
}

# --- IP discovery (guest agent, then DHCP leases) -------------------------
_vm_ip() {
    local ip src
    # Prefer the DHCP lease (never lists loopback); fall back to the guest agent.
    # In both cases skip loopback/link-local so we get the real NAT address.
    for src in lease agent; do
        ip="$(_virsh domifaddr "$HWE_VM_NAME" --source "$src" 2>/dev/null \
            | awk '/ipv4/ {split($NF,a,"/"); if (a[1] !~ /^(127\.|169\.254\.)/) {print a[1]; exit}}')"
        [[ -n "$ip" ]] && { printf '%s\n' "$ip"; return 0; }
    done
    return 1
}

# `hwe vm up` NAMES a domain; every other action has to find one. With a VM per
# distro that name stopped being a constant, and forgetting HWE_VM_DISTRO used to
# surface as a bare libvirt error about a domain you never asked for.
#
# So: if the target is missing and you did not name one, and exactly ONE HWE VM
# exists, act on that and say so. Two or more is a real ambiguity — list them and
# stop, because picking for you would be a guess, and this is the code path that
# reaches `destroy`.
_vm_distro_of_name() {
    case "$1" in
        hwe-dev-ubuntu) printf 'HWE_VM_DISTRO=ubuntu ' ;;
        *)              printf '' ;;
    esac
}

_vm_resolve_target() {
    _virsh dominfo "$HWE_VM_NAME" >/dev/null 2>&1 && return 0
    if [[ -n "$HWE_VM_TARGET_NAMED" ]]; then
        err "VM '$HWE_VM_NAME' does not exist"
        info "create it: ${C_BOLD}$(_vm_distro_of_name "$HWE_VM_NAME")hwe vm up${C_RESET}"
        return 1
    fi
    local found=() cand
    for cand in $HWE_VM_NAMES_ALL; do
        [[ "$cand" == "$HWE_VM_NAME" ]] && continue
        _virsh dominfo "$cand" >/dev/null 2>&1 && found+=("$cand")
    done
    case ${#found[@]} in
        0)  err "no HWE VM exists yet"
            info "create one: ${C_BOLD}hwe vm up${C_RESET}  or  ${C_BOLD}HWE_VM_DISTRO=ubuntu hwe vm up${C_RESET}"
            return 1 ;;
        1)  HWE_VM_NAME="${found[0]}"
            info "no '$HWE_VM_DISTRO' VM — using the one that exists: ${C_BOLD}$HWE_VM_NAME${C_RESET}"
            return 0 ;;
        *)  err "several HWE VMs exist — say which one you mean:"
            for cand in "${found[@]}"; do
                info "  ${C_BOLD}$(_vm_distro_of_name "$cand")hwe vm $*${C_RESET}   → $cand"
            done
            return 1 ;;
    esac
}

vm_ssh() {
    _vm_resolve_target ssh || return 1
    local ip; ip="$(_vm_ip)" || die "could not determine VM IP yet — is it booted and is the guest agent up? (hwe vm status)"
    info "ssh $HWE_VM_USER@$ip"
    exec ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
        "$HWE_VM_USER@$ip" "$@"
}

vm_status() {
    _vm_resolve_target status || return 1
    _virsh dominfo "$HWE_VM_NAME" | sed 's/^/    /' >&2
    local ip; if ip="$(_vm_ip)"; then ok "IP: $ip"; else warn "no IP yet (booting / agent not ready)"; fi
}

# Only HWE's own domains, not every domain on the host — the usage line promises
# "HWE VMs". Names to stdout (scriptable), the empty-case hint to stderr.
vm_list() {
    local n any=0
    for n in $HWE_VM_NAMES_ALL; do
        _virsh dominfo "$n" >/dev/null 2>&1 || continue
        printf '%s\t%s\n' "$n" "$(_virsh domstate "$n" 2>/dev/null || echo unknown)"
        any=1
    done
    [[ $any -eq 1 ]] || info "no HWE VMs exist yet — create one with: ${C_BOLD}hwe vm up${C_RESET}"
}

vm_destroy() {
    # Resolution is safe here only because the confirmation below names the VM it
    # resolved to — the user always gets to see which one is about to go.
    _vm_resolve_target destroy || return 1
    confirm "Destroy VM '$HWE_VM_NAME' and delete its disks?" || { info "aborted"; return 0; }
    vm_destroy_quiet
    ok "VM '$HWE_VM_NAME' removed"
}

# Destroy + recreate the VM named by HWE_VM_DISTRO (default 'hwe-dev'). Unlike the
# other targeted verbs it does NOT resolve to whichever VM happens to exist: the
# image vm_up builds is chosen by HWE_VM_DISTRO, so operating on a differently-named
# VM would rebuild it with the wrong distro's image. Instead it confirms by NAME —
# which both gates the disk deletion (destroy asks; rebuild used not to) and makes
# a forgotten HWE_VM_DISTRO visible ("Rebuild VM 'hwe-dev'?" when you meant ubuntu).
vm_rebuild() {
    if _virsh dominfo "$HWE_VM_NAME" >/dev/null 2>&1; then
        confirm "Rebuild VM '$HWE_VM_NAME' — destroy its disks and recreate it?" \
            || { info "rebuild cancelled — nothing changed"; return 0; }
        vm_destroy_quiet
    else
        info "no VM '$HWE_VM_NAME' to rebuild — building it fresh"
        info "(set ${C_BOLD}HWE_VM_DISTRO${C_RESET} to target a differently-named VM)"
    fi
    vm_up "$@"
}

vm_destroy_quiet() {
    _virsh destroy "$HWE_VM_NAME" >/dev/null 2>&1 || true
    _virsh undefine "$HWE_VM_NAME" --nvram --remove-all-storage >/dev/null 2>&1 \
        || _virsh undefine "$HWE_VM_NAME" >/dev/null 2>&1 || true
    # Best-effort cleanup of anything libvirt did not remove.
    if [[ -d "$HWE_POOL_DIR" ]]; then
        run sudo rm -f "$HWE_POOL_DIR/$HWE_VM_NAME.qcow2" "$HWE_POOL_DIR/$HWE_VM_NAME-seed.iso" 2>/dev/null || true
    fi
}
