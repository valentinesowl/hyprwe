#!/usr/bin/env bash
# lib/hyprland.sh — Hyprland version discovery and the Lua-only release gate.

HWE_HYPR_MIN_VERSION=0.57.0

_hypr_version_number() {
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<<"${1:-}" | head -n1
}

_hypr_version_at_least() {
    local actual minimum
    actual="$(_hypr_version_number "${1:-}")"
    minimum="$(_hypr_version_number "${2:-$HWE_HYPR_MIN_VERSION}")"
    [[ -n "$actual" && -n "$minimum" ]] || return 1
    [[ "$(printf '%s\n%s\n' "$minimum" "$actual" | sort -V | head -n1)" == "$minimum" ]]
}

# Locate the running instance even from ssh or a bare TTY. The caller decides
# whether it needs the environment exported (_hypr_session_env) or just the ID.
_hypr_find_sig() {
    local runtime="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    local sig="${HYPRLAND_INSTANCE_SIGNATURE:-}"
    if [[ -z "$sig" && -d "$runtime/hypr" ]]; then
        # shellcheck disable=SC2012  # instance IDs are compositor-generated names
        sig="$(ls "$runtime/hypr" 2>/dev/null | head -n1)" || true
    fi
    printf '%s\n' "$sig"
}

_hypr_session_env() {
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    local sig; sig="$(_hypr_find_sig)"
    [[ -n "$sig" ]] || return 1
    export HYPRLAND_INSTANCE_SIGNATURE="$sig"
}

_hyprctl() {
    _hypr_session_env || return 1
    hyprctl "$@"
}

_hypr_running_version() {
    local output=""
    if command -v hyprctl >/dev/null 2>&1; then
        output="$(_hyprctl version 2>/dev/null | head -n1 || true)"
    fi
    _hypr_version_number "$output"
}

_hypr_installed_version() {
    local output=""
    # Gates ask about the package on disk. Immediately after an upgrade the old
    # compositor may still be running, so IPC must not make the new package look old.
    if command -v Hyprland >/dev/null 2>&1; then
        output="$(Hyprland --version 2>/dev/null | head -n1 || true)"
    fi
    if [[ -z "$output" ]] && command -v hyprctl >/dev/null 2>&1; then
        output="$(_hyprctl version 2>/dev/null | head -n1 || true)"
    fi
    _hypr_version_number "$output"
}

# During the migration a live 0.56 session can share the checkout with 0.57.
# Select the IPC grammar by the process that will receive it, not the newer binary
# that may already have replaced it on disk.
_hypr_has_lua_dispatch() {
    local version; version="$(_hypr_running_version || true)"
    [[ -n "$version" ]] || version="$(_hypr_installed_version || true)"
    _hypr_version_at_least "$version"
}

_hypr_exec_cmd() {
    local command="$1"
    if _hypr_has_lua_dispatch; then
        hyprctl dispatch "hl.dsp.exec_cmd(\"$command\")"
    else
        hyprctl dispatch exec "$command"
    fi
}

_hypr_dpms() {
    local action="$1"
    [[ "$action" == on || "$action" == off ]] || return 1
    if _hypr_has_lua_dispatch; then
        hyprctl dispatch "hl.dsp.dpms({ action = \"$action\" })"
    else
        hyprctl dispatch dpms "$action"
    fi
}

_hypr_exit() {
    if _hypr_has_lua_dispatch; then
        hyprctl dispatch 'hl.dsp.exit()'
    else
        hyprctl dispatch exit
    fi
}

hypr_main() {
    case "${1:-}" in
        dpms)
            [[ $# -eq 2 ]] || { err "usage: hwe hypr dpms <on|off>"; return 1; }
            _hypr_dpms "$2" || { err "could not set DPMS state to '$2'"; return 1; }
            ;;
        ""|help|-h|--help)
            printf 'usage: hwe hypr dpms <on|off>\n  Compatibility dispatcher for hypridle (0.56 and 0.57+).\n' >&2
            ;;
        *) err "unknown hypr action: $1"; hypr_main help; return 1 ;;
    esac
}

# Hyprland 0.57.1 can report Lua errors here while `hyprctl configerrors` stays
# empty. Verification runs with an isolated runtime so its IPC socket and log do
# not collide with the live compositor. Print only the parser's verdict, without
# ANSI colours, debug messages or the unrelated verifier IPC noise.
_hypr_verify_config() {
    command -v Hyprland >/dev/null 2>&1 || return 1
    local runtime output rc=0 result
    runtime="$(mktemp -d "${TMPDIR:-/tmp}/hwe-verify.XXXXXX")" || return 1
    output="$(XDG_RUNTIME_DIR="$runtime" HYPRLAND_INSTANCE_SIGNATURE=hwe-verify \
        Hyprland --verify-config 2>&1)" || rc=$?
    rm -rf "$runtime"
    # shellcheck disable=SC2001  # strip a variable-length ANSI SGR sequence
    output="$(sed $'s/\033\\[[0-9;]*m//g' <<<"$output")"
    result="$(awk '/^======== Config parsing result:[[:space:]]*$/ { found=1; next }
                   found { print }' <<<"$output" | sed '/^[[:space:]]*$/d')"
    [[ $rc -eq 0 && "$result" == "config ok" ]] && return 0
    if [[ -n "$result" && "$result" != "config ok" ]]; then
        printf '%s\n' "$result"
    else
        printf '%s\n' "$output"
    fi
    return 1
}

_hypr_candidate_version() {
    local output=""
    case "$(_distro_family)" in
        pacman)
            command -v pacman >/dev/null 2>&1 || return 1
            output="$(pacman -Si hyprland 2>/dev/null | sed -nE 's/^Version[[:space:]]*:[[:space:]]*//p' | head -n1)"
            ;;
        apt)
            command -v apt-cache >/dev/null 2>&1 || return 1
            output="$(apt-cache policy hyprland 2>/dev/null | sed -nE 's/^[[:space:]]*Candidate:[[:space:]]*//p' | head -n1)"
            ;;
        *) return 1 ;;
    esac
    [[ -n "$output" && "$output" != "(none)" ]] || return 1
    _hypr_version_number "$output"
}

_hypr_version_refuse() {
    local version="${1:-unknown}" source="${2:-installed}"
    err "Hyprland >= $HWE_HYPR_MIN_VERSION is required by HWE 2.0 (found $version from $source)"
    info "Hyprland 0.57 removed .conf support; this checkout installs only hyprland.lua"
    info "use HWE 1.4.x (legacy-conf) for Hyprland 0.53–0.56, or select a supported package source >= 0.57"
    info "HWE will not change the compositor source or version automatically"
}

_hypr_require_installed() {
    local version
    version="$(_hypr_installed_version || true)"
    [[ -n "$version" ]] || { _hypr_version_refuse unknown installed; return 1; }
    _hypr_version_at_least "$version" || { _hypr_version_refuse "$version" installed; return 1; }
    info "Hyprland $version satisfies the Lua-only requirement (>= $HWE_HYPR_MIN_VERSION)"
}

_hypr_require_candidate() {
    local version
    version="$(_hypr_candidate_version || true)"
    [[ -n "$version" ]] || { _hypr_version_refuse unknown "$HWE_HYPR_SOURCE candidate"; return 1; }
    _hypr_version_at_least "$version" \
        || { _hypr_version_refuse "$version" "$HWE_HYPR_SOURCE candidate"; return 1; }
    info "Hyprland candidate $version from '$HWE_HYPR_SOURCE' satisfies >= $HWE_HYPR_MIN_VERSION"
}
