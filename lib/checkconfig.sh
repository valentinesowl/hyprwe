#!/usr/bin/env bash
# lib/checkconfig.sh — `hwe checkconfig`: report Hyprland config errors.
#
# Ask the running compositor AND verify the Lua file itself. Hyprland 0.57.1 can
# keep `hyprctl configerrors` empty for errors inside required Lua modules.
# Wired into autostart (`hwe checkconfig --notify`) so every login surfaces breakage.
#
# Sourced by bin/hwe; relies on lib/common.sh helpers.

# A clean result: no output at all, or a build that says so in words rather than
# emptily. Shared with doctor so both entry points reach the same verdict.
_hypr_config_clean() {
    [[ -z "$1" || "$1" == *"no errors"* ]]
}

_hypr_config_errors() {
    local ipc="" verified=""
    if command -v hyprctl >/dev/null 2>&1 && _hypr_session_env; then
        ipc="$(hyprctl configerrors 2>/dev/null || true)"
    fi
    if command -v Hyprland >/dev/null 2>&1; then
        verified="$(_hypr_verify_config || true)"
    fi
    printf '%s\n' "$ipc" "$verified" | sed '/^[[:space:]]*$/d' | awk '!seen[$0]++'
}

checkconfig_main() {
    local notify_flag=0
    [[ "${1:-}" == "--notify" ]] && notify_flag=1

    if ! command -v Hyprland >/dev/null 2>&1 && ! command -v hyprctl >/dev/null 2>&1; then
        warn "Hyprland is not installed — cannot check its config"
        return 1
    fi

    local errs; errs="$(_hypr_config_errors)"
    if _hypr_config_clean "$errs"; then
        ok "Hyprland config OK — no errors"
        return 0
    fi

    err "Hyprland reported config errors:"
    printf '%s\n' "$errs" >&2
    if [[ "$notify_flag" == 1 ]]; then
        notify error "Hyprland config errors" "Run 'hwe checkconfig' for details"
    fi
    return 1
}
