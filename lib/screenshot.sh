#!/usr/bin/env bash
# lib/screenshot.sh — screenshot workflows behind the Print key bindings.
# Every path reports success, cancellation or the failing tool without requiring
# a terminal. Temporary captures keep pipeline statuses unambiguous.

_screenshot_usage() {
    cat >&2 <<'EOF'
usage: hwe screenshot <screen|region|file|annotate>

  screen     Copy the whole screen to the clipboard (Print).
  region     Copy a selected region to the clipboard (Shift+Print).
  file       Save a selected region to ~/Pictures (Super+Print).
  annotate   Annotate a selected region with satty (Super+Shift+Print).
EOF
}

screenshot_main() {
    local action="${1:-screen}"
    case "$action" in
        help|-h|--help) _screenshot_usage; return 0 ;;
        screen|region|file|annotate) ;;
        *) err "unknown screenshot action: $action"; _screenshot_usage; return 1 ;;
    esac
    need grim grim || { notify error "Screenshot failed" "grim is not installed"; return 1; }

    local geometry=""
    if [[ "$action" != screen ]]; then
        need slurp slurp || { notify error "Screenshot failed" "slurp is not installed"; return 1; }
        if ! geometry="$(slurp)" || [[ -z "$geometry" ]]; then
            info "screenshot cancelled"
            notify info "Screenshot cancelled"
            return 0
        fi
    fi

    local tmp rc=0
    tmp="$(mktemp "${TMPDIR:-/tmp}/hwe-screenshot.XXXXXX.png")" || {
        notify error "Screenshot failed" "Could not create a temporary file"
        return 1
    }
    if [[ -n "$geometry" ]]; then
        grim -g "$geometry" "$tmp" || rc=$?
    else
        grim "$tmp" || rc=$?
    fi
    if [[ $rc -ne 0 ]]; then
        rm -f "$tmp"
        err "grim failed to capture the screen"
        notify error "Screenshot failed" "grim could not capture the screen"
        return 1
    fi

    local out
    case "$action" in
        screen|region)
            need wl-copy wl-clipboard || {
                rm -f "$tmp"
                notify error "Screenshot failed" "wl-copy is not installed"
                return 1
            }
            if ! wl-copy < "$tmp"; then
                rm -f "$tmp"
                err "wl-copy failed"
                notify error "Screenshot failed" "Could not copy the image to the clipboard"
                return 1
            fi
            rm -f "$tmp"
            ok "screenshot copied to clipboard"
            notify success "Screenshot copied" "The image is in the clipboard"
            ;;
        file|annotate)
            local pictures="${HWE_SCREENSHOT_DIR:-$HOME/Pictures}"
            if ! mkdir -p "$pictures"; then
                rm -f "$tmp"
                err "could not create $pictures"
                notify error "Screenshot failed" "Could not create $pictures"
                return 1
            fi
            out="$pictures/$(date +%F_%H-%M-%S).png"
            if [[ "$action" == file ]]; then
                if ! mv "$tmp" "$out"; then
                    rm -f "$tmp"
                    err "could not save $out"
                    notify error "Screenshot failed" "Could not save to $out"
                    return 1
                fi
                ok "screenshot saved to $out"
                notify success "Screenshot saved" "${out/#$HOME/\~}"
            else
                need satty satty || {
                    rm -f "$tmp"
                    notify error "Screenshot failed" "satty is not installed"
                    return 1
                }
                satty --filename "$tmp" --copy-command wl-copy --output-filename "$out" || rc=$?
                rm -f "$tmp"
                if [[ $rc -ne 0 ]]; then
                    if [[ $rc -eq 1 && ! -f "$out" ]]; then
                        info "annotation cancelled"
                        notify info "Annotation cancelled"
                        return 0
                    fi
                    err "satty failed"
                    notify error "Annotation failed" "satty exited with status $rc"
                    return 1
                fi
                ok "annotated screenshot saved to $out"
                notify success "Annotated screenshot saved" "${out/#$HOME/\~}"
            fi
            ;;
    esac
}
