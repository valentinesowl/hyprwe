#!/usr/bin/env bash
# lib/center.sh — `hwe center`: one keyboard-driven entry point to the workstation.
# Navigation only: every action still goes through the regular hwe CLI.

center_usage() {
    cat >&2 <<EOF
${C_BOLD}hwe center${C_RESET} — command center for the workstation

${C_BOLD}Usage:${C_RESET} hwe center [themes|sessions|system|vm|tools]

Without a section, opens the main menu (${C_BOLD}SUPER+A${C_RESET}).
Every action delegates to the corresponding ${C_BOLD}hwe${C_RESET} command.
Escape closes a menu without changing anything.
EOF
}

center_main() {
    local section="${1:-}"
    [[ $# -eq 0 ]] || shift
    case "$section" in
        ""|themes|sessions|system|vm|tools) ;;
        help|-h|--help) center_usage; return 0 ;;
        *) err "unknown center section: $section"; center_usage; return 1 ;;
    esac
    [[ $# -eq 0 ]] || { err "hwe center $section takes no arguments"; return 1; }
    if pgrep -x rofi >/dev/null 2>&1; then pkill -x rofi; return 0; fi
    need rofi rofi-wayland || return 1

    case "$section" in
        "")       _center_root ;;
        themes)   _center_themes ;;
        sessions) _center_sessions ;;
        system)   _center_system ;;
        vm)       _center_vm ;;
        tools)    _center_tools ;;
    esac
}

_center_theme() {
    printf '%s\n' "$HWE_ROOT/config/rofi/center.rasi"
}

# Print the selected zero-based row, never its display text. Labels can then carry
# status and descriptions without becoming part of command dispatch.
_center_menu() {
    local prompt="$1" message="$2"
    shift 2
    local count=$# choice rasi
    rasi="$(_center_theme)"
    local -a args=(-dmenu -i -format i -no-custom -p "$prompt" -mesg "$message")
    [[ -f "$rasi" ]] && args+=(-theme "$rasi")
    choice="$(printf '%s\n' "$@" | rofi "${args[@]}")" || return 1
    [[ "$choice" =~ ^[0-9]+$ ]] || return 1
    ((choice >= 0 && choice < count)) || return 1
    printf '%s\n' "$choice"
}

_center_input() {
    local prompt="$1" message="$2" rasi choice
    rasi="$(_center_theme)"
    local -a args=(-dmenu -i -p "$prompt" -mesg "$message"
        -theme-str 'listview { enabled: false; }')
    [[ -f "$rasi" ]] && args+=(-theme "$rasi")
    choice="$(printf '' | rofi "${args[@]}")" || return 1
    [[ -n "$choice" ]] || return 1
    printf '%s\n' "$choice"
}

# Cancel is first and selected by default. Closing the dialog is also cancellation.
_center_confirm() {
    local action="$1" detail="$2" rasi choice
    rasi="$(_center_theme)"
    local -a args=(-dmenu -i -format i -no-custom -selected-row 0
        -p "Confirm" -mesg "$action · $detail"
        -theme-str 'message { text-color: @urgent; }')
    [[ -f "$rasi" ]] && args+=(-theme "$rasi")
    choice="$(printf 'Cancel\nConfirm\n' | rofi "${args[@]}")" || return 1
    [[ "$choice" == 1 ]]
}

_center_run() {
    "$HWE_ROOT/bin/hwe" "$@"
}

# Long provisioning and maintenance output belongs in a real terminal, not in a
# menu that looks frozen. --hold keeps the result available after the command ends.
_center_terminal() {
    local title="$1"
    shift
    need kitty kitty || return 1
    kitty --title "$title" --hold -e env "HWE_ASSUME_YES=${HWE_ASSUME_YES:-0}" \
        "$HWE_ROOT/bin/hwe" "$@"
}

_center_capture() {
    NO_COLOR=1 "$HWE_ROOT/bin/hwe" "$@" 2>&1
}

_center_report() {
    local title="$1"
    shift
    local report rasi
    report="$(_center_capture "$@" || true)"
    [[ -n "$report" ]] || report="No output."
    rasi="$(_center_theme)"
    local -a args=(-dmenu -i -no-custom -p "$title"
        -mesg "Read-only report · Escape closes"
        -theme-str 'window { width: 980px; } listview { lines: 18; } element { padding: 2px 8px; }')
    [[ -f "$rasi" ]] && args+=(-theme "$rasi")
    printf '%s\n' "$report" | rofi "${args[@]}" >/dev/null 2>&1 || true
    return 0
}

_center_root() {
    local theme choice
    theme="$(_theme_current)"
    choice="$(_center_menu "hyprwe" \
        "COMMAND CENTER\n${theme:-no theme} · v$HWE_VERSION · choose a section" \
        "01  Themes          Palette and wallpaper" \
        "02  Sessions        Save and restore the workstation" \
        "03  System          Health, drift and updates" \
        "04  Virtual machines  Rehearse this working tree" \
        "05  Utilities       Desktop tools and shortcuts")" || return 0
    case "$choice" in
        0) _center_themes ;;
        1) _center_sessions ;;
        2) _center_system ;;
        3) _center_vm ;;
        4) _center_tools ;;
    esac
}

_center_themes() {
    local current choice
    current="$(_theme_current)"
    choice="$(_center_menu "Themes" \
        "APPEARANCE\nCurrent: ${current:-none}" \
        "Choose theme         Preview and apply a complete palette" \
        "Choose wallpaper     Keep the current theme, change its image" \
        "Reapply current      Render and reload the active theme" \
        "Back                 Return to the command center")" || return 0
    case "$choice" in
        0) _center_run theme pick ;;
        1) _center_run wall pick ;;
        2) _center_run theme apply ;;
        3) _center_root ;;
    esac
}

_center_session_dir() {
    printf '%s\n' "${HWE_SESSION_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/hwe/sessions}"
}

_center_session_names() {
    local dir path name
    dir="$(_center_session_dir)"
    for path in "$dir"/*.json; do
        [[ -f "$path" ]] || continue
        name="$(basename "$path" .json)"
        [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && printf '%s\n' "$name"
    done
    return 0
}

_center_session_pick() {
    local action="$1"
    local -a names=()
    mapfile -t names < <(_center_session_names)
    if [[ ${#names[@]} -eq 0 ]]; then
        notify info "Sessions" "No saved snapshots yet"
        return 1
    fi
    _center_menu "Sessions" "$action\nChoose a named snapshot" "${names[@]}"
}

_center_save_session() {
    local name dir
    name="$(_center_input "Save session" \
        "NEW SNAPSHOT\nName: letters, digits, dots, underscores and dashes")" || return 0
    if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        notify error "Invalid session name" "Use letters, digits, dots, underscores and dashes"
        return 1
    fi
    dir="$(_center_session_dir)"
    if [[ -f "$dir/$name.json" ]]; then
        _center_confirm "Overwrite snapshot '$name'?" "The previous saved layout will be replaced" || return 0
    fi
    _center_run session save "$name"
}

_center_sessions() {
    local choice name
    choice="$(_center_menu "Sessions" \
        "NAMED SNAPSHOTS\nApplications, workspaces and window geometry" \
        "Save current         Capture every mapped window and workspace" \
        "Restore              Reopen a named workstation layout" \
        "Delete               Remove one named snapshot" \
        "Quick slots          1–9 save · Shift+1–9 restore" \
        "Back                 Return to the command center")" || return 0
    case "$choice" in
        0) _center_save_session ;;
        1)
            name="$(_center_session_pick "RESTORE" || true)"
            [[ -n "$name" ]] && _center_run session restore "$name"
            ;;
        2)
            name="$(_center_session_pick "DELETE" || true)"
            [[ -n "$name" ]] || return 0
            _center_confirm "Delete snapshot '$name'?" "This cannot be undone" || return 0
            _center_run session clear "$name"
            ;;
        3) _center_run session mode ;;
        4) _center_root ;;
    esac
}

_center_copy_report() {
    need wl-copy wl-clipboard || return 1
    local report
    report="$(_center_capture doctor --report || true)"
    printf '%s\n' "$report" | wl-copy
    notify success "System report copied" "Ready to paste into an issue"
}

_center_system() {
    local choice
    choice="$(_center_menu "System" \
        "WORKSTATION HEALTH\nRead-only checks never change the machine" \
        "Health report        Configs, packages, personal layer and session" \
        "Copy issue report    Put a colour-free diagnostic report on the clipboard" \
        "Check drift          Read-only reconciliation preview" \
        "Update workstation   Pull ff-only and reconcile this machine" \
        "Back                 Return to the command center")" || return 0
    case "$choice" in
        0) _center_report "System / health" doctor --report ;;
        1) _center_copy_report ;;
        2) _center_report "System / drift" update --check ;;
        3)
            _center_confirm "Update this workstation?" "Pull and reconcile packages, configs and theme" || return 0
            _center_terminal "hyprwe · update" update
            ;;
        4) _center_root ;;
    esac
}

_center_vm() {
    local choice distro="${HWE_VM_DISTRO:-arch}"
    choice="$(_center_menu "Virtual machines" \
        "DISPOSABLE REHEARSAL\nTarget: $distro · long tasks open in a terminal" \
        "VM status            State and guest IP" \
        "Create from commit   Provision the current branch" \
        "Rehearse changes     Provision the uncommitted working tree" \
        "Open SSH             Shell inside the running guest" \
        "Rebuild changes      Replace the target VM with this working tree" \
        "Destroy VM           Delete the target VM and its disks" \
        "Back                 Return to the command center")" || return 0
    case "$choice" in
        0) _center_report "VM / status" vm status ;;
        1) _center_terminal "hyprwe · VM from commit" vm up ;;
        2) _center_terminal "hyprwe · VM rehearsal" vm up --uncommitted ;;
        3) _center_terminal "hyprwe · VM SSH" vm ssh ;;
        4)
            _center_confirm "Rebuild the $distro VM?" "Its current disks will be replaced" || return 0
            HWE_ASSUME_YES=1 _center_terminal "hyprwe · rebuild VM" vm rebuild --uncommitted
            ;;
        5)
            _center_confirm "Destroy the $distro VM?" "The VM and its disks will be deleted" || return 0
            HWE_ASSUME_YES=1 _center_terminal "hyprwe · destroy VM" vm destroy
            ;;
        6) _center_root ;;
    esac
}

_center_tools() {
    local choice
    choice="$(_center_menu "Utilities" \
        "DESKTOP TOOLS\nThe same actions as the regular keybindings" \
        "Application launcher  Search installed applications" \
        "Clipboard history     Pick a recent clipboard entry" \
        "Screenshot            Capture a region to the clipboard" \
        "Record screen         Toggle whole-screen recording" \
        "Night light           Toggle hyprsunset" \
        "Keybindings           Show live shortcuts, including personal ones" \
        "Power                 Lock, logout, suspend, reboot or shutdown" \
        "Back                  Return to the command center")" || return 0
    case "$choice" in
        0) rofi -show drun ;;
        1) _center_run clip show ;;
        2) _center_run screenshot region ;;
        3) _center_run record toggle ;;
        4) _center_run sunset toggle ;;
        5) _center_run keys ;;
        6) _center_run power ;;
        7) _center_root ;;
    esac
}
