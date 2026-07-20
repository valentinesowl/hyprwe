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
# For _hypr_config_clean — the same "is the config clean?" predicate checkconfig
# uses, so a login notification and a doctor line can never disagree.
# shellcheck source=lib/checkconfig.sh
source "$HWE_ROOT/lib/checkconfig.sh"

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
         personal layer, Hyprland config, shell). Read-only. This is the default.
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

# Your own settings in ~/.config/hwe (see HWE_USER_CONFIG in lib/common.sh).
# The layer being EDITED is not drift — it is the point of it, so a customised
# file is reported and not counted against the machine. Only a missing file is a
# finding, and only hypr.conf is a real one: hyprland.conf sources it
# unconditionally, so its absence is a config error at every login. The file
# list comes from the install's own skeleton dir, so the two cannot diverge.
_doctor_user_layer() {
    local name dst missing=() customised=0 rc=0
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        dst="$HWE_USER_CONFIG/$name"
        if [[ ! -e "$dst" ]]; then
            missing+=("$name")
        elif ! cmp -s "$dst" "$HWE_USER_SKEL/$name"; then
            customised=$((customised + 1))
        fi
    done < <(_user_layer_files)

    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "personal layer incomplete: ~/.config/hwe/{${missing[*]}} missing"
        if [[ " ${missing[*]} " == *" hypr.conf "* ]]; then
            info "hyprland.conf sources hypr.conf — until it exists, every login logs a config error"
        fi
        info "recreate the missing file(s): ${C_BOLD}hwe update${C_RESET} (it never overwrites an existing one)"
        rc=1
    elif [[ $customised -gt 0 ]]; then
        ok "personal layer in ~/.config/hwe ($customised file(s) of your own)"
    else
        ok "personal layer in ~/.config/hwe (untouched defaults)"
    fi
    return $rc
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

    # --- the personal layer ----------------------------------------------
    _doctor_user_layer || fail=1

    # --- packages ---------------------------------------------------------
    # core + dev are both relevant on a real workstation (it's a dev box), and
    # your own list is as binding as HWE's — it is what this machine needs.
    # _pm_missing asks the local package manager the "is this satisfied" question
    # in its own terms. HWE's lists are translated first (Arch names are the
    # canonical vocabulary); your own list is not, since it already names local
    # packages. AUR is best-effort — only meaningful with a helper, and its
    # packages register locally so the check still sees them.
    if _distro_supported 2>/dev/null; then
        local want=() missing=()
        mapfile -t want < <({ _pkgs_from core.lst; _pkgs_from dev.lst
                              command -v paru >/dev/null 2>&1 && _aur_wanted; } | _pm_translate
                            _pkgs_user packages.lst)
        if [[ ${#want[@]} -gt 0 ]]; then
            mapfile -t missing < <(_pm_missing "${want[@]}")
        fi
        if [[ ${#missing[@]} -eq 0 ]]; then
            ok "all listed packages installed"
        else
            warn "${#missing[@]} listed package(s) missing: ${missing[*]}"
            info "install them with: ${C_BOLD}hwe update${C_RESET}"
            fail=1
        fi
    else
        info "unknown distribution (${HWE_DISTRO:-?}) — skipping the package check"
    fi

    # --- pinned fonts -----------------------------------------------------
    # The icon font is a package on Arch but a fetched-and-pinned download where
    # nothing packages it (Ubuntu). Reuse _font_installed so detect and fix share
    # one predicate. An unpinned row is not fetchable, so it is not drift update
    # could fix — skip it, don't cry.
    local fid _ fa fmember ff fonts_missing=0
    while IFS=$'\t' read -r fid _ fa fmember ff; do
        [[ -n "${fid:-}" && -n "${fmember:-}" ]] || continue
        _font_installed "$fmember" && continue
        [[ "$ff" == "-" || "$fa" == "-" || -z "$ff" || -z "$fa" ]] && continue
        warn "pinned font not installed: $fmember"
        fonts_missing=1
    done < <(_fonts_lock_rows)
    if [[ $fonts_missing -eq 0 ]]; then
        ok "pinned fonts present"
    else
        info "install them with: ${C_BOLD}hwe update${C_RESET}"
        fail=1
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
        if _hypr_config_clean "$errs"; then
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
