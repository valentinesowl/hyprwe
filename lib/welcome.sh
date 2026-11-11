#!/usr/bin/env bash
# lib/welcome.sh — `hwe welcome`: a one-time first-login greeting.
#
# Run from autostart.lua. On the very first graphical login it pops a
# short on-screen notice pointing at the keybind cheatsheet, then drops a
# sentinel so it never nags again. `--force` shows it regardless (for testing).
#
# Sourced by bin/hwe; relies on lib/common.sh helpers.

welcome_main() {
    local state="${XDG_STATE_HOME:-$HOME/.local/state}/hwe"
    local flag="$state/welcomed"

    if [[ "${1:-}" != "--force" && -f "$flag" ]]; then
        return 0
    fi
    mkdir -p "$state" && : >"$flag"

    notify info "Welcome to HWE" "Press SUPER + / for the keybind cheatsheet"
}
