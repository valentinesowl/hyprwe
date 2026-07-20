#!/usr/bin/env bash
# lib/theme.sh — `hwe theme`: generate every component's colours from ONE source
# of truth (themes/<name>/theme.toml) via templates.
#
# Sourced by bin/hwe; relies on lib/common.sh helpers.

# Theme roots (HWE_THEMES / HWE_THEMES_USER), HWE_THEME_CURRENT and the
# _theme_dir resolver come from lib/common.sh — lib/wall.sh needs them too.
: "${HWE_TEMPLATES:=$HWE_ROOT/templates}"
HWE_THEME_OUT="$HWE_ROOT/config"           # rendered into the (symlinked) config tree
HWE_THEME_RENDER="$HWE_ROOT/scripts/render-theme.py"
HWE_SDDM_THEME_DIR="/usr/share/sddm/themes/hwe"   # system greeter install path
HWE_SDDM_CONF="/etc/sddm.conf.d/10-hwe.conf"      # points SDDM at our theme

# wall helpers (_wall_default/_wall_activate) — theme apply sets the wallpaper too
# shellcheck source=lib/wall.sh
source "$HWE_ROOT/lib/wall.sh"

theme_usage() {
    cat >&2 <<EOF
${C_BOLD}hwe theme${C_RESET} — generate component colours from a theme's parameters

${C_BOLD}Usage:${C_RESET} hwe theme <action> [name]

${C_BOLD}Actions:${C_RESET}
  ${C_CYAN}list${C_RESET}              List available themes (current marked with *)
  ${C_CYAN}apply${C_RESET} [name]      Render + deploy a theme, then reload running apps
                    (no name re-applies the current theme — used by ${C_BOLD}hwe update${C_RESET})
  ${C_CYAN}pick${C_RESET}              Pick a theme interactively via rofi (SUPER+SHIFT+T)
  ${C_CYAN}validate${C_RESET} <name>   Check a theme against the role contract (fail-loud)
  ${C_CYAN}current${C_RESET}           Print the currently applied theme
  ${C_CYAN}sddm${C_RESET}              Sync the SDDM login greeter to the current theme (needs root)
EOF
}

theme_main() {
    local action="${1:-}"; shift || true
    case "$action" in
        list|ls)        theme_list ;;
        apply|set)      theme_apply "${1:-}" ;;
        pick)           theme_pick ;;
        validate|check) theme_validate "${1:-}" ;;
        sddm|greeter)   theme_sddm_sync ;;
        current)        cat "$HWE_THEME_CURRENT" 2>/dev/null || echo "(none)" ;;
        ""|help|-h|--help) theme_usage ;;
        *) err "unknown theme action: $action"; theme_usage; return 1 ;;
    esac
}

# Plain list of theme names (one per line), for scripting / rofi. Both roots,
# deduplicated: a name present in both appears once — `_theme_dir` decides which
# one it resolves to.
theme_names() {
    local root d name
    while IFS= read -r root; do
        for d in "$root"/*/; do
            [[ -f "$d/theme.toml" ]] || continue
            # A directory we could never resolve by name is not a theme — listing
            # it would only hand callers a name that _theme_dir then refuses.
            name="$(basename "$d")"
            _theme_name_ok "$name" && printf '%s\n' "$name"
        done
    done < <(_theme_roots) | sort -u
    # Explicit: without it the exit status is that of the LAST `[[ -f ]]` test, so
    # a non-theme directory sorting last (themes/README.md's neighbours, a stray
    # scratch dir) makes a successful listing report failure — and bin/hwe runs
    # under `set -e`. Callers today read us via `< <(theme_names)`, which hides it.
    return 0
}

theme_list() {
    local cur name dir mark origin
    cur="$(cat "$HWE_THEME_CURRENT" 2>/dev/null || true)"
    log "Available themes:"
    while IFS= read -r name; do
        dir="$(_theme_dir "$name")" || continue
        # Say where a theme comes from, so a shadowed shipped theme is visible
        # rather than mysterious.
        origin=""
        [[ "$dir" == "$HWE_THEMES_USER"/* ]] && origin=" ${C_DIM}(yours)${C_RESET}"
        mark=""
        [[ "$name" == "$cur" ]] && mark=" *"
        if [[ -n "$mark" ]]; then
            printf '  %s%s *%s%s\n' "$C_GREEN" "$name" "$C_RESET" "$origin" >&2
        else
            printf '  %s%s\n' "$name" "$origin" >&2
        fi
    done < <(theme_names)
    info "yours: ${C_DIM}$HWE_THEMES_USER${C_RESET}"
}

# Interactive rofi theme selector (bound to SUPER+SHIFT+T). Each entry carries
# the theme's preview.png as its rofi icon (dmenu \0icon\x1f protocol) so you
# pick by look. NULs stay inside the pipe; only the chosen name comes back.
theme_pick() {
    # toggle: a second press closes the picker (matches wall/power menus)
    if pgrep -x rofi >/dev/null 2>&1; then pkill -x rofi; return 0; fi
    need rofi rofi-wayland || return 1
    local cur name choice icon rasi sel=-1 i=0
    cur="$(cat "$HWE_THEME_CURRENT" 2>/dev/null || echo none)"
    rasi="$HWE_ROOT/config/rofi/theme.rasi"    # generated gallery (hwe theme apply)
    # No -mesg: theme.rasi has no "message" child, so rofi dropped it silently — and
    # the current theme is already announced by -selected-row pre-highlighting its tile.
    local args=(-dmenu -i -p "Theme" -show-icons)
    [[ -f "$rasi" ]] && args+=(-theme "$rasi")
    # Pre-highlight the current theme's tile.
    while IFS= read -r name; do
        [[ "$name" == "$cur" ]] && sel=$i
        i=$((i + 1))
    done < <(theme_names)
    [[ $sel -ge 0 ]] && args+=(-selected-row "$sel")
    choice="$(
        while IFS= read -r name; do
            icon="$(_theme_dir "$name" 2>/dev/null)/preview.png"
            if [[ -f "$icon" ]]; then
                printf '%s\0icon\x1f%s\n' "$name" "$icon"
            else
                printf '%s\n' "$name"
            fi
        done < <(theme_names) | rofi "${args[@]}"
    )" || return 0
    [[ -n "$choice" ]] && theme_apply "$choice"
}

_theme_toml() {
    local name="${1:-}"
    [[ -n "$name" ]] || { err "no theme name given (hwe theme list)"; return 1; }
    _theme_name_ok "$name" || {
        err "invalid theme name: '$name' (a theme is a directory: letters, digits, . _ -)"
        return 1
    }
    local dir
    dir="$(_theme_dir "$name")" || {
        err "theme '$name' not found in $HWE_THEMES_USER or $HWE_THEMES"
        return 1
    }
    printf '%s\n' "$dir/theme.toml"
}

theme_validate() {
    local t; t="$(_theme_toml "${1:-}")" || return 1
    need python3 || return 1
    python3 "$HWE_THEME_RENDER" "$t" "$HWE_TEMPLATES" "${TMPDIR:-/tmp}" --check
}

# Config dirs the theme system renders into. `theme apply` symlinks each into
# ~/.config so generated colours go live — scoped to exactly what we theme.
_theme_config_dirs=(hypr kitty waybar rofi mako gtk-3.0 gtk-4.0 qt6ct)

_theme_deploy_links() {
    local cfg="$HWE_ROOT/config" name src dst
    mkdir -p "$HOME/.config"
    for name in "${_theme_config_dirs[@]}"; do
        src="$cfg/$name"; [[ -d "$src" ]] || continue
        dst="$HOME/.config/$name"
        # already ours → nothing to do (keeps repeat applies silent)
        [[ -L "$dst" && "$(readlink -f "$dst")" == "$(readlink -f "$src")" ]] && continue
        if [[ -L "$dst" ]]; then
            rm -f "$dst"                                   # foreign/stale symlink
        elif [[ -e "$dst" ]]; then
            mv "$dst" "$dst.hwe-bak.$$"                    # real dir → back up
            warn "backed up ~/.config/$name -> $(basename "$dst").hwe-bak.$$"
        fi
        ln -sfn "$src" "$dst"
        info "linked ~/.config/$name"
    done
    # top-level generated files (starship.toml, kdeglobals) live directly in
    # ~/.config. kdeglobals may pre-exist as KDE's own file — back it up first.
    local f
    for f in "$cfg"/*.toml "$cfg"/kdeglobals; do
        [[ -f "$f" ]] || continue
        dst="$HOME/.config/$(basename "$f")"
        [[ -L "$dst" && "$(readlink -f "$dst")" == "$(readlink -f "$f")" ]] && continue
        [[ -e "$dst" && ! -L "$dst" ]] && { mv "$dst" "$dst.hwe-bak.$$"; warn "backed up ~/.config/$(basename "$f")"; }
        ln -sfn "$f" "$dst"
        info "linked ~/.config/$(basename "$f")"
    done

    # KDE colour scheme lives under XDG_DATA (not ~/.config) so kdeglobals'
    # ColorScheme=HWE resolves (else KColorScheme half-falls back to light Breeze).
    local sch="$cfg/color-schemes/HWE.colors"
    if [[ -f "$sch" ]]; then
        local schdir="${XDG_DATA_HOME:-$HOME/.local/share}/color-schemes"
        mkdir -p "$schdir"
        [[ -L "$schdir/HWE.colors" && "$(readlink -f "$schdir/HWE.colors")" == "$(readlink -f "$sch")" ]] \
            || { ln -sfn "$sch" "$schdir/HWE.colors"; info "linked color-schemes/HWE.colors"; }
    fi
}

# Kvantum reliably themes Qt/KDE apps (esp. Dolphin): one engine paints every
# widget from a single palette (Fusion+KColorScheme left Dolphin labels black).
# We borrow the installed base theme's SVG/geometry (not vendored) + our palette.
HWE_KVANTUM_BASE="${HWE_KVANTUM_BASE:-/usr/share/Kvantum/KvArcDark}"

_theme_kvantum() {
    command -v kvantummanager >/dev/null 2>&1 || return 0     # kvantum not installed
    local base="$HWE_KVANTUM_BASE" bn
    bn="$(basename "$base")"
    [[ -f "$base/$bn.svg" && -f "$base/$bn.kvconfig" ]] || { warn "Kvantum base '$bn' not found — skipping Qt theming"; return 0; }
    local gc="$HWE_THEME_OUT/kvantum/generalcolors.ini"        # generated from [sem]
    [[ -f "$gc" ]] || { warn "generated $gc missing — run theme apply"; return 0; }

    local dst="$HOME/.config/Kvantum/HWE"
    mkdir -p "$dst"
    cp -f "$base/$bn.svg" "$dst/HWE.svg"                       # widget graphics (borrowed)
    # HWE.kvconfig = base config with [GeneralColors] swapped for ours. Keeping the
    # base [%General]/[Hacks] keeps kvconfig<->svg a matched pair; only palette changes.
    python3 - "$base/$bn.kvconfig" "$gc" "$dst/HWE.kvconfig" <<'PY'
import sys
base, gc, out = sys.argv[1:4]
res, skip = [], False
for ln in open(base, encoding="utf-8", errors="replace").read().splitlines():
    s = ln.strip()
    if s.startswith("[") and s.endswith("]"):
        skip = s.lower() == "[generalcolors]"
    if not skip:
        res.append(ln)
colors = open(gc, encoding="utf-8").read().rstrip("\n")
open(out, "w", encoding="utf-8").write("\n".join(res).rstrip("\n") + "\n\n" + colors + "\n")
PY
    # Point Kvantum at our theme (style=kvantum set in qt6ct.conf). Back up a pre-
    # existing non-HWE kvantum.kvconfig once (courtesy); the theme=HWE guard then holds.
    local kv="$HOME/.config/Kvantum/kvantum.kvconfig"
    if [[ -f "$kv" ]] && ! grep -q '^theme=HWE$' "$kv"; then
        cp -f "$kv" "$kv.hwe-bak.$$"
        warn "backed up existing kvantum.kvconfig -> $(basename "$kv").hwe-bak.$$"
    fi
    printf '[General]\ntheme=HWE\n' > "$kv"
    info "Kvantum theme HWE generated (restart Qt apps to apply)"
}

# Optional user Waybar overrides. Bar COMPOSITION (which modules, their order, a
# module's on-click) is a user choice, not a theme's, so it lives OUTSIDE the
# theme: ~/.config/hwe/waybar.jsonc is deep-merged over the freshly generated
# config.jsonc on every apply (wbmerge.py). The user edits one small untracked
# file; theme switches and `git pull` never clobber it. Best-effort: a broken
# override warns and is ignored — it must never break the apply.
_theme_waybar_overrides() {
    local ov="$HWE_USER_CONFIG/waybar.jsonc"
    local gen="$HWE_THEME_OUT/waybar/config.jsonc"
    [[ -f "$ov" && -f "$gen" ]] || return 0
    local merged
    if merged="$(python3 "$HWE_ROOT/scripts/wbmerge.py" "$gen" "$ov" 2>/dev/null)"; then
        printf '%s\n' "$merged" > "$gen"
        info "applied Waybar overrides from $ov"
    else
        warn "$ov is not valid JSON — ignoring it"
    fi
}

theme_apply() {
    local name="${1:-}"
    [[ -z "$name" ]] && name="$(cat "$HWE_THEME_CURRENT" 2>/dev/null || true)"
    local t; t="$(_theme_toml "$name")" || { theme_list; return 1; }
    need python3 python-jinja || return 1

    log "Applying theme '$name'"
    python3 "$HWE_THEME_RENDER" "$t" "$HWE_TEMPLATES" "$HWE_THEME_OUT" || return 1
    printf '%s\n' "$name" > "$HWE_THEME_CURRENT"
    # Layer the user's Waybar composition over the generated config, if any.
    _theme_waybar_overrides || true
    # Symlink every rendered config dir into ~/.config (else colours aren't live).
    # Self-heals newly-added themed dirs on older boxes. Idempotent.
    _theme_deploy_links
    # Assemble the Kvantum theme (Qt/KDE apps incl. Dolphin). Best-effort.
    _theme_kvantum || true
    # Point the wallpaper at this theme's choice. Best-effort: like the reload it
    # must never fail apply.
    _wall_activate "$(_wall_default "$name")" || true
    # Sync the SDDM greeter to the theme, but only if free (passwordless sudo) —
    # theme apply must stay non-interactive. Best-effort, never fails the apply.
    _sddm_refresh_if_free "$name" || true
    # Live-reload is cosmetic — it must NEVER fail the apply (and thus the whole
    # install, which runs under `set -euo pipefail`). Best-effort only.
    _theme_reload || true
    ok "theme '$name' applied"
}

# Live-reload running apps so regenerated colours take effect. Locates the
# Hyprland instance itself so it works from any context (keybind/ssh/terminal).
_theme_reload() {
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    local sig="${HYPRLAND_INSTANCE_SIGNATURE:-}"
    # No session env (e.g. install time)? Find the instance ourselves. Guard the dir
    # + `|| true`: under set -euo pipefail a failing `ls|head` would abort mid-reload.
    if [[ -z "$sig" && -d "$XDG_RUNTIME_DIR/hypr" ]]; then
        # shellcheck disable=SC2012  # entries are Hyprland instance signatures
        # (hex), never arbitrary filenames — `find` buys nothing but noise here.
        sig="$(ls "$XDG_RUNTIME_DIR/hypr" 2>/dev/null | head -n1)" || true
    fi

    if [[ -n "$sig" ]] && command -v hyprctl >/dev/null 2>&1; then
        export HYPRLAND_INSTANCE_SIGNATURE="$sig"
        hyprctl reload >/dev/null 2>&1 && info "hyprland reloaded"
        # @import'd colours don't reload via SIGUSR2 — full restart.
        # Wait for the old bar to die so we never spawn two.
        pkill -x waybar 2>/dev/null
        local i
        for i in 1 2 3 4 5 6 7 8 9 10; do
            pgrep -x waybar >/dev/null 2>&1 || break
            sleep 0.2
        done
        pkill -9 -x waybar 2>/dev/null   # anything still lingering: force the field clear
        hyprctl dispatch exec waybar >/dev/null 2>&1 && info "waybar (re)started"
    else
        # No compositor reachable (e.g. install time): best-effort signal only.
        pgrep -x waybar >/dev/null 2>&1 && { pkill -SIGUSR2 waybar 2>/dev/null; info "waybar reloaded"; }
    fi

    command -v makoctl >/dev/null 2>&1 && makoctl reload >/dev/null 2>&1 && info "mako reloaded"
    pgrep -x kitty >/dev/null 2>&1 && { pkill -SIGUSR1 kitty 2>/dev/null; info "kitty reloaded"; }
    # Nudge GTK4/libadwaita into the theme's light/dark preference so unoverridden
    # defaults match. The generated gtk-4.0/settings.ini carries the resolved scheme
    # (prefer-dark-theme=0 → light); read it back rather than re-parse the TOML.
    # Needs a dbus session + gsettings schemas; best-effort, never fails the reload.
    if command -v gsettings >/dev/null 2>&1; then
        local pref=prefer-dark
        grep -qs '^gtk-application-prefer-dark-theme=0' "$HWE_THEME_OUT/gtk-4.0/settings.ini" && pref=prefer-light
        gsettings set org.gnome.desktop.interface color-scheme "$pref" >/dev/null 2>&1 || true
    fi
    # Refresh KDE's cache so a new colour scheme is seen (apps still need a restart).
    command -v kbuildsycoca6 >/dev/null 2>&1 && kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
    return 0
}

# Install/refresh the HWE SDDM greeter and point SDDM at it. SEPARATE from
# `theme apply` because the greeter lives in system paths and needs root — we
# never bury a sudo prompt in the frequent, unprivileged apply. Run by hand:
#   hwe theme sddm
theme_sddm_sync() {
    command -v sddm >/dev/null 2>&1 || { warn "sddm not installed — no greeter to theme"; return 0; }
    local src="$HWE_ROOT/provision/sddm/hwe"
    [[ -f "$src/Main.qml" ]] || { err "missing greeter source at $src"; return 1; }

    # Ensure the palette conf exists — render the current theme if it doesn't yet.
    local gen="$HWE_THEME_OUT/sddm/theme.conf"
    if [[ ! -f "$gen" ]]; then
        theme_apply "$(cat "$HWE_THEME_CURRENT" 2>/dev/null || echo mocha)" >/dev/null || true
    fi
    [[ -f "$gen" ]] || { err "no generated $gen — run 'hwe theme apply <name>' first"; return 1; }

    log "Installing HWE SDDM greeter -> $HWE_SDDM_THEME_DIR"
    run sudo install -d "$HWE_SDDM_THEME_DIR" || return 1
    run sudo install -m644 "$src/Main.qml"          "$HWE_SDDM_THEME_DIR/Main.qml"
    run sudo install -m644 "$src/metadata.desktop"  "$HWE_SDDM_THEME_DIR/metadata.desktop"
    run sudo install -m644 "$gen"                   "$HWE_SDDM_THEME_DIR/theme.conf"

    # Background = the active wallpaper (resolve the current.wall symlink) copied
    # in next to Main.qml, since the sddm user can't read the user's $HOME.
    local wall; wall="$(readlink -f "$HWE_ROOT/config/hypr/assets/current.wall" 2>/dev/null || true)"
    if [[ -f "$wall" ]]; then
        run sudo install -m644 "$wall" "$HWE_SDDM_THEME_DIR/background.png"
    else
        warn "no active wallpaper found — greeter will use its solid background colour"
    fi

    # Point SDDM at our theme.
    run sudo install -d /etc/sddm.conf.d
    printf '[Theme]\nCurrent=hwe\n' | run sudo tee "$HWE_SDDM_CONF" >/dev/null

    # KNOWN LIMITATION, deliberate: another desktop framework's leftover config
    # can still outrank ours. SDDM reads EVERY file in /etc/sddm.conf.d (not just
    # *.conf) and the last one alphabetically wins, so a leftover that sorts after
    # "10-hwe.conf" takes the greeter. We do NOT go looking for other projects'
    # files to move aside: policing another project's uninstall is its job, not
    # ours, and a tool that quietly relocates files it does not own is worse than
    # the symptom. If the greeter still looks foreign after `hwe theme sddm`, list
    # /etc/sddm.conf.d and remove what that framework's own uninstaller left.
    # (Migration from other environments is a topic of its own — see README.)

    ok "SDDM greeter set to 'hwe' — takes effect at the next login screen"
}

# Refresh the installed greeter's wallpaper+colours to match the theme WITHOUT
# prompting: only when the greeter is installed and we already hold passwordless
# sudo. Otherwise (root-owned /usr/share) just hint how to sync deliberately.
_sddm_refresh_if_free() {
    [[ -d "$HWE_SDDM_THEME_DIR" ]] || return 0     # greeter not installed → nothing to do
    local gen="$HWE_THEME_OUT/sddm/theme.conf"
    local wall; wall="$(readlink -f "$HWE_ROOT/config/hypr/assets/current.wall" 2>/dev/null || true)"
    if sudo -n true 2>/dev/null; then
        [[ -f "$wall" ]] && sudo -n install -m644 "$wall" "$HWE_SDDM_THEME_DIR/background.png" 2>/dev/null
        [[ -f "$gen"  ]] && sudo -n install -m644 "$gen"  "$HWE_SDDM_THEME_DIR/theme.conf"     2>/dev/null
        info "login greeter updated to match '$1'"
    else
        info "login screen still shows the old theme — run ${C_BOLD}hwe theme sddm${C_RESET} to update it"
    fi
}
