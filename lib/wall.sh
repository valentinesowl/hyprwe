#!/usr/bin/env bash
# lib/wall.sh — `hwe wall`: manage the desktop wallpaper.
#
# awww displays static images and animated GIFs. hyprpaper remains the static-only
# fallback on distributions without awww. current.wall tracks the desktop image;
# current.lock.wall always points to a static image for hyprlock and SDDM. Per-theme
# choices live in ~/.config/hwe/themes/<name>/wallpapers, outside the checkout.
#
# Sourced by bin/hwe and lib/theme.sh; relies on lib/common.sh helpers.

# Theme roots (HWE_THEMES / HWE_THEMES_USER), HWE_THEME_CURRENT and the
# _theme_dir resolver come from lib/common.sh — a theme of your own carries its
# wallpapers exactly like a shipped one.
# The links live at the REPO path (config/hypr is whole-dir symlinked into
# ~/.config), so they resolve both before and after deploy.
HWE_WALL_LINK="$HWE_ROOT/config/hypr/assets/current.wall"
HWE_LOCK_WALL_LINK="$HWE_ROOT/config/hypr/assets/current.lock.wall"
HWE_WALL_THUMBS="$HWE_CACHE/wallpaper-thumbs"
HWE_WALL_LOG="$HWE_CACHE/wallpaper.log"

wall_usage() {
    cat >&2 <<EOF
${C_BOLD}hwe wall${C_RESET} — manage the desktop wallpaper

${C_BOLD}Usage:${C_RESET} hwe wall <action> [arg]

${C_BOLD}Actions:${C_RESET}
  ${C_CYAN}list${C_RESET} [theme]     List wallpapers available for a theme (active marked *)
  ${C_CYAN}set${C_RESET} <path|name>  Set the wallpaper (a file path, or a name from 'list')
  ${C_CYAN}random${C_RESET} [theme]   Set a random wallpaper for the theme
  ${C_CYAN}pick${C_RESET}             Pick a wallpaper interactively via rofi (SUPER+SHIFT+W)
  ${C_CYAN}current${C_RESET}          Print the path of the active wallpaper
  ${C_CYAN}restore${C_RESET}          Start awww/hyprpaper + apply the active wallpaper (autostart)

Drop your own photos/GIFs into ${C_DIM}~/.config/hwe/themes/<name>/wallpapers/${C_RESET}
and they appear here alongside the theme's generated wallpaper.
EOF
}

wall_main() {
    local action="${1:-}"; shift || true
    case "$action" in
        list|ls)   wall_list "${1:-}" ;;
        set)       wall_set "${1:-}" ;;
        random)    wall_random "${1:-}" ;;
        pick)      wall_pick ;;
        current)   wall_current ;;
        restore)   wall_restore ;;
        ""|help|-h|--help) wall_usage ;;
        *) err "unknown wall action: $action"; wall_usage; return 1 ;;
    esac
}

# Resolve the theme name to operate on: explicit arg, else the current theme,
# else mocha (the shipped default).
_wall_theme() {
    local n="${1:-}"
    [[ -z "$n" ]] && n="$(_theme_current)"
    [[ -z "$n" ]] && n="mocha"
    printf '%s\n' "$n"
}

# Candidate wallpaper files for a theme (absolute paths): user-layer images,
# then the theme's local images, then generated static and animated variants.
_wall_candidates() {
    local dir; dir="$(_theme_dir "$1")" || return 0    # unknown theme: no candidates
    local d grad="$dir/wallpaper.png" gif="$dir/wallpaper.gif"
    for d in "$HWE_USER_CONFIG/themes/$1/wallpapers" "$dir/wallpapers"; do
        if [[ -d "$d" ]]; then
            find "$d" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' \
                -o -iname '*.png' -o -iname '*.webp' -o -iname '*.bmp' -o -iname '*.gif' \) | sort
        fi
    done
    [[ -f "$gif" ]] && printf '%s\n' "$gif"
    [[ -f "$grad" ]] && printf '%s\n' "$grad"
}

# Where a theme's wallpaper choice is remembered: the theme's slot in the user
# layer. ~/.config/hwe/themes/<name>/ has room for any future per-theme state,
# and its wallpapers/ subdir mirrors the theme-dir anatomy on purpose — the
# marker sits inside it the way it used to sit beside the photos.
_wall_marker() { printf '%s/themes/%s/wallpapers/.current_wallpaper\n' "$HWE_USER_CONFIG" "$1"; }

# Read the remembered wallpaper path (empty if none). Installs that predate 1.3.2
# kept it in the theme's own directory inside the checkout; the first read
# migrates it — copy, not move, same reasoning as _theme_current's.
_wall_remembered() {
    local name="$1" marker legacy dir
    marker="$(_wall_marker "$name")"
    if [[ ! -f "$marker" ]] && dir="$(_theme_dir "$name")"; then
        legacy="$dir/.current_wallpaper"
        if [[ -f "$legacy" ]]; then
            mkdir -p "$(dirname "$marker")" 2>/dev/null || true
            cp "$legacy" "$marker" 2>/dev/null || true
        fi
    fi
    cat "$marker" 2>/dev/null || true
}

# Prefer a theme's animated default only when its renderer is available.
_wall_default() {
    local dir; dir="$(_theme_dir "$1")" || return 1
    local p; p="$(_wall_remembered "$1")"
    if [[ -n "$p" && -f "$p" ]]; then
        if [[ "${p,,}" != *.gif ]] || command -v awww >/dev/null 2>&1; then
            printf '%s\n' "$p"
            return 0
        fi
    fi
    if command -v awww >/dev/null 2>&1 && [[ -f "$dir/wallpaper.gif" ]]; then
        printf '%s\n' "$dir/wallpaper.gif"
    else
        printf '%s\n' "$dir/wallpaper.png"
    fi
}

# A friendly label for a wallpaper path (the generated one reads as such, in
# either root).
_wall_label() {
    local p="$1"
    case "$p" in
        "$HWE_THEMES"/*/wallpaper.png|"$HWE_THEMES_USER"/*/wallpaper.png) echo "generated" ;;
        "$HWE_THEMES"/*/wallpaper.gif|"$HWE_THEMES_USER"/*/wallpaper.gif) echo "animated" ;;
        *) basename "${p%.*}" ;;
    esac
}

# Remember a theme's wallpaper choice, so `theme apply` comes back to it. Lives
# in the theme's user-layer slot, so it survives the checkout being replaced.
# Best-effort: the wallpaper is already set by the time we get here, and failing
# to write a preference must not report the swap itself as failed.
_wall_remember() {
    local marker; marker="$(_wall_marker "$1")"
    mkdir -p "$(dirname "$marker")" 2>/dev/null || true
    printf '%s\n' "$(readlink -f "$2")" > "$marker" 2>/dev/null || true
}

# Resolve the static image used by access screens. Generated GIFs already have a
# full-resolution PNG beside them; custom GIFs get a cached first-frame poster.
_wall_lock_image() {
    local path="$1" poster
    if [[ "${path,,}" != *.gif ]]; then
        printf '%s\n' "$path"
        return 0
    fi
    if [[ "$path" == */wallpaper.gif && -f "${path%.gif}.png" ]]; then
        printf '%s\n' "${path%.gif}.png"
        return 0
    fi
    need convert imagemagick || return 1
    poster="$HWE_CACHE/wallpaper-posters/$(printf '%s' "$path" | cksum | cut -d' ' -f1).png"
    if [[ ! -f "$poster" || "$path" -nt "$poster" ]]; then
        mkdir -p "$(dirname "$poster")"
        convert "${path}[0]" "$poster" >/dev/null 2>&1 || {
            err "could not make a lock-screen poster from $path"
            return 1
        }
    fi
    printf '%s\n' "$poster"
}

# Point the desktop and lock-screen links at their respective images, then swap live.
_wall_activate() {
    local path="$1" lock
    [[ -f "$path" ]] || { err "wallpaper not found: $path"; return 1; }
    path="$(readlink -f "$path")"
    if [[ "${path,,}" == *.gif ]] && ! command -v awww >/dev/null 2>&1; then
        err "animated wallpapers need awww (install the awww package)"
        return 1
    fi
    lock="$(_wall_lock_image "$path")" || return 1
    mkdir -p "$(dirname "$HWE_WALL_LINK")"
    ln -sfn "$lock" "$HWE_LOCK_WALL_LINK"
    ln -sfn "$path" "$HWE_WALL_LINK"
    _wall_apply "$path"
}

# Start the preferred backend and wait until awww's socket answers. hyprpaper is
# retained for static-only installations where awww is not packaged.
_wall_start() {
    mkdir -p "$(dirname "$HWE_WALL_LOG")" 2>/dev/null || true
    if command -v awww >/dev/null 2>&1; then
        awww query >/dev/null 2>&1 && return 0
        if ! pgrep -x awww-daemon >/dev/null 2>&1; then
            awww-daemon --format xrgb >> "$HWE_WALL_LOG" 2>&1 &
            disown
        fi
        local i
        for i in $(seq 1 25); do
            awww query >/dev/null 2>&1 && return 0
            sleep 0.1
        done
        return 1
    fi
    if ! pgrep -x hyprpaper >/dev/null 2>&1; then
        hyprpaper >> "$HWE_WALL_LOG" 2>&1 &
        disown
    fi
}

# The raw live swap, and it tells the truth. Locates the Hyprland instance
# itself so it works from a keybind/ssh/terminal. No compositor is a legitimate
# no-op at install time; a refused backend apply is an error.
_wall_apply() {
    local path="$1" stamp="" marker=""
    command -v hyprctl >/dev/null 2>&1 || return 0
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    local sig="${HYPRLAND_INSTANCE_SIGNATURE:-}"
    if [[ -z "$sig" && -d "$XDG_RUNTIME_DIR/hypr" ]]; then
        # shellcheck disable=SC2012  # entries are Hyprland instance signatures
        # (hex), never arbitrary filenames — `find` buys nothing but noise here.
        sig="$(ls "$XDG_RUNTIME_DIR/hypr" 2>/dev/null | head -n1)" || true
    fi
    [[ -n "$sig" ]] || return 0
    export HYPRLAND_INSTANCE_SIGNATURE="$sig"
    if command -v awww >/dev/null 2>&1; then
        _wall_start || return 1
        # awww caches decoded GIF frames by path, not by file contents/mtime.
        # Invalidate only a changed GIF; clearing on every apply re-decodes the
        # whole animation and makes theme/wallpaper selection visibly stall.
        if [[ "${path,,}" == *.gif ]]; then
            stamp="$(stat -c '%y:%s' "$path")"
            marker="$HWE_CACHE/wallpaper-gif-stamps/$(printf '%s' "$path" | cksum | cut -d' ' -f1)"
            if [[ "$(cat "$marker" 2>/dev/null || true)" != "$stamp" ]]; then
                mkdir -p "$(dirname "$marker")"
                awww clear-cache >/dev/null 2>&1 || true
            fi
        fi
        if awww img --transition-type none "$path" >/dev/null 2>&1; then
            [[ -z "$marker" ]] || printf '%s\n' "$stamp" > "$marker"
            pkill -x hyprpaper 2>/dev/null || true
            info "wallpaper set (awww)"
            return 0
        fi
        return 1
    fi
    [[ "${path,,}" != *.gif ]] || { err "animated wallpapers need awww"; return 1; }
    _wall_start || return 1
    # hyprpaper 0.8+ loads on demand; older versions require a preload first.
    hyprctl hyprpaper preload "$path" >/dev/null 2>&1 || true
    if hyprctl hyprpaper wallpaper ",$path" >/dev/null 2>&1; then
        info "wallpaper set (hyprpaper)"
        return 0
    fi
    return 1
}

wall_current() {
    if [[ -L "$HWE_WALL_LINK" ]]; then
        readlink -f "$HWE_WALL_LINK"
    else
        echo "(none)"
    fi
}

# Session-autostart entry point (autostart.lua: hwe wall restore).
wall_restore() {
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    local target; target="$(readlink -f "$HWE_WALL_LINK" 2>/dev/null || true)"
    [[ -f "$target" ]] || { warn "no active wallpaper to restore ($HWE_WALL_LINK)"; return 0; }
    if [[ "${target,,}" == *.gif ]] && ! command -v awww >/dev/null 2>&1; then
        local fallback="${target%.gif}.png"
        [[ -f "$fallback" ]] || {
            err "animated wallpapers need awww; no static fallback found for $target"
            return 1
        }
        warn "awww is unavailable — restoring the static wallpaper instead"
        target="$fallback"
        ln -sfn "$target" "$HWE_WALL_LINK"
    fi

    # Retry the apply itself: a stale socket may exist after its daemon has died.
    local i
    for i in $(seq 1 50); do
        if _wall_apply "$target"; then return 0; fi
        sleep 0.2
    done
    warn "wallpaper backend did not take the wallpaper after 10s — its log: $HWE_WALL_LOG"
    return 1
}

wall_list() {
    local theme; theme="$(_wall_theme "${1:-}")"
    local active; active="$(wall_current)"
    log "Wallpapers for '$theme':"
    local any=0 p
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        any=1
        if [[ "$(readlink -f "$p")" == "$active" ]]; then
            printf '  %s%s *%s\n' "$C_GREEN" "$(_wall_label "$p")" "$C_RESET" >&2
        else
            printf '  %s\n' "$(_wall_label "$p")" >&2
        fi
    done < <(_wall_candidates "$theme")
    [[ "$any" == 1 ]] || warn "no wallpapers for '$theme'"
}

# Set the wallpaper. Arg is a file path, or a wallpaper name/basename as shown by
# `wall list` (resolved within the current theme, the generated one included).
wall_set() {
    local arg="${1:-}"
    [[ -n "$arg" ]] || { err "usage: hwe wall set <path|name>"; return 1; }
    local theme; theme="$(_wall_theme)"
    local path=""
    if [[ -f "$arg" ]]; then
        path="$arg"
    else
        # match against this theme's candidates by label or basename; a name
        # two files answer to (sunset.jpg beside sunset.png) is refused with
        # both spelled out, not resolved to whichever sorts first
        local p matches=()
        while IFS= read -r p; do
            [[ -z "$p" ]] && continue
            if [[ "$(_wall_label "$p")" == "$arg" || "$(basename "$p")" == "$arg" \
                  || "$(basename "${p%.*}")" == "$arg" ]]; then
                matches+=("$p")
            fi
        done < <(_wall_candidates "$theme")
        if [[ ${#matches[@]} -gt 1 ]]; then
            err "'$arg' is ambiguous — say which one:"
            printf '  %s\n' "${matches[@]##*/}" >&2
            return 1
        fi
        [[ ${#matches[@]} -eq 1 ]] && path="${matches[0]}"
    fi
    [[ -n "$path" && -f "$path" ]] || {
        err "wallpaper not found: $arg"
        notify error "Wallpaper failed" "Not found: $arg"
        return 1
    }
    _wall_activate "$path" || {
        notify error "Wallpaper failed" "wallpaper backend refused the image · run 'hwe wall restore'"
        return 1
    }
    _wall_remember "$theme" "$path"
    ok "wallpaper: $(_wall_label "$path")"
    notify success "Wallpaper changed" "$(_wall_label "$path") · $theme"
}

wall_random() {
    local theme; theme="$(_wall_theme "${1:-}")"
    local files=() p
    while IFS= read -r p; do [[ -n "$p" ]] && files+=("$p"); done < <(_wall_candidates "$theme")
    [[ ${#files[@]} -gt 0 ]] || {
        err "no wallpapers for '$theme'"
        notify error "Wallpaper failed" "No wallpapers found for '$theme'"
        return 1
    }
    local pick="${files[RANDOM % ${#files[@]}]}"
    _wall_activate "$pick" || {
        notify error "Wallpaper failed" "wallpaper backend refused the image · run 'hwe wall restore'"
        return 1
    }
    _wall_remember "$theme" "$pick"
    ok "wallpaper: $(_wall_label "$pick")"
    notify success "Wallpaper changed" "$(_wall_label "$pick") · $theme"
}

# Interactive rofi picker with thumbnails (bound to SUPER+SHIFT+W).
wall_pick() {
    # toggle: a second press closes it
    if pgrep -x rofi >/dev/null 2>&1; then pkill -x rofi; return 0; fi
    need rofi rofi-wayland || return 1

    local theme; theme="$(_wall_theme)"
    local rasi="$HWE_ROOT/config/rofi/wallpaper.rasi"   # generated by `hwe theme`
    local active; active="$(wall_current)"
    local cache="$HWE_WALL_THUMBS/$theme"
    mkdir -p "$cache"

    local have_convert=0
    command -v convert >/dev/null 2>&1 && have_convert=1

    local files=() labels=() displays=() thumbs=() p label thumb marker input
    # First pass: count labels. `sunset.jpg` and `sunset.png` share the stem
    # "sunset" — two identical rows, and the picker resolves whichever comes
    # first. Where the stem is ambiguous, the row shows the full filename.
    local -A stem_count=()
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        files+=("$p")
        label="$(_wall_label "$p")"
        stem_count["$label"]=$(( ${stem_count["$label"]:-0} + 1 ))
    done < <(_wall_candidates "$theme")

    for p in "${files[@]}"; do
        label="$(_wall_label "$p")"
        [[ "${stem_count[$label]}" -gt 1 ]] && label="$(basename "$p")"
        labels+=("$label")
        # The path checksum keeps same-stem files (and a photo that happens to
        # share the generated wallpaper's name) from sharing one cache slot.
        thumb="$cache/$(basename "${p%.*}").$(printf '%s' "$p" | cksum | cut -d' ' -f1).thumb.png"
        if [[ "$have_convert" == 1 ]]; then
            if [[ ! -f "$thumb" || "$p" -nt "$thumb" ]]; then
                input="$p"
                [[ "${p,,}" != *.gif ]] || input="${p}[0]"   # never decode all frames for a thumbnail
                convert "$input" -resize 400x225^ -gravity center -extent 400x225 \
                    -quality 85 "$thumb" 2>/dev/null || thumb="$p"
            fi
        else
            thumb="$p"   # no imagemagick: let rofi render the full image
        fi
        thumbs+=("$thumb")
        marker=""
        [[ "$(readlink -f "$p")" == "$active" ]] && marker="● "
        displays+=("${marker}${label}")
    done

    [[ ${#files[@]} -gt 0 ]] || { warn "no wallpapers for '$theme'"; return 0; }

    local rofi_args=(-dmenu -i -show-icons -no-custom -p "" -mesg "Wallpaper · $theme")
    [[ -f "$rasi" ]] && rofi_args+=(-theme "$rasi")

    # Feed rofi its icon protocol, one row per line: "<display>\0icon\x1f<thumb>".
    # The \0 MUST be written straight to the pipe — a bash string silently DROPS NUL
    # bytes (C strings), so an `entries` var would lose thumbnails. printf writes it.
    local choice i
    choice="$(
        for i in "${!displays[@]}"; do
            printf '%s\0icon\x1f%s\n' "${displays[$i]}" "${thumbs[$i]}"
        done | rofi "${rofi_args[@]}"
    )" || return 0
    [[ -n "$choice" ]] || return 0
    choice="${choice#● }"

    # map the chosen label back to its file path
    for i in "${!labels[@]}"; do
        if [[ "${labels[$i]}" == "$choice" ]]; then
            wall_set "${files[$i]}"
            return 0
        fi
    done
    err "could not resolve selection: $choice"
    return 1
}
