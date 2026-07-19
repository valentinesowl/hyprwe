#!/usr/bin/env bash
# lib/common.sh — shared helpers for the HWE toolchain.
# Sourced by bin/hwe and the lib/*.sh modules. Never executed directly.

# --- Colours (respect NO_COLOR and non-tty) -------------------------------
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\e[0m'; C_DIM=$'\e[2m'; C_BOLD=$'\e[1m'
    C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
    C_BLUE=$'\e[34m'; C_CYAN=$'\e[36m'
else
    C_RESET=''; C_DIM=''; C_BOLD=''
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''
fi

log()   { printf '%s\n' "${C_CYAN}::${C_RESET} $*" >&2; }
info()  { printf '%s\n' "${C_BLUE}  ->${C_RESET} $*" >&2; }
ok()    { printf '%s\n' "${C_GREEN}  ok${C_RESET} $*" >&2; }
warn()  { printf '%s\n' "${C_YELLOW}warn${C_RESET} $*" >&2; }
err()   { printf '%s\n' "${C_RED}fail${C_RESET} $*" >&2; }
die()   { err "$*"; exit 1; }

# Ask a yes/no question (default No). Auto-yes when HWE_ASSUME_YES=1.
confirm() {
    local prompt="${1:-Proceed?}"
    if [[ "${HWE_ASSUME_YES:-0}" == 1 ]]; then return 0; fi
    local reply
    read -r -p "${C_YELLOW}??${C_RESET} ${prompt} [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

# Require a command to exist, else die with an install hint.
need() {
    local cmd="$1" hint="${2:-}"
    command -v "$cmd" >/dev/null 2>&1 && return 0
    err "missing required command: ${C_BOLD}${cmd}${C_RESET}"
    [[ -n "$hint" ]] && info "install: $hint"
    return 1
}

# Run a command, echoing it first (for transparency of privileged ops).
run() {
    info "${C_DIM}\$ $*${C_RESET}"
    "$@"
}

# --- Paths ----------------------------------------------------------------
# HWE_ROOT is exported by bin/hwe before sourcing this file.
: "${HWE_ROOT:?HWE_ROOT must be set}"
# shellcheck disable=SC2034  # read by the sourced lib/*.sh modules (wall, vm)
HWE_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/hwe"

# --- The personal layer ---------------------------------------------------
# ~/.config/hwe/ holds what is YOURS rather than HWE's: the settings that differ
# per machine and per person — displays, keybinds, extra packages, the bar's
# composition. It sits OUTSIDE the checkout on purpose. The repo is deployed by
# symlink, so a tweak made in place would be a change to a tracked file, and
# `hwe update`'s fast-forward pull refuses to run on a dirty tree — personalising
# the machine would cost you the ability to update it. Here, neither can happen:
# `git status` stays clean, a pull can never conflict, and replacing the clone
# does not take your settings with it.
#
# The files (skeletons in provision/userlayer/, copied once by the install):
#   hypr.conf           sourced last by hyprland.conf — displays, input, binds
#   packages.lst        extra packages for this machine (pacman)
#   packages-aur.lst    same, from the AUR
#   waybar.jsonc        bar composition, deep-merged over the generated config
#
# Overridable like the theme roots, so the tests can exercise the layer without
# writing into the live ~/.config of whoever runs them.
: "${HWE_USER_CONFIG:=${XDG_CONFIG_HOME:-$HOME/.config}/hwe}"

# --- Themes ---------------------------------------------------------------
# Themes live in two roots: the ones HWE ships (repo themes/, tracked by git) and
# your own (XDG data dir). Keeping yours OUT of the repo is the point: nothing
# you write shows up in `git status`, collides on `git pull`, or disappears when
# the checkout is replaced. Same anatomy in both — a directory holding theme.toml.
: "${HWE_THEMES:=$HWE_ROOT/themes}"
: "${HWE_THEMES_USER:=${XDG_DATA_HOME:-$HOME/.local/share}/hwe/themes}"
# The applied theme is remembered by NAME, so it resolves through either root.
: "${HWE_THEME_CURRENT:=$HWE_THEMES/.current}"

# Theme roots, in precedence order: yours first, so a theme of your own shadows a
# shipped one of the same name (that is how you retune `frost` without editing
# the repo). `theme list` marks which is which.
_theme_roots() {
    printf '%s\n' "$HWE_THEMES_USER" "$HWE_THEMES"
}

# A theme name addresses a directory, so it must BE a plain directory name: no
# slash (path traversal out of the roots), no leading dot (the roots' own state,
# e.g. .current), no leading dash (an option to the commands we hand it to).
_theme_name_ok() {
    [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

# Resolve a theme name to its directory, honouring root precedence. Prints the
# path; returns 1 if the name is malformed or no root holds such a theme.
_theme_dir() {
    local name="${1:-}" root
    _theme_name_ok "$name" || return 1
    while IFS= read -r root; do
        [[ -f "$root/$name/theme.toml" ]] && { printf '%s\n' "$root/$name"; return 0; }
    done < <(_theme_roots)
    return 1
}
