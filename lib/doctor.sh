#!/usr/bin/env bash
# lib/doctor.sh — `hwe doctor`: health checks.
#
# Two subjects under one verb:
#   hwe doctor host   drift-check an INSTALLED machine — do the config symlinks,
#                     packages and running compositor still match the repo?
#   hwe doctor vm     prerequisites for the dev-VM workflow (delegates to vm.sh).
# Bare `hwe doctor` == `hwe doctor host` (the common case: "is my box still as
# described"). All checks are READ-ONLY — nothing here mutates the live session,
# so it is safe to run on the host at any time (`hwe update` is the fix action).
#
# Sourced by bin/hwe; relies on lib/common.sh helpers. Package/config primitives
# (_pkgs_from, the deploy layout) come from provision/guest-install.sh so the
# check can never drift from what install actually lays down. Sourcing it only
# defines functions — install_main runs only when the file is executed directly.
# shellcheck source=provision/guest-install.sh
HWE_INSTALL_STANDALONE=1 source "$HWE_ROOT/provision/guest-install.sh"

doctor_main() {
    local sub="${1:-host}"; shift || true
    case "$sub" in
        host)       doctor_host ;;
        vm)
            # shellcheck source=lib/vm.sh
            source "$HWE_ROOT/lib/vm.sh"
            vm_doctor
            ;;
        help|-h|--help)
            cat >&2 <<EOF
${C_BOLD}hwe doctor${C_RESET} — health checks

${C_BOLD}Usage:${C_RESET} hwe doctor [host|vm]

  ${C_CYAN}host${C_RESET}   Drift-check this installed machine (symlinks, packages,
         Hyprland config, shell). Read-only. This is the default.
  ${C_CYAN}vm${C_RESET}     Host prerequisites for the dev VM (libvirt, KVM, network).

Fix drift with ${C_BOLD}hwe update${C_RESET}.
EOF
            ;;
        *)  err "unknown doctor subject: $sub"; doctor_main help; return 1 ;;
    esac
}

# Compare one deployed path against its repo source. Echoes a one-word status:
# ok | missing | dangling | foreign-link | foreign-real.
_doctor_link_status() {
    local dst="$1" src="$2"
    if [[ -L "$dst" ]]; then
        [[ -e "$dst" ]] || { echo dangling; return; }
        if [[ "$(readlink -f "$dst")" == "$(readlink -f "$src")" ]]; then
            echo ok
        else
            echo foreign-link
        fi
    elif [[ -e "$dst" ]]; then
        echo foreign-real
    else
        echo missing
    fi
}

# The set of ~/.config entries `_deploy_configs` links: every config/*/ subdir,
# plus the loose top-level generated files. Mirror that list exactly so a drift
# report matches what install/update actually deploys.
_doctor_config_targets() {
    local src name
    for src in "$HWE_ROOT"/config/*/; do
        [[ -d "$src" ]] || continue
        name="$(basename "$src")"
        _config_is_staging "$name" && continue   # build output, not a ~/.config link
        printf '%s\t%s\n' "$name" "${src%/}"
    done
    for src in "$HWE_ROOT"/config/*.toml "$HWE_ROOT"/config/*.conf "$HWE_ROOT/config/kdeglobals"; do
        [[ -f "$src" ]] && printf '%s\t%s\n' "$(basename "$src")" "$src"
    done
}

doctor_host() {
    log "Checking this installed HWE machine for drift..."
    local fail=0

    # --- CLI symlink ------------------------------------------------------
    if [[ "$(readlink -f /usr/local/bin/hwe 2>/dev/null)" == "$(readlink -f "$HWE_ROOT/bin/hwe")" ]]; then
        ok "hwe CLI linked (/usr/local/bin/hwe -> this repo)"
    else
        warn "/usr/local/bin/hwe does not point at this repo"
        info "fix: ${C_BOLD}hwe update${C_RESET} (or: sudo ln -sf $HWE_ROOT/bin/hwe /usr/local/bin/hwe)"
        fail=1
    fi

    # --- config symlinks --------------------------------------------------
    local name src status drift=0
    while IFS=$'\t' read -r name src; do
        [[ -n "$name" ]] || continue
        status="$(_doctor_link_status "$HOME/.config/$name" "$src")"
        case "$status" in
            ok) ;;
            missing)      warn "not deployed: ~/.config/$name";              drift=1 ;;
            dangling)     warn "dangling symlink: ~/.config/$name";           drift=1 ;;
            foreign-link) warn "points outside this repo: ~/.config/$name";   drift=1 ;;
            foreign-real) warn "a real file, not our link: ~/.config/$name";  drift=1 ;;
        esac
    done < <(_doctor_config_targets)
    if [[ $drift -eq 0 ]]; then
        ok "config symlinks intact"
    else
        info "re-link with: ${C_BOLD}hwe update${C_RESET} (backs up anything foreign)"
        fail=1
    fi

    # --- packages ---------------------------------------------------------
    # core + dev are both relevant on a real workstation (it's a dev box);
    # pacman -T understands versions, provides and virtual packages, so it's the
    # right "is this satisfied" test. AUR is best-effort — only meaningful with a
    # helper, and its packages register locally so pacman -T still sees them.
    if command -v pacman >/dev/null 2>&1; then
        local want=() missing=()
        mapfile -t want < <(_pkgs_from core.lst; _pkgs_from dev.lst; command -v paru >/dev/null 2>&1 && _pkgs_from aur.lst)
        if [[ ${#want[@]} -gt 0 ]]; then
            mapfile -t missing < <(pacman -T "${want[@]}" 2>/dev/null || true)
        fi
        if [[ ${#missing[@]} -eq 0 ]]; then
            ok "all listed packages installed"
        else
            warn "${#missing[@]} listed package(s) missing: ${missing[*]}"
            info "install them with: ${C_BOLD}hwe update${C_RESET}"
            fail=1
        fi
    else
        info "pacman not found — skipping package check"
    fi

    # --- login shell ------------------------------------------------------
    local sh; sh="$(getent passwd "$USER" 2>/dev/null | cut -d: -f7)"
    if [[ "$(basename "${sh:-}")" == zsh ]]; then
        ok "login shell is zsh"
    else
        warn "login shell is ${sh:-unknown}, not zsh"
        info "set it: ${C_BOLD}hwe install${C_RESET} configures the shell (or: chsh -s \$(command -v zsh))"
    fi

    # --- Hyprland config errors ------------------------------------------
    if command -v hyprctl >/dev/null 2>&1 && \
       [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" || -d "${XDG_RUNTIME_DIR:-/run/user/$UID}/hypr" ]]; then
        local errs
        errs="$(hyprctl configerrors 2>/dev/null | sed '/^[[:space:]]*$/d' || true)"
        if [[ -z "$errs" || "$errs" == *"no errors"* ]]; then
            ok "Hyprland config: no errors"
        else
            warn "Hyprland reports config errors:"
            printf '%s\n' "$errs" | sed 's/^/     /' >&2
            fail=1
        fi
    else
        info "no running Hyprland session — skipping config-error check"
    fi

    echo
    if [[ $fail -eq 0 ]]; then
        ok "no drift — this machine matches the repo"
    else
        warn "drift detected — run ${C_BOLD}hwe update${C_RESET} to reconcile"
        return 1
    fi
}
