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

_distro_detect
