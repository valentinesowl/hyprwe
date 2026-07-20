#!/usr/bin/env bash
# lib/clip.sh — `hwe clip`: clipboard-history picker (SUPER+C).
#
# History is captured by the `wl-paste --watch cliphist store` autostart lines;
# this just shows it in a themed rofi list and copies the pick back. Reuses the
# launcher's rofi theme (config.rasi) so it matches without a dedicated template.
#
# Sourced by bin/hwe; relies on lib/common.sh helpers.

clip_main() {
    case "${1:-show}" in
        show)
            need cliphist cliphist || return 1
            need wl-copy wl-clipboard || return 1
            # a second press closes an open picker
            if pgrep -x rofi >/dev/null 2>&1; then pkill -x rofi; return 0; fi
            need rofi rofi-wayland || return 1
            local rasi="$HWE_ROOT/config/rofi/config.rasi"
            local -a args=(-dmenu -i -p "Clipboard")
            [[ -f "$rasi" ]] && args+=(-theme "$rasi")
            # Capture the pick, THEN copy. Piping rofi straight into wl-copy meant
            # cancelling (Esc → rofi exits 1, prints nothing) still ran wl-copy with
            # empty stdin, wiping the current clipboard — and pipefail failed the
            # command. An empty or cancelled pick now leaves the clipboard as it is.
            local pick
            pick="$(cliphist list | rofi "${args[@]}")" || return 0
            [[ -n "$pick" ]] || return 0
            printf '%s\n' "$pick" | cliphist decode | wl-copy
            ;;
        wipe)
            need cliphist cliphist || return 1
            cliphist wipe && info "clipboard history cleared"
            ;;
        help|-h|--help)
            printf 'usage: hwe clip [show|wipe]\n  show  clipboard-history picker (rofi; SUPER+C)\n  wipe  clear the stored history\n' >&2
            ;;
        *)
            err "unknown clip action: ${1}"
            printf 'usage: hwe clip [show|wipe]\n' >&2
            return 1
            ;;
    esac
}
