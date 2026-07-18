#!/usr/bin/env bash
# lib/clip.sh — `hwe clip`: clipboard-history picker (SUPER+C).
#
# History is captured by the `wl-paste --watch cliphist store` autostart lines;
# this just shows it in a themed rofi list and copies the pick back. Reuses the
# launcher's rofi theme (config.rasi) so it matches without a dedicated template.
#
# Sourced by bin/hwe; relies on lib/common.sh helpers.

clip_main() {
    need cliphist "sudo pacman -S cliphist" || return 1
    need wl-copy "sudo pacman -S wl-clipboard" || return 1

    case "${1:-show}" in
        show)
            # a second press closes an open picker
            if pgrep -x rofi >/dev/null 2>&1; then pkill -x rofi; return 0; fi
            need rofi "sudo pacman -S rofi-wayland" || return 1
            local rasi="$HWE_ROOT/config/rofi/config.rasi"
            local -a args=(-dmenu -i -p "Clipboard")
            [[ -f "$rasi" ]] && args+=(-theme "$rasi")
            cliphist list | rofi "${args[@]}" | cliphist decode | wl-copy
            ;;
        wipe)
            cliphist wipe && info "clipboard history cleared"
            ;;
        *)
            err "usage: hwe clip [show|wipe]"; return 1
            ;;
    esac
}
