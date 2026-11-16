#!/usr/bin/env bash
# lib/control.sh — `hwe control`: toggle the bottom Control Shelf.

control_main() {
    case "${1:-}" in
        help|-h|--help)
            printf 'usage: hwe control\n  Toggle the bottom Control Shelf (SUPER+SHIFT+Up).\n' >&2
            return 0 ;;
        "") ;;
        *) err "hwe control takes no arguments"; return 1 ;;
    esac

    local script="$HWE_ROOT/scripts/control_shelf.py"
    local pattern="^python3 $script\$"
    if pgrep -f "$pattern" >/dev/null 2>&1; then
        pkill -USR1 -f "$pattern"
        return 0
    fi

    need python3 || return 1
    need pkg-config pkgconf || return 1
    [[ -f "$script" ]] || { err "Control Shelf is missing: $script"; return 1; }
    if ! python3 -c 'import gi; gi.require_version("Gtk", "4.0"); gi.require_version("Gtk4LayerShell", "1.0")' 2>/dev/null; then
        err "Control Shelf needs python-gobject, GTK4 and Gtk4LayerShell"
        return 1
    fi

    local libdir preload
    libdir="$(pkg-config --variable=libdir gtk4-layer-shell-0 2>/dev/null)" || {
        err "Control Shelf needs gtk4-layer-shell"
        return 1
    }
    preload="$libdir/libgtk4-layer-shell.so"
    [[ -f "$preload" ]] || { err "Control Shelf library is missing: $preload"; return 1; }

    mkdir -p "$HWE_CACHE"
    LD_PRELOAD="$preload${LD_PRELOAD:+:$LD_PRELOAD}" \
        python3 "$script" >> "$HWE_CACHE/control-shelf.log" 2>&1 &
    disown
}
