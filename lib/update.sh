#!/usr/bin/env bash
# lib/update.sh — `hwe update`: reconcile this machine with the repo.
#
# The counterpart to `hwe doctor host`: doctor DETECTS drift, update FIXES it.
#   1. git pull --ff-only   (safe: aborts on a dirty tree or a non-ff history —
#                            you drive real merges/rebases, update never guesses)
#      — if the pull moved HEAD, re-exec the pulled bin/hwe once, so the steps
#        below always run the code of the commit they are laying down
#   2. re-link configs      (_deploy_configs — idempotent, repairs the symlinks)
#   3. re-link the CLI      (_link_cli — so `doctor`'s advertised fix is real)
#   4. re-apply the theme    (regenerate every component + live-reload)
#   5. install missing pkgs  (core + dev + your own list, AUR best-effort;
#                             confirm before it acts)
#   6. fetch newly-pinned fonts (idempotent: skips what a package already provides)
#
# Nothing here touches your personal layer (~/.config/hwe) — which is exactly why
# step 1 can afford to be strict about a dirty tree: your settings are not in the
# tree. Step 2 only recreates a file of the layer that is missing entirely.
#
# `hwe update --check` runs the read-only drift report (== hwe doctor host) and
# changes nothing. You run this yourself, so the live reload in step 3 is your
# own action — see the drive-live-envs discipline.
#
# Sourced by bin/hwe. Reuses install primitives from guest-install.sh.
# shellcheck source=provision/guest-install.sh
HWE_INSTALL_STANDALONE=1 source "$HWE_ROOT/provision/guest-install.sh"

update_main() {
    local check=0
    case "${1:-}" in
        --check|-n) check=1 ;;
        help|-h|--help)
            cat >&2 <<EOF
${C_BOLD}hwe update${C_RESET} — pull the repo and reconcile this machine

${C_BOLD}Usage:${C_RESET} hwe update [--check]

  (no args)   ff-only pull, re-link configs + CLI, re-apply theme, install missing pkgs + fonts
  ${C_CYAN}--check${C_RESET}     read-only drift report only (same as ${C_BOLD}hwe doctor host${C_RESET})
EOF
            return 0 ;;
        "") ;;
        *)  err "unknown update flag: $1"; update_main help; return 1 ;;
    esac

    if [[ $check -eq 1 ]]; then
        # shellcheck source=lib/doctor.sh
        source "$HWE_ROOT/lib/doctor.sh"
        doctor_host
        return
    fi

    need git git || return 1
    [[ $EUID -eq 0 ]] && die "run 'hwe update' as a normal user (it uses sudo where needed)"

    local head_before head_after
    head_before="$(git -C "$HWE_ROOT" rev-parse HEAD 2>/dev/null || true)"
    _update_pull || return 1
    head_after="$(git -C "$HWE_ROOT" rev-parse HEAD 2>/dev/null || true)"

    # Everything sourced above — the deploy contract in guest-install.sh,
    # common.sh, this very file — is still the PRE-pull code: bash keeps the
    # definitions it loaded, not the files the pull just rewrote. Reconciling
    # with them would lay down yesterday's contract over today's tree, and void
    # the user-layer guarantee the comment below promises in exactly the release
    # that adds a skeleton file. So when the pull moved HEAD, hand the rest of
    # the run to the freshly pulled CLI and let the new commit reconcile itself.
    # The guard stops a loop if upstream advances again between the two pulls;
    # that rare race reconciles one commit behind and heals on the next update.
    if [[ "$head_after" != "$head_before" && -z "${HWE_UPDATE_REEXECED:-}" ]]; then
        log "Repo advanced — restarting with the updated code"
        HWE_UPDATE_REEXECED=1 exec "$HWE_ROOT/bin/hwe" update
    fi

    log "Reconciling this machine with the repo"
    # FIRST, before anything else: the pull may have just brought in a
    # hyprland.conf that sources a personal file this machine does not have yet,
    # and Hyprland treats a missing source as a config error the moment it
    # reloads. Copy-once, so anything already there is yours and is left alone.
    _deploy_user_layer
    _deploy_configs
    _link_cli
    _update_apply_theme
    _update_packages
    _install_fetched_fonts

    echo
    ok "hwe update complete."
}

# Fast-forward only. Refuse to touch a repo with uncommitted TRACKED changes
# (gitignored generated files don't count) or one that can't fast-forward — those
# are yours to resolve, and a silent merge/stash here would be exactly the kind of
# surprise state change to avoid.
_update_pull() {
    git -C "$HWE_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || { err "$HWE_ROOT is not a git checkout — nothing to pull"; return 1; }

    if ! git -C "$HWE_ROOT" diff --quiet || ! git -C "$HWE_ROOT" diff --cached --quiet; then
        err "uncommitted changes in $HWE_ROOT — commit or stash them first"
        info "update only fast-forwards; it won't touch your work in progress"
        return 1
    fi

    local branch upstream
    branch="$(git -C "$HWE_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    [[ -n "$branch" ]] || { err "HEAD is detached — check out a branch first"; return 1; }
    upstream="$(git -C "$HWE_ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
    if [[ -z "$upstream" ]]; then
        # A clone sets tracking on its own, so this is mostly a checkout that was
        # created locally and pushed without -u. Name the fix when the matching
        # remote branch is actually there; guessing one that isn't would send the
        # user to a command that fails.
        err "branch '$branch' has no upstream to pull from"
        local remote
        remote="$(git -C "$HWE_ROOT" remote | head -n1)"
        if [[ -n "$remote" ]] && \
           git -C "$HWE_ROOT" show-ref --verify --quiet "refs/remotes/$remote/$branch"; then
            info "set it once: ${C_BOLD}git -C $HWE_ROOT branch --set-upstream-to=$remote/$branch $branch${C_RESET}"
        elif [[ -n "$remote" ]]; then
            info "'$remote' has no branch '$branch' — push it first, or switch to a tracked branch"
        else
            info "this checkout has no remote at all — add one, or update it by hand"
        fi
        return 1
    fi

    log "Pulling $branch (fast-forward only) from $upstream"
    if ! run git -C "$HWE_ROOT" pull --ff-only; then
        err "cannot fast-forward — $branch has diverged from $upstream"
        info "reconcile it yourself (git rebase / git merge), then re-run hwe update"
        return 1
    fi
}

# Re-apply the currently-selected theme (regenerate every component and live
# reload). No-op-safe if nothing is selected yet.
_update_apply_theme() {
    local cur; cur="$(_theme_current)"
    [[ -n "$cur" ]] || { info "no theme selected yet — skipping theme apply"; return 0; }
    log "Re-applying theme '$cur'"
    # shellcheck source=lib/theme.sh
    source "$HWE_ROOT/lib/theme.sh"
    theme_apply "$cur"
}

# Install packages the lists name but the system lacks (core + dev; AUR only if a
# helper is present). Report-only for what's already there; confirm before acting.
_update_packages() {
    _distro_supported 2>/dev/null || { info "unknown distribution — skipping package sync"; return 0; }
    local want=() missing=()
    mapfile -t want < <({ _pkgs_from core.lst; _pkgs_from dev.lst; } | _pm_translate
                        _pkgs_user packages.lst)
    if [[ ${#want[@]} -gt 0 ]]; then
        mapfile -t missing < <(_pm_missing "${want[@]}")
    fi

    if [[ ${#missing[@]} -eq 0 ]]; then
        ok "packages already in sync"
    else
        warn "${#missing[@]} package(s) from the lists are not installed:"
        info "${missing[*]}"
        if confirm "Install the missing packages now?"; then
            _pm_install "${missing[@]}"
        else
            info "skipped — install later with: ${C_BOLD}hwe update${C_RESET}"
        fi
    fi

    # AUR: only if a helper exists and aur.lst names anything not yet installed.
    if command -v paru >/dev/null 2>&1; then
        local aur=() aur_missing=()
        mapfile -t aur < <(_aur_wanted)
        if [[ ${#aur[@]} -gt 0 ]]; then
            mapfile -t aur_missing < <(_pm_missing "${aur[@]}")
            if [[ ${#aur_missing[@]} -gt 0 ]]; then
                warn "${#aur_missing[@]} AUR package(s) missing: ${aur_missing[*]}"
                if confirm "Install missing AUR packages with paru?"; then
                    run paru -S --needed --noconfirm "${aur_missing[@]}"
                fi
            fi
        fi
    fi
}
