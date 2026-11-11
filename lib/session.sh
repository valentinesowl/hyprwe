#!/usr/bin/env bash

_session_usage() {
    cat >&2 <<'EOF'
usage: hwe session <save|restore|list|clear> [name]

  save <name>       Save every window and workspace to a named snapshot.
  restore <name>    Restore applications, workspaces and tiled window geometry.
  list              List saved snapshots.
  clear <name>      Delete one snapshot.
  clear --all       Delete every snapshot (asks for confirmation).

Names may contain letters, digits, dots, underscores and dashes.
Snapshots live in ~/.local/state/hwe/sessions/ (or $HWE_SESSION_DIR).
EOF
}

session_main() {
    local action="${1:-}"
    [[ $# -eq 0 ]] || shift
    case "$action" in
        help|-h|--help|"") _session_usage; return 0 ;;
        mode)
            notify info "Session mode" "1–9 save · Shift+1–9 restore · Esc cancel"
            _hyprctl dispatch 'hl.dsp.submap("session")'
            return
            ;;
        save|restore|list|clear) ;;
        *) err "unknown session action: $action"; _session_usage; return 1 ;;
    esac
    need python3 python-jinja || return 1

    case "$action" in
        save|restore)
            [[ $# -eq 1 ]] || { err "hwe session $action requires exactly one name"; _session_usage; return 1; }
            if python3 "$HWE_ROOT/scripts/session.py" "$action" "$1"; then
                if [[ "$action" == save ]]; then
                    notify success "Session saved" "Snapshot '$1'"
                else
                    notify success "Session restored" "Snapshot '$1'"
                fi
            else
                local rc=$?
                notify error "Session $action failed" "Snapshot '$1' · run 'hwe doctor'"
                return "$rc"
            fi
            ;;
        list)
            [[ $# -eq 0 ]] || { err "hwe session list takes no arguments"; _session_usage; return 1; }
            python3 "$HWE_ROOT/scripts/session.py" list
            ;;
        clear)
            [[ $# -eq 1 ]] || { err "hwe session clear requires a name or --all"; _session_usage; return 1; }
            if [[ "$1" == --all ]]; then
                confirm "Delete every saved HWE session?" || { info "cancelled"; return 0; }
            fi
            python3 "$HWE_ROOT/scripts/session.py" clear "$1"
            ;;
    esac
}
