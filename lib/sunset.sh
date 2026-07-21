#!/usr/bin/env bash
# lib/sunset.sh — `hwe sunset`: the night light (hyprsunset).
#
#   hwe sunset          toggle it
#   hwe sunset on       start the daemon (it walks its time profiles from there)
#   hwe sunset off      stop it (the compositor drops the tint instantly)
#   hwe sunset status   print on|off; --waybar emits JSON for the bar module
#
# The toggle is start/kill on purpose, not IPC: when hyprsunset dies the
# compositor resets the colour matrix (instant normal screen), and a fresh
# start re-reads the schedule and applies what belongs NOW. `hyprctl
# hyprsunset identity` would instead stick until the next profile boundary —
# an off switch that quietly cancels the evening it was supposed to resume.
#
# The schedule lives in ~/.config/hwe/hyprsunset.conf (personal layer;
# bridged to ~/.config/hypr/hyprsunset.conf, the only path hyprsunset reads).
#
# Sourced by bin/hwe; relies on lib/common.sh helpers.

sunset_main() {
    case "${1:-toggle}" in
        toggle) ;;
        on)  _sunset_on;  return ;;
        off) _sunset_off; return ;;
        status)
            _sunset_status "${2:-}"
            return
            ;;
        help | -h | --help)
            printf 'usage: hwe sunset [toggle|on|off|status]\n  toggle  turn the night light on/off (default; the bar module clicks this)\n  on      start hyprsunset (schedule: ~/.config/hwe/hyprsunset.conf)\n  off     stop it — the screen returns to normal at once\n  status  print on|off (--waybar: JSON for the bar module)\n' >&2
            return 0
            ;;
        *) err "unknown sunset action: ${1}"; printf 'usage: hwe sunset [toggle|on|off|status]\n' >&2; return 1 ;;
    esac

    if _sunset_running; then _sunset_off; else _sunset_on; fi
}

_sunset_running() { pgrep -x hyprsunset >/dev/null 2>&1; }
_sunset_available() { command -v hyprsunset >/dev/null 2>&1; }

_sunset_on() {
    need hyprsunset hyprsunset || return 1
    _sunset_running && { info "night light is already on"; return 0; }
    # setsid: detach from this shell so a keybind/bar click returns at once and
    # the daemon survives the caller.
    (setsid hyprsunset >/dev/null 2>&1 &)
    _sunset_bar_refresh
    ok "night light on (schedule: ~/.config/hwe/hyprsunset.conf)"
}

_sunset_off() {
    _sunset_running || { info "night light is already off"; return 0; }
    # Undo the tint by IPC before the kill: whether the compositor resets the
    # colour matrix when its client dies varies across versions, and a dead
    # daemon can otherwise leave the screen warm with nothing left to ask.
    if command -v hyprctl >/dev/null 2>&1; then
        hyprctl hyprsunset identity >/dev/null 2>&1 || true
    fi
    pkill -x hyprsunset || true
    # Now WAIT for it to die: waybar re-runs the status exec the moment the
    # click handler returns, and a still-dying process reads as "on" — the
    # icon then lies for a full poll interval.
    local _i
    for _i in $(seq 1 40); do
        _sunset_running || break
        sleep 0.05
    done
    _sunset_running && { err "hyprsunset did not stop"; return 1; }
    _sunset_bar_refresh
    ok "night light off"
}

# Nudge the bar to re-read the module now rather than on the next poll. Both
# best-effort: no bar (a bare TTY, a test) is not an error.
_sunset_bar_refresh() {
    pkill -RTMIN+8 -x waybar 2>/dev/null || true
}

# `status --waybar`: JSON for the custom/sunset module. No hyprsunset binary →
# empty output, which hides the module entirely (Ubuntu's archive does not
# carry hyprsunset; the PPA does).
_sunset_status() {
    if ! _sunset_available; then
        [[ "${1:-}" == "--waybar" ]] && return 0
        info "hyprsunset is not installed"
        return 1
    fi
    local state; _sunset_running && state=on || state=off
    if [[ "${1:-}" == "--waybar" ]]; then
        printf '{"text":"󰖔","class":"%s","tooltip":"night light %s — click to turn %s"}\n' \
            "$state" "$state" "$([[ $state == on ]] && echo off || echo on)"
    else
        echo "$state"
    fi
}
