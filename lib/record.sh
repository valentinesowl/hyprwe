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
        help | -h | --help)
            printf 'usage: hwe record [toggle|region|status]\n  toggle  start/stop a full-screen capture (-> ~/Videos)\n  region  start a capture of a slurp-selected region\n  status  print recording|idle (for the waybar module)\n' >&2
            return 0
            ;;
        *) err "unknown record action: ${1}"; printf 'usage: hwe record [toggle|region|status]\n' >&2; return 1 ;;
    esac

    # A running capture means "stop", regardless of the requested mode.
    if pgrep -x wf-recorder >/dev/null 2>&1; then
        if ! pkill -INT -x wf-recorder; then
            err "could not stop wf-recorder"
            notify error "Recording failed" "Could not stop wf-recorder"
            return 1
        fi
        ok "recording stopped — saved to ~/Videos"
        notify success "Recording stopped" "Saved to ~/Videos"
        return 0
    fi

    need wf-recorder wf-recorder || {
        notify error "Recording failed" "wf-recorder is not installed"
        return 1
    }
    local dir="$HOME/Videos"
    mkdir -p "$dir"
    local out
    out="$dir/rec_$(date +%F_%H-%M-%S).mp4"

    local -a geo=()
    if [[ "${1:-}" == region ]]; then
        need slurp slurp || {
            notify error "Recording failed" "slurp is not installed"
            return 1
        }
        local g
        if ! g="$(slurp)" || [[ -z "$g" ]]; then
            info "recording cancelled"
            notify info "Recording cancelled"
            return 0
        fi
        geo=(-g "$g")
    fi

    # Detached so the keybind returns immediately; wf-recorder keeps running.
    wf-recorder "${geo[@]}" -f "$out" >/dev/null 2>&1 &
    disown
    notify warning "Recording started" "● REC · ${out/#$HOME/\~}"
}
