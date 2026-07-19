#!/usr/bin/env bash
# lib/distro.sh — the one place that knows HWE runs on more than Arch.
#
# Everything else names packages the way HWE's own lists do (Arch names, which
# are the canonical vocabulary of pkg/*.lst) and calls the `_pm_*` verbs below.
# The distro-specific parts — what the package manager is called, how you ask it
# whether something is installed, and what the same software is called elsewhere
# — live here and nowhere else.
#
# Why a name MAP rather than a second set of lists: pkg/core.lst answers "what
# does this environment need", and that answer is the same on every distro. A
# parallel ubuntu/core.lst would be a second copy of that answer, free to drift
# from the first the moment someone adds a package to one of them. A map only
# records the differences, so an unmapped package is not an omission — it is a
# name that happens to be identical, which is the common case (65 of our 96).
#
# Sourced by lib/common.sh, so HWE_DISTRO is available to every module.

# --- which distro is this -------------------------------------------------
# Reads /etc/os-release, the interface every systemd distro provides. ID_LIKE
# catches derivatives (Linux Mint says ID=linuxmint, ID_LIKE="ubuntu debian"),
# so a derivative gets its parent's behaviour instead of an unhelpful refusal.
# Override with HWE_DISTRO to test a backend on the wrong machine.
_distro_detect() {
    [[ -n "${HWE_DISTRO:-}" ]] && return 0
    local id="" like=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091  # a machine-generated file, not ours to lint
        id="$(. /etc/os-release 2>/dev/null && printf '%s' "${ID:-}")"
        like="$(. /etc/os-release 2>/dev/null && printf '%s' "${ID_LIKE:-}")"
    fi
    case " $id $like " in
        *" arch "*)              HWE_DISTRO=arch ;;
        *" ubuntu "*|*" debian "*) HWE_DISTRO=debian ;;
        *)                       HWE_DISTRO="${id:-unknown}" ;;
    esac
    export HWE_DISTRO
}

# The package-manager family, which is what the _pm_* verbs actually switch on.
# Kept separate from HWE_DISTRO so a future Fedora is one case arm, not a rename.
_distro_family() {
    case "${HWE_DISTRO:-}" in
        arch)   printf 'pacman\n' ;;
        debian) printf 'apt\n' ;;
        *)      printf 'unknown\n' ;;
    esac
}

# Refuse early and clearly rather than half-installing onto something we do not
# know how to drive.
_distro_supported() {
    case "$(_distro_family)" in
        pacman|apt) return 0 ;;
        *)
            err "unsupported distribution: ${HWE_DISTRO:-unknown}"
            info "HWE installs on Arch and on Ubuntu/Debian; set HWE_DISTRO to force one"
            return 1
            ;;
    esac
}

# --- package name translation ---------------------------------------------
# pkg/map/<family>.map is TSV: an Arch name, then the local name(s) separated by
# spaces, or `-` for "this package does not exist here and nothing replaces it".
# One Arch name may map to several (openssh -> openssh-client openssh-server).
# An unmapped name passes through unchanged.
_pm_map_file() { printf '%s/pkg/map/%s.map\n' "$HWE_ROOT" "$(_distro_family)"; }

# Translate names on stdin (one per line) to local ones on stdout. Reading the
# map into an array once keeps this O(n) for a 96-package list.
_pm_translate() {
    local map; map="$(_pm_map_file)"
    if [[ ! -f "$map" ]]; then cat; return 0; fi
    local -A m=()
    local from to
    while IFS=$'\t' read -r from to; do
        [[ -z "$from" || "$from" == \#* ]] && continue
        m["$from"]="$to"
    done < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$map")

    local name; local -a into=()
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        if [[ -v m["$name"] ]]; then
            # `-` means: intentionally dropped on this distro (Arch-only tooling).
            [[ "${m[$name]}" == "-" ]] && continue
            # Split on whitespace explicitly — one Arch name may become several
            # local ones. `read -a` rather than an unquoted expansion so a stray
            # `*` in the map cannot glob against the working directory.
            read -r -a into <<<"${m[$name]}"
            printf '%s\n' "${into[@]}"
        else
            printf '%s\n' "$name"
        fi
    done
}

# --- package manager verbs ------------------------------------------------
# Slow-mirror tolerant on both sides: a stalled download was the #1 provisioning
# failure on Arch, and apt behind a flaky mirror fails the same way.
_pm_retry() {
    local tries=0 max=3
    while true; do
        if "$@"; then return 0; fi
        tries=$((tries + 1))
        [[ $tries -ge $max ]] && { err "package transaction failed after $max attempts"; return 1; }
        warn "package transaction failed — refreshing and retrying ($tries/$max)"
        case "$(_distro_family)" in
            pacman) sudo pacman -Syy --noconfirm --disable-download-timeout >/dev/null 2>&1 || true ;;
            apt)    sudo apt-get update -qq >/dev/null 2>&1 || true ;;
        esac
        sleep 3
    done
}

# Refresh the package database. A full upgrade is deliberate, not implied: on
# Arch a partial upgrade breaks a system, which is why the keyring comes first.
_pm_sync() {
    local full="${1:-0}"
    case "$(_distro_family)" in
        pacman)
            if [[ "$full" == 1 ]]; then
                log "Refreshing package DB and upgrading the system"
                _pm_retry sudo pacman -Sy --noconfirm --disable-download-timeout archlinux-keyring
                _pm_retry sudo pacman -Su --noconfirm --disable-download-timeout
            else
                log "Refreshing package DB"
                _pm_retry sudo pacman -Sy --noconfirm --disable-download-timeout
            fi
            ;;
        apt)
            log "Refreshing package lists"
            _pm_retry sudo apt-get update -qq
            if [[ "$full" == 1 ]]; then
                log "Upgrading the system"
                _pm_retry sudo env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
            fi
            ;;
    esac
}

# Install the given packages (already-local names), skipping the ones present.
#
# --no-install-recommends is not thrift, it is the translation. pkg/*.lst is
# written in Arch's vocabulary AND Arch's semantics: pacman never installs
# optdepends, so the list means "these packages". apt installs Recommends by
# default, so the same list means "these packages and whatever their maintainers
# suggest" — a different system wearing the same name.
#
# Not hypothetical. The first Ubuntu VM came up at 1926 packages and greeted its
# user with a GDM password prompt: network-manager-applet Recommends gnome-shell,
# which depends on gdm3, and Debian ENABLES a service the moment it is installed.
# A greeter nobody asked for took over the login path, from a recommendation.
# Anything genuinely needed belongs in pkg/*.lst by name, where it can be seen.
_pm_install() {
    [[ $# -gt 0 ]] || return 0
    case "$(_distro_family)" in
        pacman) _pm_retry sudo pacman -S --needed --noconfirm --disable-download-timeout "$@" ;;
        # -q, NOT -qq. `-qq` means "no output at all", which on a slow mirror
        # produces several silent minutes that are indistinguishable from a hang
        # — during provisioning the console is the only feedback there is, and a
        # progress-free install reads as a dead one. `-q` still drops the
        # progress bars that would be useless in a log, and keeps the per-package
        # Get:/Setting up: lines that show it is alive.
        #
        # apt-get rather than apt on purpose: apt is the human-facing front end
        # and says outright that its CLI is not stable across versions; apt-get
        # is the interface meant to be scripted against.
        apt)    _pm_retry sudo env DEBIAN_FRONTEND=noninteractive \
                    apt-get install -y -q --no-install-recommends "$@" ;;
    esac
}

# Of the given packages, print the ones NOT satisfied — one per line, nothing on
# stdout when everything is present. `pacman -T` is exactly this question and
# understands versions, provides and virtual packages. dpkg has no equivalent, so
# apt gets a per-package status check; a name satisfied only through Provides
# will look missing, which is what the map is for (map it to its real provider).
_pm_missing() {
    [[ $# -gt 0 ]] || return 0
    case "$(_distro_family)" in
        pacman) pacman -T "$@" 2>/dev/null || true ;;
        apt)
            local p st
            for p in "$@"; do
                st="$(dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null || true)"
                [[ "$st" == "installed" ]] || printf '%s\n' "$p"
            done
            ;;
    esac
}

# The command a user is told to run when something is missing and we will not
# install it for them.
_pm_install_hint() {
    case "$(_distro_family)" in
        pacman) printf 'sudo pacman -S %s\n' "$*" ;;
        apt)    printf 'sudo apt install %s\n' "$*" ;;
        *)      printf 'install %s\n' "$*" ;;
    esac
}

# --- where the compositor comes from --------------------------------------
# On Arch this question does not exist: Hyprland is in the repos and tracks
# upstream. On Ubuntu the archive's copy is 0.53.3 in `universe` — a community
# package with no vendor security SLA, frozen for the life of the release.
#
# So HWE offers both, and makes the choice explicit rather than convenient:
#
#   repo (default)  the distribution's own package. Whatever it is, it is what
#                   the machine already trusts. Nothing new is granted.
#   ppa             a third-party archive with current Hyprland. NOT a default,
#                   ever. Adding a PPA the ordinary way hands its key the right
#                   to install ANY package on that machine, for good — a far
#                   larger grant than the one package you wanted.
#
# Building from source is deliberately not offered: Hyprland's dependency
# cluster (aquamarine, hyprutils, hyprlang, hyprgraphics, hyprwire, hyprtoolkit)
# moves independently, and scripting it would make HWE a permanent build system
# for someone else's compositor.
#
# Setting HWE_HYPR_SOURCE=ppa IS the consent. It is deliberately NOT covered by
# HWE_ASSUME_YES: a blanket "yes to prompts" must never be what extends trust to
# a stranger — that has to be its own act.
: "${HWE_HYPR_SOURCE:=repo}"
: "${HWE_HYPR_PPA:=cppiber/hyprland}"
: "${HWE_HYPR_PPA_FP:=A54D23B62FF3FCC76EFF71E8FDBAAA1CF0CCF48E}"
: "${HWE_HYPR_PPA_ORIGIN:=LP-PPA-cppiber-hyprland}"

# The packages the PPA is ALLOWED to supply. Everything else stays the
# distribution's, enforced by apt pinning rather than by good intentions — see
# _hypr_ppa_enable. Measured, not guessed: with this list, installing the stack
# on resolute draws 16 packages from the PPA out of 346, and all 16 are
# Hyprland's own. libudis86 is on it because the PPA is the only place resolute
# has it at all; wayland-protocols is NOT, because the archive has it and the
# archive's copy is the one we want even though the PPA ships a newer one.
HWE_HYPR_PPA_PKGS='hypr* libhypr* libaquamarine* libudis86* xdg-desktop-portal-hyprland*'

_hypr_apt_keyring=/etc/apt/keyrings/hwe-hyprland.gpg
_hypr_apt_source=/etc/apt/sources.list.d/hwe-hyprland.sources
_hypr_apt_prefs=/etc/apt/preferences.d/hwe-hyprland

# Say plainly what is being granted, to whom, and how far it reaches. This prints
# even unattended: a grant nobody can find in the log is not much of a grant.
_hypr_ppa_announce() {
    warn "compositor source: THIRD-PARTY PPA ${C_BOLD}${HWE_HYPR_PPA}${C_RESET}, not Ubuntu"
    info "signing key pinned to $HWE_HYPR_PPA_FP"
    info "apt pinning confines it to: $HWE_HYPR_PPA_PKGS"
    info "every other package on this machine stays Ubuntu's — including ones"
    info "this PPA also publishes and versions it rates higher"
    info "undo with: sudo rm $_hypr_apt_source $_hypr_apt_prefs $_hypr_apt_keyring"
}

# Fetch the pinned key BY FULL FINGERPRINT — a keyserver can hand us a key, but
# never a DIFFERENT one, since the fingerprint is the key's own hash.
_hypr_ppa_fetch_key() {
    local ring ks ok=1
    ring="$(mktemp -d)"; chmod 700 "$ring"
    for ks in hkps://keyserver.ubuntu.com hkps://keys.openpgp.org; do
        if gpg --homedir "$ring" --batch --no-tty --keyserver "$ks" \
               --recv-keys "$HWE_HYPR_PPA_FP" >/dev/null 2>&1; then ok=0; break; fi
    done
    if [[ $ok -ne 0 ]]; then
        rm -rf "$ring"; err "could not fetch the PPA signing key $HWE_HYPR_PPA_FP"; return 1
    fi
    # Prove we hold the key we asked for before it is allowed to vouch for bytes.
    if ! gpg --homedir "$ring" --batch --no-tty --list-keys "$HWE_HYPR_PPA_FP" >/dev/null 2>&1; then
        rm -rf "$ring"; err "keyserver returned a key that is not $HWE_HYPR_PPA_FP"; return 1
    fi
    run sudo install -d -m 0755 /etc/apt/keyrings
    gpg --homedir "$ring" --batch --no-tty --export "$HWE_HYPR_PPA_FP" \
        | run sudo tee "$_hypr_apt_keyring" >/dev/null
    rm -rf "$ring"
}

_hypr_ppa_enable() {
    local suite
    suite="$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_CODENAME:-}")"
    [[ -n "$suite" ]] || { err "cannot read VERSION_CODENAME from /etc/os-release"; return 1; }

    _hypr_ppa_announce
    _hypr_ppa_fetch_key || return 1

    printf '%s\n' \
        'Types: deb' \
        "URIs: https://ppa.launchpadcontent.net/${HWE_HYPR_PPA}/ubuntu" \
        "Suites: $suite" \
        'Components: main' \
        "Signed-By: $_hypr_apt_keyring" \
        | run sudo tee "$_hypr_apt_source" >/dev/null

    # Default -1 (never), then an allowlist above the archive's 500. Without the
    # first stanza this would be an ordinary PPA — that is, a general-purpose
    # key on the machine, which is the thing we are declining to hand out.
    printf '%s\n' \
        'Package: *' \
        "Pin: release o=$HWE_HYPR_PPA_ORIGIN" \
        'Pin-Priority: -1' \
        '' \
        "Package: $HWE_HYPR_PPA_PKGS" \
        "Pin: release o=$HWE_HYPR_PPA_ORIGIN" \
        'Pin-Priority: 600' \
        | run sudo tee "$_hypr_apt_prefs" >/dev/null

    _pm_sync 0
}

# Called once by the installer, before anything is installed.
_distro_compositor_source() {
    case "$HWE_HYPR_SOURCE" in
        repo) return 0 ;;
        ppa)
            if [[ "$(_distro_family)" != apt ]]; then
                warn "HWE_HYPR_SOURCE=ppa is an apt-family option — ignoring it on ${HWE_DISTRO}"
                info "on Arch, Hyprland comes from the distribution and already tracks upstream"
                return 0
            fi
            _hypr_ppa_enable
            ;;
        *)
            err "unknown HWE_HYPR_SOURCE='$HWE_HYPR_SOURCE' (expected 'repo' or 'ppa')"
            return 1
            ;;
    esac
}

_distro_detect
