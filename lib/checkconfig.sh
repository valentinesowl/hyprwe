#!/usr/bin/env bash
# lib/checkconfig.sh — `hwe checkconfig`: report Hyprland config errors.
#
# Hyprland changes config syntax aggressively across releases, so a deploy can
# silently break rules. Asks the running compositor via `hyprctl configerrors`.
# Wired into autostart (`hwe checkconfig --notify`) so every login surfaces breakage.
#
# Sourced by bin/hwe; relies on lib/common.sh helpers.

# Locate the Hyprland instance from ANY context (login exec-once, plain terminal,
# ssh) rather than trusting the caller's env — same approach as _theme_reload.
_checkconfig_find_sig() {
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    local sig="${HYPRLAND_INSTANCE_SIGNATURE:-}"
    if [[ -z "$sig" && -d "$XDG_RUNTIME_DIR/hypr" ]]; then
        # shellcheck disable=SC2012  # entries are Hyprland instance signatures
        # (hex), never arbitrary filenames — `find` buys nothing but noise here.
        sig="$(ls "$XDG_RUNTIME_DIR/hypr" 2>/dev/null | head -n1)" || true
    fi
    printf '%s\n' "$sig"
}

# A clean configerrors result: no output at all, or a build that says so in words
# rather than emptily. Shared with doctor (which sources this file) so the two
# never disagree on what "clean" is — a version that prints "no errors" must not
# raise a red login notification here while doctor calls the same config fine.
_hypr_config_clean() {
    [[ -z "$1" || "$1" == *"no errors"* ]]
}

checkconfig_main() {
    local notify=0
    [[ "${1:-}" == "--notify" ]] && notify=1

    local sig; sig="$(_checkconfig_find_sig)"
    if [[ -z "$sig" ]] || ! command -v hyprctl >/dev/null 2>&1; then
        warn "no running Hyprland instance found"
        info "start Hyprland, then run ${C_BOLD}hwe checkconfig${C_RESET}"
        return 0
    fi
    export HYPRLAND_INSTANCE_SIGNATURE="$sig"

    # Clean config => empty output. Drop blank lines so whitespace isn't read as an error.
    local errs; errs="$(hyprctl configerrors 2>/dev/null | sed '/^[[:space:]]*$/d')"
    if _hypr_config_clean "$errs"; then
        ok "Hyprland config OK — no errors"
        return 0
    fi

    err "Hyprland reported config errors:"
    printf '%s\n' "$errs" >&2
    # On-screen heads-up (built-in; needs no libnotify/mako). Best-effort.
    if [[ "$notify" == 1 ]]; then
        hyprctl notify 3 8000 "rgb(ff5555)" \
            "HWE: Hyprland config errors — run 'hwe checkconfig'" >/dev/null 2>&1 || true
    fi
    return 1
}
