#!/usr/bin/env bash
# lib/record.sh — `hwe record`: toggle screen recording (wf-recorder).
#
#   hwe record          toggle: start full-screen capture, or stop a running one
#   hwe record region   toggle: start a slurp-selected region instead
#   hwe record status    print "recording" / "idle" (used by the waybar module)
#
# A single wf-recorder process is the source of truth: if one runs, any toggle
# stops it (SIGINT finalises the .mp4). Output lands in ~/Videos. The waybar
# custom/record module polls `hwe record status` and shows ● REC while active.
#
# Sourced by bin/hwe; relies on lib/common.sh helpers.

record_main() {
    case "${1:-toggle}" in
        status)
            pgrep -x wf-recorder >/dev/null 2>&1 && echo recording || echo idle
            return 0
            ;;
        toggle | region) ;;
        *) err "usage: hwe record [toggle|region|status]"; return 1 ;;
    esac

    # A running capture means "stop", regardless of the requested mode.
    if pgrep -x wf-recorder >/dev/null 2>&1; then
        pkill -INT -x wf-recorder
        _record_notify "Recording stopped" "Saved to ~/Videos"
        return 0
    fi

    need wf-recorder wf-recorder || return 1
    local dir="$HOME/Videos"
    mkdir -p "$dir"
    local out
    out="$dir/rec_$(date +%F_%H-%M-%S).mp4"

    local -a geo=()
    if [[ "${1:-}" == region ]]; then
        need slurp slurp || return 1
        local g
        g="$(slurp)" || return 0 # cancelled selection: abort cleanly
        geo=(-g "$g")
    fi

    # Detached so the keybind returns immediately; wf-recorder keeps running.
    wf-recorder "${geo[@]}" -f "$out" >/dev/null 2>&1 &
    disown
    _record_notify "Recording…" "→ ${out/#$HOME/\~}"
}

# Best-effort on-screen feedback via Hyprland's built-in notify (no libnotify).
_record_notify() {
    command -v hyprctl >/dev/null 2>&1 || return 0
    hyprctl notify -1 3000 "rgb(ee4444)" "  $1${2:+ — $2}" >/dev/null 2>&1 || true
}
