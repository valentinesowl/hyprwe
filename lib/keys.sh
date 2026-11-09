#!/usr/bin/env bash
# lib/keys.sh — `hwe keys`: a themed, read-only keybind cheatsheet (SUPER+/).
# Reads the binds registered by the running compositor, including personal ones.

keys_main() {
    case "${1:-}" in
        help|-h|--help)
            printf 'usage: hwe keys\n  Keybind cheatsheet overlay (rofi; SUPER+/).\n' >&2
            return 0 ;;
    esac
    if pgrep -x rofi >/dev/null 2>&1; then pkill -x rofi; return 0; fi
    need rofi rofi-wayland || return 1
    need python3 || return 1
    command -v hyprctl >/dev/null 2>&1 || { err "hyprctl not found — start Hyprland first"; return 1; }

    local rasi="$HWE_ROOT/config/rofi/keys.rasi"
    local -a args=(-dmenu -i -p "" -mesg "" -no-custom -theme-str 'entry { enabled: false; }')
    [[ -f "$rasi" ]] && args+=(-theme "$rasi")

    local binds
    binds="$(hyprctl binds -j)" || { err "could not read binds from the running Hyprland session"; return 1; }
    printf '%s\n' "$binds" | _keys_render | rofi "${args[@]}" >/dev/null 2>&1 || true
    return 0
}

_keys_render() {
    python3 "$HWE_ROOT/scripts/keybinds.py"
}
