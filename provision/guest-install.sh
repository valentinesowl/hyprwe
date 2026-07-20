#!/usr/bin/env bash
# provision/guest-install.sh — install packages + deploy configs onto THIS
# machine. Used by `hwe install` (sourced) and by cloud-init at first boot.
# Idempotent; configs are symlinked into ~/.config so repo edits are live.

# When run standalone (not via bin/hwe) bootstrap the environment ourselves.
if [[ -z "${HWE_ROOT:-}" ]]; then
    _self="$(readlink -f "${BASH_SOURCE[0]}")"
    HWE_ROOT="$(cd "$(dirname "$_self")/.." && pwd)"
    export HWE_ROOT
    # `source=` paths are resolved from the directory shellcheck RUNS in (the repo
    # root — see `just lint`), not from this file. Hence lib/…, not ../lib/….
    # shellcheck source=lib/common.sh
    source "$HWE_ROOT/lib/common.sh"
fi

# --- package helpers ------------------------------------------------------
_pkgs_read() {
    # Read a .lst file: strip comments/blank lines, emit one package per line.
    local f="$1"
    [[ -f "$f" ]] || return 0
    sed -e 's/#.*//' -e '/^[[:space:]]*$/d' -e 's/[[:space:]]//g' "$f"
}

# HWE's own lists (pkg/, tracked) and yours (~/.config/hwe/, untracked). Same
# format, two sources: the repo answers "what does this environment need", your
# list answers "what does THIS machine need" — see the personal layer in
# lib/common.sh. A missing file is simply an empty list.
_pkgs_from() { _pkgs_read "$HWE_ROOT/pkg/$1"; }
_pkgs_user() { _pkgs_read "$HWE_USER_CONFIG/$1"; }

# Everything wanted from the AUR: HWE's list plus yours. Used both to decide
# whether bootstrapping paru is warranted at all and to install.
_aur_wanted() { _pkgs_from aur.lst; _pkgs_user packages-aur.lst; }

# Install one of HWE's lists. The names in pkg/*.lst are Arch's — the canonical
# vocabulary — so they go through _pm_translate before they reach the local
# package manager. On Arch that is a pass-through; elsewhere it renames what
# needs renaming and drops what does not exist there (lib/distro.sh).
_pacman_install() {
    local pkgs=()
    mapfile -t pkgs < <(_pkgs_from "$1" | _pm_translate)
    [[ ${#pkgs[@]} -eq 0 ]] && return 0
    log "Installing ${#pkgs[@]} packages from pkg/$1"
    _pm_install "${pkgs[@]}"
}

# Your own packages (~/.config/hwe/packages.lst), installed exactly like HWE's —
# except that these are NOT translated. Your list names what your machine should
# have, in the vocabulary of the machine you are on; second-guessing it would be
# wrong the moment you name something that only exists here.
_install_user_packages() {
    local pkgs=()
    mapfile -t pkgs < <(_pkgs_user packages.lst)
    [[ ${#pkgs[@]} -eq 0 ]] && return 0
    log "Installing ${#pkgs[@]} packages from ~/.config/hwe/packages.lst"
    _pm_install "${pkgs[@]}"
}

# Slow-mirror tolerant: --disable-download-timeout + retry against a refreshed
# DB. Flaky mirrors were the #1 provisioning failure (a stalled .sig aborts all).
_pacman_retry() {
    local tries=0 max=3
    while true; do
        if run sudo pacman "$@" --noconfirm --disable-download-timeout; then
            return 0
        fi
        tries=$((tries + 1))
        [[ $tries -ge $max ]] && { err "pacman failed after $max attempts"; return 1; }
        warn "pacman transaction failed — refreshing DBs and retrying ($tries/$max)"
        sudo pacman -Syy --noconfirm --disable-download-timeout >/dev/null 2>&1 || true
        sleep 3
    done
}

# The AUR is Arch's, and so is paru. Elsewhere an aur.lst entry is simply not
# installable — say so once rather than failing per package.
_aur_supported() {
    [[ "$(_distro_family)" == pacman ]] && return 0
    local aur; mapfile -t aur < <(_aur_wanted)
    [[ ${#aur[@]} -gt 0 ]] && info "AUR packages are Arch-only — skipping ${#aur[@]} of them on ${HWE_DISTRO}"
    return 1
}

_bootstrap_paru() {
    _aur_supported || return 0
    command -v paru >/dev/null 2>&1 && return 0
    local aur; mapfile -t aur < <(_aur_wanted)
    [[ ${#aur[@]} -eq 0 ]] && return 0   # no AUR packages requested → skip
    log "Bootstrapping paru (AUR helper)"
    _pacman_retry -S --needed base-devel git
    local tmp; tmp="$(mktemp -d)"
    run git clone --depth=1 https://aur.archlinux.org/paru-bin.git "$tmp/paru-bin"
    ( cd "$tmp/paru-bin" && makepkg -si --noconfirm )
    rm -rf "$tmp"
}

_aur_install() {
    _aur_supported || return 0
    local aur; mapfile -t aur < <(_aur_wanted)
    [[ ${#aur[@]} -eq 0 ]] && return 0
    command -v paru >/dev/null 2>&1 || { warn "paru unavailable, skipping AUR packages"; return 0; }
    log "Installing ${#aur[@]} AUR packages"
    run paru -S --needed --noconfirm "${aur[@]}"
}

# --- config deployment ----------------------------------------------------
# A few config/<name>/ dirs hold theme-apply BUILD OUTPUT that is consumed
# elsewhere, NOT read from ~/.config — so they must not be symlinked there
# (a ~/.config/<name> link would be inert, and misleadingly show as "config"):
#   color-schemes -> ~/.local/share/color-schemes/HWE.colors  (KDE reads XDG_DATA)
#   kvantum       -> assembled into ~/.config/Kvantum/HWE by `hwe theme` (theme.sh)
#   sddm          -> installed into /usr/share/sddm/themes/hwe by `hwe theme sddm`
# Shared with lib/doctor.sh so the drift check can't diverge from the deploy.
_config_is_staging() {
    case "$1" in
        color-schemes|kvantum|sddm) return 0 ;;
        *) return 1 ;;
    esac
}

# --- fonts we fetch ourselves ---------------------------------------------
# Almost every font HWE uses comes from the distribution, signed. The Nerd Fonts
# icon glyphs are the exception on distributions that do not package them, and
# that download is the only artifact here without a distribution's signature
# behind it — so it is pinned in pkg/fonts.lock and verified before use.
#
# The refusal is the point: an entry with a blank hash means no maintainer has
# vouched for those bytes, and HWE would rather come up without icons than
# install something nobody checked. See scripts/fontlock.py for what the pin is
# and is not worth.
_fonts_lock_rows() {
    # Overridable so the tests can exercise the refusals against a fixture
    # instead of the shipped lock — and without reaching the network.
    local f="${HWE_FONTS_LOCK:-$HWE_ROOT/pkg/fonts.lock}"
    [[ -f "$f" ]] || return 0
    sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$f"
}

# True if a font member is already available — provided by a package (fc-list
# knows it) or fetched by us into the hwe font dir. Shared by the installer (skip
# the download) and doctor (no drift), so the two cannot disagree.
#
# `grep -q` would exit on the first match and SIGPIPE fc-list; under `set -o
# pipefail` that 141 is reported as the pipeline's status, so a PRESENT font read
# as absent — the installer then re-downloaded a packaged font every run. grep
# reads all of fc-list instead of short-circuiting, which keeps fc-list's exit 0.
_font_installed() {
    local member="$1"
    local dest="${XDG_DATA_HOME:-$HOME/.local/share}/fonts/hwe"
    [[ -f "$dest/$member" ]] && return 0
    fc-list 2>/dev/null | grep -F "$member" >/dev/null 2>&1
}

_install_fetched_fonts() {
    local dest="${XDG_DATA_HOME:-$HOME/.local/share}/fonts/hwe"
    local id url a_sha member f_sha installed=0
    while IFS=$'\t' read -r id url a_sha member f_sha; do
        [[ -n "${id:-}" && -n "${member:-}" ]] || continue

        # Already provided by a package on this distro (or fetched before)? Not ours to fetch.
        if _font_installed "$member"; then
            info "$member already installed — not fetching"
            continue
        fi
        # `-` is the unpinned marker. It has to be a real character: tab is IFS
        # whitespace, so `read` collapses a run of them and an empty column would
        # disappear — the row would be skipped in silence rather than refused.
        if [[ "$f_sha" == "-" || "$a_sha" == "-" || -z "$f_sha" || -z "$a_sha" ]]; then
            warn "$id is not pinned in pkg/fonts.lock — skipping the download"
            info "nobody has vouched for those bytes yet; run 'just fonts-lock' to review and pin"
            continue
        fi

        local tmp; tmp="$(mktemp -d)"
        log "Fetching $member (pinned)"
        if ! run curl -fL --progress-bar "$url" -o "$tmp/archive"; then
            warn "could not download $id — icons will fall back to whatever is installed"
            rm -rf "$tmp"; continue
        fi
        local got; got="$(sha256sum "$tmp/archive" | awk '{print $1}')"
        if [[ "$got" != "$a_sha" ]]; then
            err "$id: archive hash mismatch — refusing to use it"
            info "expected $a_sha, got $got (tampered mirror, or upstream replaced the asset)"
            rm -rf "$tmp"; continue
        fi
        # tar, not unzip: tar is everywhere, unzip is not on a bare Ubuntu.
        if ! tar -xJf "$tmp/archive" -C "$tmp" "./$member" 2>/dev/null \
           && ! tar -xJf "$tmp/archive" -C "$tmp" "$member" 2>/dev/null; then
            err "$id: '$member' is not in the archive — upstream changed its layout"
            rm -rf "$tmp"; continue
        fi
        got="$(sha256sum "$tmp/$member" | awk '{print $1}')"
        if [[ "$got" != "$f_sha" ]]; then
            err "$id: font hash mismatch inside a matching archive — refusing to install"
            rm -rf "$tmp"; continue
        fi
        mkdir -p "$dest"
        install -m 644 "$tmp/$member" "$dest/$member"
        rm -rf "$tmp"
        info "installed $member -> $dest"
        installed=1
    done < <(_fonts_lock_rows)
    [[ $installed -eq 1 ]] && command -v fc-cache >/dev/null 2>&1 && run fc-cache -f "$dest" >/dev/null 2>&1
    return 0
}

# --- the personal layer ---------------------------------------------------
# Create ~/.config/hwe/ from the skeletons in provision/userlayer/ — see the
# rationale on HWE_USER_CONFIG in lib/common.sh. Copy-once, never overwrite: an
# existing file is yours and is left exactly as it is, so this is safe to run on
# every install and every update.
#
# hypr.conf MUST exist, because hyprland.conf sources it unconditionally and a
# missing source file is a Hyprland config error. The rest are created only so
# the layer is discoverable — an empty machine should show you where your
# settings go, rather than documenting a path you have to create by hand.
# The skeleton directory IS the definition of the layer: lib/doctor.sh reads the
# same list, so the check cannot drift from what the install lays down.
HWE_USER_SKEL="$HWE_ROOT/provision/userlayer"

_user_layer_files() {
    local f
    for f in "$HWE_USER_SKEL"/*; do
        [[ -f "$f" ]] && printf '%s\n' "${f##*/}"
    done
    return 0
}

_deploy_user_layer() {
    local name dst created=0
    mkdir -p "$HWE_USER_CONFIG"
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        dst="$HWE_USER_CONFIG/$name"
        [[ -e "$dst" ]] && continue      # yours — never overwritten
        cp "$HWE_USER_SKEL/$name" "$dst"
        info "created ~/.config/hwe/$name"
        created=1
    done < <(_user_layer_files)
    [[ $created -eq 1 ]] && log "Personal layer ready in $HWE_USER_CONFIG — yours to edit, HWE won't touch it again"
    return 0
}

_deploy_configs() {
    log "Deploying configs -> ~/.config (symlinked to the repo)"
    local src dst name backup
    mkdir -p "$HOME/.config"
    for src in "$HWE_ROOT"/config/*/; do
        [[ -d "$src" ]] || continue
        name="$(basename "$src")"
        _config_is_staging "$name" && continue   # build output, consumed elsewhere
        dst="$HOME/.config/$name"
        if [[ -L "$dst" ]]; then
            rm -f "$dst"
        elif [[ -e "$dst" ]]; then
            backup="$dst.hwe-bak.$$"
            warn "backing up existing ~/.config/$name -> $(basename "$backup")"
            mv "$dst" "$backup"
        fi
        ln -sfn "${src%/}" "$dst"
        info "linked ~/.config/$name"
    done
    # Loose top-level files (starship.toml, kdeglobals) live directly in
    # ~/.config. Back up a pre-existing real kdeglobals (KDE writes its own).
    for src in "$HWE_ROOT"/config/*.toml "$HWE_ROOT"/config/*.conf "$HWE_ROOT"/config/kdeglobals; do
        [[ -f "$src" ]] || continue
        dst="$HOME/.config/$(basename "$src")"
        [[ -e "$dst" && ! -L "$dst" ]] && mv "$dst" "$dst.hwe-bak.$$"
        ln -sfn "$src" "$dst"
    done
    # KDE colour scheme lives under XDG_DATA so kdeglobals' ColorScheme resolves.
    if [[ -f "$HWE_ROOT/config/color-schemes/HWE.colors" ]]; then
        mkdir -p "${XDG_DATA_HOME:-$HOME/.local/share}/color-schemes"
        ln -sfn "$HWE_ROOT/config/color-schemes/HWE.colors" \
            "${XDG_DATA_HOME:-$HOME/.local/share}/color-schemes/HWE.colors"
    fi
}

# --- session / services ---------------------------------------------------

# Guest-only integration packages (qemu-guest-agent, spice-vdagent). Installed
# only inside a VM — never pollutes a bare-metal workstation.
_install_vm_packages() {
    systemd-detect-virt --quiet 2>/dev/null || { info "not a VM: skipping guest packages"; return 0; }
    log "VM detected — installing guest integration packages"
    _pacman_install vm.lst
}

# --- Packaged session units that duplicate our autostart ------------------
# Debian/Ubuntu ship systemd USER units for session programs and enable them the
# moment the package installs; Arch ships none of these. HWE starts the same
# programs itself from config/hypr/autostart.conf, so on apt you end up running
# two of each: two bars (you can see it on screen), two idle daemons racing to
# lock, two wallpaper daemons fighting over the same output.
#
# Neither owner is wrong — there are simply two of them. autostart.conf is the
# one this project documents, themes and reloads, so the packaged units stand
# down. hyprpolkitagent is deliberately NOT in this list: autostart.conf starts
# that one BY unit, so the packaged unit is the intended owner there.
#
# `--global` edits /etc/systemd/user/*.wants, which is where these symlinks
# actually live, and needs no running user session — this runs from cloud-init,
# where there is none.
HWE_DUPLICATE_USER_UNITS="waybar.service hypridle.service mako.service hyprpaper.service"

_disable_duplicate_user_units() {
    [[ "$(_distro_family)" == apt ]] || return 0
    local u stood_down=()
    for u in $HWE_DUPLICATE_USER_UNITS; do
        # Any enablement symlink, not just graphical-session.target's — the
        # target a package picks is its business, and may change.
        find /etc/systemd/user -path '*.wants/*' -name "$u" -print -quit 2>/dev/null \
            | grep -q . || continue
        run sudo systemctl --global disable "$u" >/dev/null 2>&1 && stood_down+=("$u")
        # If a session happens to be up (a plain `hwe install`, not provisioning)
        # stop the copy already running instead of leaving it for a reboot.
        systemctl --user stop "$u" >/dev/null 2>&1 || true
    done
    [[ ${#stood_down[@]} -eq 0 ]] && return 0
    ok "stood down ${#stood_down[@]} packaged user units HWE starts itself"
    info "${stood_down[*]}"
}

# --- GPU: NVIDIA on bare metal -------------------------------------------
# Intel/AMD need nothing here — mesa arrives transitively with hyprland and the
# open kernel drivers are in-tree. NVIDIA is the exception: proprietary/open
# modules, DRM modeset, an initramfs rebuild and an update hook, none of which
# ship by default. This whole path is gated on actually seeing an NVIDIA GPU AND
# on bare metal (a VM uses virtio-gpu) — an Intel/AMD machine never touches it.
#
# CAVEAT: this rewrites the boot chain (mkinitcpio MODULES + initramfs). It is
# NOT undone by `hwe uninstall`, and — unlike the rest of HWE — it is UNVERIFIED
# on real NVIDIA hardware. HWE_NO_NVIDIA=1 skips it entirely; HWE_NVIDIA_DRIVER
# pins the package if generation detection guesses wrong.

# Pure: map an NVIDIA chip codename (TU116, GA104, GP104, …) to its driver
# package. Open kernel modules cover Turing and newer; older cards (and Volta)
# need the proprietary series. Unknown/blank codename → the proprietary DKMS
# package, which supports the widest card range. Status: 0 confident, 1 fallback.
_nvidia_driver_for_codename() {
    case "${1^^}" in
        TU*|GA*|AD*|GH*|GB*) printf 'nvidia-open-dkms\n'; return 0 ;;  # Turing → Blackwell
        GP*|GM*|GK*|GF*|GV*) printf 'nvidia-dkms\n';      return 0 ;;  # Fermi → Pascal (+Volta)
        *)                   printf 'nvidia-dkms\n';      return 1 ;;  # unknown → safe broad
    esac
}

# True when a display-class NVIDIA device (vendor 10de) is on the bus.
_nvidia_gpu_present() {
    command -v lspci >/dev/null 2>&1 || return 1
    lspci -d 10de:: 2>/dev/null | grep -Eiq 'VGA|3D|Display'
}

# Best-effort chip codename from lspci; empty if pciutils' hwdata doesn't know
# the card (a brand-new GPU on an old hwdata) — the caller falls back safely.
_nvidia_codename() {
    command -v lspci >/dev/null 2>&1 || return 0
    lspci -d 10de:: 2>/dev/null \
        | grep -oE '\b(TU|GA|AD|GH|GB|GP|GM|GK|GF|GV)[0-9]{2,3}\b' | head -n1
}

# Kernel base packages that are actually installed — DKMS needs the matching
# -headers for each so the module builds against every kernel present.
_installed_kernels() {
    pacman -Qq 2>/dev/null | grep -E '^linux(-lts|-zen|-hardened|-rt|-rt-lts)?$' || true
}

# Editable + testable: add the four NVIDIA modules to a mkinitcpio.conf's single
# MODULES=(...) line, once. Operates on the file at $1 so a test can drive it
# against a temp copy — no root, no real /etc. Status: 0 edited, 2 already there,
# 1 no MODULES=() line to edit (unexpected layout — caller warns, doesn't guess).
_mkinitcpio_add_nvidia_modules() {
    local file="$1" mods='nvidia nvidia_modeset nvidia_uvm nvidia_drm'
    grep -q 'nvidia_drm' "$file" 2>/dev/null && return 2
    grep -qE '^MODULES=\(' "$file" 2>/dev/null || return 1
    # Append inside the parens. A leading space in MODULES=( nvidia …) when the
    # list was empty is harmless — mkinitcpio splits the line on whitespace.
    sed -E -i "s/^(MODULES=\()(.*)(\))/\1\2 $mods\3/" "$file"
    grep -q 'nvidia_drm' "$file"
}

# Keep the initramfs rebuilt whenever the driver changes: a new module against a
# stale initramfs is a machine that doesn't boot. Targets the installed driver.
_install_nvidia_pacman_hook() {
    local driver="$1"
    run sudo install -d /etc/pacman.d/hooks
    printf '%s\n' \
        '[Trigger]' 'Operation=Install' 'Operation=Upgrade' 'Operation=Remove' \
        'Type=Package' "Target=$driver" 'Target=nvidia-utils' \
        '' '[Action]' 'Description=Rebuilding initramfs after an NVIDIA driver change (HWE)' \
        'Depends=mkinitcpio' 'When=PostTransaction' 'Exec=/usr/bin/mkinitcpio -P' \
        | run sudo tee /etc/pacman.d/hooks/hwe-nvidia.hook >/dev/null
}

_setup_nvidia() {
    [[ "${HWE_NO_NVIDIA:-0}" == 1 ]] && { info "HWE_NO_NVIDIA=1: skipping NVIDIA setup"; return 0; }
    systemd-detect-virt --quiet 2>/dev/null && return 0   # VM → virtio-gpu, not NVIDIA
    _nvidia_gpu_present || return 0                        # no NVIDIA → nothing to do
    # Driver names, the mkinitcpio rebuild and the pacman update hook are all
    # Arch's. Ubuntu has its own story (ubuntu-drivers, dkms, update-initramfs);
    # until that is written and tested, say so rather than guess at it.
    if [[ "$(_distro_family)" != pacman ]]; then
        warn "NVIDIA GPU detected, but HWE only automates the driver on Arch"
        info "install it the ${HWE_DISTRO} way (e.g. ubuntu-drivers install), then re-run"
        return 0
    fi

    local driver
    if [[ -n "${HWE_NVIDIA_DRIVER:-}" ]]; then
        driver="$HWE_NVIDIA_DRIVER"
        info "NVIDIA GPU detected — using pinned driver '$driver' (HWE_NVIDIA_DRIVER)"
    else
        # Both probes RETURN non-zero on their documented fallback paths — an
        # empty codename from old hwdata, and the unknown-codename default — so
        # under `set -e` a bare assignment here would abort the whole install
        # before the warn/default arms below could run. `|| true` keeps the
        # stdout they already printed while neutralising the status.
        local cn; cn="$(_nvidia_codename || true)"
        driver="$(_nvidia_driver_for_codename "$cn" || true)"
        if [[ -n "$cn" ]]; then
            info "NVIDIA $cn detected — selecting '$driver'"
        else
            warn "NVIDIA GPU detected but its generation is unreadable — defaulting to '$driver'"
            info "for a Turing+ card, re-run with HWE_NVIDIA_DRIVER=nvidia-open-dkms"
        fi
    fi

    log "Configuring NVIDIA: driver + DRM modeset + initramfs"
    warn "this rewrites /etc/mkinitcpio.conf and rebuilds the initramfs"
    warn "'hwe uninstall' does NOT revert it, and it is unverified on real NVIDIA hardware"
    confirm "Set up NVIDIA (driver '$driver')?" || { info "skipped NVIDIA setup"; return 0; }

    local pkgs=("$driver" nvidia-utils egl-wayland) k
    while read -r k; do [[ -n "$k" ]] && pkgs+=("$k-headers"); done < <(_installed_kernels)
    _pacman_retry -S --needed "${pkgs[@]}" \
        || { err "NVIDIA package install failed — boot chain left untouched"; return 1; }

    # DRM modeset is required for Wayland; fbdev=1 gives a working fb console on
    # recent drivers. Our own file — we never edit the user's modprobe configs.
    printf 'options nvidia_drm modeset=1 fbdev=1\n' \
        | run sudo tee /etc/modprobe.d/hwe-nvidia.conf >/dev/null

    # Edit a temp copy with the tested function, then install it back under sudo —
    # so the exact logic the bats suite pins is what runs against real /etc.
    local tmp; tmp="$(mktemp)"; cp /etc/mkinitcpio.conf "$tmp" 2>/dev/null || true
    # `f; local rc=$?` would never reach the assignment: under `set -e` the
    # non-zero return (2 already-present, 1 no MODULES line) aborts first, so the
    # idempotent and warn arms below were dead. Capture the status without aborting.
    local rc=0; _mkinitcpio_add_nvidia_modules "$tmp" || rc=$?
    case $rc in
        0)  run sudo cp -n /etc/mkinitcpio.conf "/etc/mkinitcpio.conf.hwe-bak.$$" 2>/dev/null || true
            run sudo install -m644 "$tmp" /etc/mkinitcpio.conf
            _install_nvidia_pacman_hook "$driver"
            run sudo mkinitcpio -P || warn "mkinitcpio -P failed — check before rebooting"
            ok "NVIDIA configured ($driver). Reboot to load the modules." ;;
        2)  _install_nvidia_pacman_hook "$driver"
            info "mkinitcpio already lists the NVIDIA modules — nothing to rebuild" ;;
        *)  warn "MODULES=() not found in /etc/mkinitcpio.conf — skipped the initramfs edit"
            info "add manually: MODULES=(… nvidia nvidia_modeset nvidia_uvm nvidia_drm), then: sudo mkinitcpio -P" ;;
    esac
    rm -f "$tmp"
}

_enable_services() {
    log "Enabling system services"
    if systemd-detect-virt --quiet 2>/dev/null; then
        # SSH so `hwe vm ssh` works (host keys are generated on first start).
        run sudo systemctl enable --now sshd.service 2>/dev/null || true
        run sudo systemctl enable qemu-guest-agent.service 2>/dev/null || true
        run sudo systemctl enable --now spice-vdagentd.service 2>/dev/null || true
        # In a VM the cloud image already manages networking (systemd-networkd);
        # don't enable NetworkManager here to avoid a two-manager conflict.
    elif [[ "${HWE_NO_NM:-0}" == 1 ]]; then
        info "HWE_NO_NM=1: leaving networking untouched"
    else
        run sudo systemctl enable NetworkManager.service 2>/dev/null || true
    fi
    # User audio stack (pipewire) is socket-activated; nothing to enable here.
    # Bluetooth: enable the daemon (safe if bluez is installed).
    command -v bluetoothctl >/dev/null 2>&1 && run sudo systemctl enable bluetooth.service 2>/dev/null || true
}

# Session entry point. VM/unattended → passwordless tty1 autologin (fast dev
# loop); bare metal → SDDM greeter launching Hyprland via uwsm.
_setup_login() {
    if [[ "${HWE_UNATTENDED:-0}" == 1 ]] || systemd-detect-virt --quiet 2>/dev/null; then
        _setup_autologin
        return 0
    fi
    command -v sddm >/dev/null 2>&1 || {
        info "sddm not installed: no greeter (start Hyprland from a TTY with 'uwsm start hyprland.desktop')"
        return 0
    }
    log "Installing Hyprland (uwsm) session + enabling SDDM"
    run sudo install -Dm644 "$HWE_ROOT/provision/hyprland-uwsm.desktop" \
        /usr/share/wayland-sessions/hyprland-uwsm.desktop
    # Never silently steal an already-configured display manager — let the user
    # decide, so we don't break their current login path.
    local cur; cur="$(systemctl is-enabled display-manager.service 2>/dev/null || true)"
    if [[ -n "$cur" && "$cur" != "disabled" ]] && ! systemctl is-enabled sddm.service >/dev/null 2>&1; then
        warn "another display manager is already enabled — not overriding it"
        info "to switch:  sudo systemctl disable display-manager.service && sudo systemctl enable sddm.service"
    else
        run sudo systemctl enable sddm.service 2>/dev/null || warn "could not enable sddm"
        info "SDDM starts at next boot — your current session is left running"
    fi
    # Theme the greeter from the active palette, and make sure ours is the config
    # that wins. Best-effort: a greeter-sync failure must never abort the install.
    "$HWE_ROOT/bin/hwe" theme sddm || warn "could not sync the SDDM greeter theme"
}

# Autologin on tty1 + start Hyprland — only inside the VM / unattended runs.
# Stand down any display manager that got itself enabled, so tty1 autologin is
# actually reached. Only ever called on the VM path — on bare metal the greeter
# is the intended login route and _setup_login handles it, carefully.
_autologin_disable_dm() {
    local unit=""
    # display-manager.service is an alias symlink; disabling the alias is not
    # reliable, so act on the real unit it points at.
    if [[ -L /etc/systemd/system/display-manager.service ]]; then
        unit="$(basename "$(readlink -f /etc/systemd/system/display-manager.service)")"
    fi
    [[ -n "$unit" ]] || return 0
    systemctl is-enabled "$unit" >/dev/null 2>&1 || return 0
    warn "a display manager ($unit) is enabled in this VM — it would ask for a password"
    info "this VM logs in automatically on tty1; disabling it"
    run sudo systemctl disable --now "$unit" >/dev/null 2>&1 \
        || warn "could not disable $unit — you may get a greeter instead of the session"
}

_setup_autologin() {
    [[ "${HWE_UNATTENDED:-0}" == 1 ]] || systemd-detect-virt --quiet 2>/dev/null || {
        info "not in a VM: skipping tty1 autologin (add 'exec Hyprland' to ~/.bash_profile yourself)"
        return 0
    }
    local user; user="$(id -un)"
    log "Configuring tty1 autologin + Hyprland for '$user'"

    # Debian/Ubuntu enable AND start a service when its package is installed;
    # Arch does not. So on Ubuntu a greeter can seize the login path just by
    # being pulled in — which is exactly what autologin exists to replace here.
    # In a VM tty1 is ours, so take it back explicitly rather than losing a race.
    _autologin_disable_dm

    # agetty is /usr/bin on Arch and /usr/sbin on Debian/Ubuntu. Probe for it
    # instead of hardcoding: the unit's `-` prefix makes a missing binary a
    # SILENT failure, so a wrong path costs you the login with no error anywhere.
    local agetty="" cand
    for cand in /usr/bin/agetty /usr/sbin/agetty /sbin/agetty; do
        [[ -x "$cand" ]] && { agetty="$cand"; break; }
    done
    if [[ -z "$agetty" ]]; then
        warn "agetty not found — skipping tty1 autologin"
        info "you will get an ordinary login prompt on this machine"
        return 0
    fi

    run sudo install -d /etc/systemd/system/getty@tty1.service.d
    # shellcheck disable=SC2016  # $TERM must reach the unit file LITERALLY —
    # systemd expands it at boot; expanding it here would freeze in our own value.
    printf '[Service]\nExecStart=\nExecStart=-%s --autologin %s --noclear %%I $TERM\n' "$agetty" "$user" \
        | run sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf >/dev/null
    run sudo systemctl daemon-reload 2>/dev/null || true

    local prof="$HOME/.bash_profile"
    if ! grep -q 'HWE autostart' "$prof" 2>/dev/null; then
        cat >> "$prof" <<'EOF'

# HWE autostart — launch Hyprland on the first virtual terminal.
# Prefer uwsm (proper systemd user session + env import); fall back to bare
# Hyprland. Bare launch triggers Hyprland's "started without start-hyprland"
# warning, so uwsm is the sanctioned path.
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ "$(tty)" = "/dev/tty1" ]; then
    if command -v uwsm >/dev/null 2>&1 && uwsm check may-start; then
        exec uwsm start hyprland.desktop
    else
        exec Hyprland
    fi
fi
EOF
    fi
}

# Make zsh the login shell and point it at the repo's XDG config. We only write
# the tiny ~/.zshenv bootstrap here (it MUST live at $HOME); the real config
# (.zshrc/.zprofile) is deployed as the ~/.config/zsh symlink by _deploy_configs.
_setup_shell() {
    [[ "${HWE_NO_ZSH:-0}" == 1 ]] && { info "HWE_NO_ZSH=1: leaving login shell unchanged"; return 0; }
    command -v zsh >/dev/null 2>&1 || { info "zsh not installed: skipping shell setup"; return 0; }
    local user zsh_bin; user="$(id -un)"; zsh_bin="$(command -v zsh)"

    # ~/.zshenv is read before anything else and just redirects to ~/.config/zsh.
    if ! grep -q 'ZDOTDIR=.*/.config/zsh' "$HOME/.zshenv" 2>/dev/null; then
        log "Writing ~/.zshenv (ZDOTDIR -> ~/.config/zsh)"
        # shellcheck disable=SC2016  # $HOME must stay literal in the written file:
        # zsh expands it per-user at startup. Baking in our value breaks every
        # other account (and root) that reads this .zshenv.
        printf '# HWE: keep zsh dotfiles under XDG config\nexport ZDOTDIR="$HOME/.config/zsh"\n' \
            > "$HOME/.zshenv"
    fi

    # zsh must be a registered login shell (else some logins fall back to bash).
    if ! grep -qxF "$zsh_bin" /etc/shells 2>/dev/null; then
        info "registering $zsh_bin in /etc/shells"
        printf '%s\n' "$zsh_bin" | run sudo tee -a /etc/shells >/dev/null || true
    fi

    # usermod (root) is more reliable than chsh in a non-interactive context
    # (PAM quirks silently no-op'd chsh — the "kitty opened bash" bug). Verify.
    if [[ "$(getent passwd "$user" | cut -d: -f7)" != "$zsh_bin" ]]; then
        log "Setting login shell to zsh for '$user'"
        run sudo usermod -s "$zsh_bin" "$user" \
            || run sudo chsh -s "$zsh_bin" "$user" \
            || warn "could not change login shell"
    fi
    if [[ "$(getent passwd "$user" | cut -d: -f7)" == "$zsh_bin" ]]; then
        ok "login shell is zsh"
    else
        warn "login shell is still $(getent passwd "$user" | cut -d: -f7) — terminals may open bash"
    fi
}

# Put `hwe` on PATH so it works from the terminal and from keybinds
# (e.g. SUPER+SHIFT+T -> `hwe theme pick`).
_link_cli() {
    log "Linking hwe -> /usr/local/bin/hwe"
    run sudo ln -sf "$HWE_ROOT/bin/hwe" /usr/local/bin/hwe
}

# Images opened from Dolphin should just open, not prompt for an app each time.
# gwenview ships a .desktop that already declares every image type; we only mark
# it the *default*. xdg-mime MERGES into the user's ~/.config/mimeapps.list — it
# never clobbers their browser/other associations — so this is safe + idempotent.
# We don't ship a mimeapps.list in config/ on purpose: it's user-mutable state
# (apps write to it when you pick "always open with…"), so symlinking it fights.
_set_default_apps() {
    command -v xdg-mime >/dev/null 2>&1 || { info "xdg-utils missing: skipping default-app setup"; return 0; }
    local viewer=org.kde.gwenview.desktop
    # Only claim the default if gwenview is actually installed (guards a bad id too).
    [[ -f /usr/share/applications/$viewer ]] \
        || { info "gwenview not installed: leaving image defaults untouched"; return 0; }
    log "Setting gwenview as the default image viewer"
    local t
    for t in image/png image/jpeg image/gif image/webp image/bmp image/tiff \
             image/svg+xml image/x-icon image/avif image/heif image/jxl; do
        run xdg-mime default "$viewer" "$t"
    done
}

# Generate every component's colours from the default theme. The deployed configs
# source/import these generated files, so this MUST succeed for a working desktop.
_apply_default_theme() {
    local theme="${HWE_DEFAULT_THEME:-mocha}"
    log "Generating colours from theme '$theme'"
    "$HWE_ROOT/bin/hwe" theme apply "$theme" \
        || die "theme generation failed — deployed configs depend on it (need python-jinja)"
}

# Keyring + system upgrade. A full -Su on a live daily driver is a surprise, so
# it's opt-in (VM/unattended always does it). The light path never runs a bare
# -Sy (the partial-upgrade footgun) — installs use the current DB.
_pacman_sync() {
    if [[ "${HWE_FULL_UPGRADE:-0}" == 1 || "${HWE_UNATTENDED:-0}" == 1 ]]; then
        _pm_sync 1
    elif [[ "$(_distro_family)" == apt ]]; then
        # apt has no partial-upgrade footgun: refreshing the lists without
        # upgrading is normal and is in fact required before any install.
        _pm_sync 0
    else
        info "full upgrade skipped (set HWE_FULL_UPGRADE=1 to enable)"
        info "installing against your current package DB — if that errors, run 'sudo pacman -Syu' first, then re-run"
    fi
}

# Guardrails before we touch the system: don't wreck a running session, and show
# what's about to happen (skipped under HWE_ASSUME_YES, e.g. the VM).
_install_preflight() {
    if [[ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" && "${HWE_UNATTENDED:-0}" != 1 && "${HWE_FORCE:-0}" != 1 ]]; then
        err "refusing to install from inside a running graphical session"
        info "theme apply reloads the compositor + restarts the bar and would disrupt it"
        info "switch to a TTY (Ctrl+Alt+F3), log in there, and run 'hwe install'"
        info "(or set HWE_FORCE=1 to override)"
        exit 1
    fi
    # Named in the summary because it is the one line here that widens who can
    # put software on this machine — it should not be the quiet one.
    local comp="this distribution's own packages"
    [[ "$HWE_HYPR_SOURCE" == ppa ]] \
        && comp="${C_BOLD}third-party PPA ${HWE_HYPR_PPA}${C_RESET} ${C_DIM}(pinned to the Hyprland stack)${C_RESET}"
    # apt-only, and worth saying: it turns OFF services the distribution turned on.
    local dup=""
    [[ "$(_distro_family)" == apt ]] \
        && dup="
  • stand down packaged user units HWE starts itself   ${C_DIM}(waybar, mako, hypridle, hyprpaper)${C_RESET}"
    local up="no  ${C_DIM}(HWE_FULL_UPGRADE=1 to enable)${C_RESET}"
    case "$(_distro_family)" in
        pacman) local upcmd="pacman -Su" ;;
        apt)    local upcmd="apt-get upgrade" ;;
        *)      local upcmd="system upgrade" ;;
    esac
    [[ "${HWE_FULL_UPGRADE:-0}" == 1 || "${HWE_UNATTENDED:-0}" == 1 ]] && up="YES ($upcmd)"
    cat >&2 <<SUMMARY
${C_BOLD}HWE install will, on this machine:${C_RESET}
  • install packages from pkg/core.lst + pkg/dev.lst   ${C_DIM}(sudo $(_distro_family))${C_RESET}
  • take Hyprland from: ${comp}
  • full system upgrade: ${up}
  • symlink config/* into ~/.config                    ${C_DIM}(existing dirs -> *.hwe-bak)${C_RESET}
  • set gwenview as default image viewer                ${C_DIM}(merged into mimeapps.list)${C_RESET}
  • set your login shell to zsh                         ${C_DIM}(HWE_NO_ZSH=1 to skip)${C_RESET}
  • enable NetworkManager${C_DIM}, and SDDM on bare metal${C_RESET}    ${C_DIM}(HWE_NO_NM=1 to skip NM)${C_RESET}${dup}
  • on an NVIDIA GPU: driver + initramfs setup      ${C_DIM}(bare metal; HWE_NO_NVIDIA=1 to skip)${C_RESET}
  • link 'hwe' into /usr/local/bin
Revert later with:  hwe uninstall
SUMMARY
    confirm "Proceed with HWE install?" || die "aborted"
}

_install_usage() {
    cat >&2 <<'EOF'
usage: hwe install
  Provision THIS machine: packages (pkg/*.lst + your ~/.config/hwe layer),
  configs, the default theme, login shell and services. Uses sudo where needed.
  Prints a summary and asks before it starts (skip the prompt with HWE_ASSUME_YES=1).
  Honours HWE_HYPR_SOURCE (repo|ppa) for where the compositor comes from.
EOF
}

install_main() {
    case "${1:-}" in
        help|-h|--help) _install_usage; return 0 ;;
        "") : ;;
        *) err "hwe install takes no arguments (got '$1')"; _install_usage; return 1 ;;
    esac
    _distro_supported || return 1
    [[ $EUID -eq 0 ]] && die "run 'hwe install' as a normal user (it uses sudo where needed)"

    _install_preflight
    log "HWE install starting on $(uname -n)"
    # Before anything is installed: if the compositor is to come from somewhere
    # other than the distribution, that has to be settled while nothing has been
    # fetched yet. Self-contained (it refreshes its own DB), so the sync below
    # is the ordinary one either way.
    _distro_compositor_source || return 1
    _pacman_sync
    # Before the package steps: your own lists have to exist before they can be
    # read, and hypr.conf before the compositor ever parses hyprland.conf.
    _deploy_user_layer
    _pacman_install core.lst
    _pacman_install dev.lst
    _install_user_packages
    _install_fetched_fonts
    _install_vm_packages
    _setup_nvidia
    _bootstrap_paru
    _aur_install
    _link_cli
    # Generate the theme BEFORE deploying: _deploy_configs symlinks top-level
    # generated files individually, so they must exist at deploy time. (Subdir
    # configs are fine — the whole dir is symlinked regardless.)
    _apply_default_theme
    _deploy_configs
    _set_default_apps
    _setup_shell
    _enable_services
    _disable_duplicate_user_units
    _setup_login

    echo
    ok "HWE install complete."
    info "Hyprland config is health-checked at each login (hwe checkconfig)"
    if [[ "${HWE_UNATTENDED:-0}" == 1 ]]; then
        info "reboot into the Hyprland session:  sudo reboot"
    else
        info "start Hyprland from a TTY with:  Hyprland   (or reboot if autologin was configured)"
    fi
}

# Reverse _deploy_configs + _setup_shell: remove our symlinks, restore the newest
# backup, revert the shell, unlink the CLI. Leaves packages/services (removing
# them could lock the user out) and the repo itself in place.
_uninstall_usage() {
    cat >&2 <<'EOF'
usage: hwe uninstall
  Revert HWE's config symlinks (restoring any *.hwe-bak backups) and the login
  shell. Leaves installed packages and enabled services in place, and never
  touches your ~/.config/hwe layer. Asks before it starts (skip with HWE_ASSUME_YES=1).
EOF
}

uninstall_main() {
    case "${1:-}" in
        help|-h|--help) _uninstall_usage; return 0 ;;
        "") : ;;
        *) err "hwe uninstall takes no arguments (got '$1')"; _uninstall_usage; return 1 ;;
    esac
    confirm "Revert HWE's config symlinks and login shell on $(uname -n)?" \
        || { info "uninstall cancelled — nothing changed"; return 0; }
    log "HWE uninstall — reverting config symlinks + login shell"
    local src name dst bak
    for src in "$HWE_ROOT"/config/*/; do
        [[ -d "$src" ]] || continue
        name="$(basename "$src")"; dst="$HOME/.config/$name"
        if [[ -L "$dst" && "$(readlink -f "$dst")" == "$(readlink -f "${src%/}")" ]]; then
            rm -f "$dst"; info "unlinked ~/.config/$name"
            # shellcheck disable=SC2012  # -t sorts by mtime to find the NEWEST
            # backup; our own "$dst.hwe-bak.$$" names are pid-suffixed, not user input.
            bak="$(ls -1dt "$dst".hwe-bak.* 2>/dev/null | head -n1 || true)"
            [[ -n "$bak" ]] && { mv "$bak" "$dst"; info "restored ~/.config/$name from $(basename "$bak")"; }
        fi
    done
    for src in "$HWE_ROOT"/config/*.toml "$HWE_ROOT"/config/*.conf "$HWE_ROOT"/config/kdeglobals; do
        [[ -f "$src" ]] || continue
        dst="$HOME/.config/$(basename "$src")"
        if [[ -L "$dst" && "$(readlink -f "$dst")" == "$(readlink -f "$src")" ]]; then
            rm -f "$dst"; info "unlinked ~/.config/$(basename "$src")"
            # shellcheck disable=SC2012  # as above: mtime order, our own filenames.
            bak="$(ls -1dt "$dst".hwe-bak.* 2>/dev/null | head -n1 || true)"
            [[ -n "$bak" ]] && { mv "$bak" "$dst"; info "restored ~/.config/$(basename "$src")"; }
        fi
    done

    local user zsh_bin bash_bin; user="$(id -un)"
    zsh_bin="$(command -v zsh 2>/dev/null || true)"; bash_bin="$(command -v bash 2>/dev/null || true)"
    if [[ -n "$zsh_bin" && "$(getent passwd "$user" | cut -d: -f7)" == "$zsh_bin" && -n "$bash_bin" ]]; then
        if confirm "Revert login shell to bash?"; then
            run sudo usermod -s "$bash_bin" "$user" || warn "could not revert shell"
            [[ -f "$HOME/.zshenv" ]] && grep -q 'ZDOTDIR=.*/.config/zsh' "$HOME/.zshenv" 2>/dev/null \
                && { rm -f "$HOME/.zshenv"; info "removed ~/.zshenv"; }
        fi
    fi

    # KDE colour-scheme symlink under XDG_DATA
    local sch="${XDG_DATA_HOME:-$HOME/.local/share}/color-schemes/HWE.colors"
    [[ -L "$sch" ]] && { rm -f "$sch"; info "unlinked color-schemes/HWE.colors"; }

    [[ -L /usr/local/bin/hwe ]] && run sudo rm -f /usr/local/bin/hwe
    rm -f "$HWE_ROOT/config/hypr/assets/current.wall"
    warn "packages + enabled services (SDDM/NetworkManager/bluetooth) were left as-is"
    info "remove them manually if you want a full teardown"
    # The personal layer is not ours to delete: it is the one thing here that
    # was never HWE's, and it outlives both the install and the checkout.
    [[ -d "$HWE_USER_CONFIG" ]] && info "your settings in ~/.config/hwe were left untouched"
    ok "HWE uninstalled — the repo at $HWE_ROOT is untouched"
}

# Allow direct execution: ./provision/guest-install.sh
if [[ -z "${HWE_INSTALL_STANDALONE:-}" && "${BASH_SOURCE[0]}" == "${0}" ]]; then
    install_main "$@"
fi
