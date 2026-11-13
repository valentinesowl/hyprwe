# HWE themes

**English** · [Русский](README.ru.md)

A theme is **one** file: `themes/<name>/theme.toml`. From it, `hwe theme apply <name>`
renders the colors and geometry of **every** component (hyprland, waybar, kitty, rofi, mako,
GTK 3/4, Kvantum, starship, kdeglobals, hyprlock, SDDM) through the `templates/**/*.j2` templates.
No hand-duplicated palettes: you edit values in one place and everything is redrawn.

## Where themes live

Two roots, identical layout:

| Root | What it is |
|---|---|
| `themes/` (in the repo) | themes HWE ships; tracked in git |
| `~/.local/share/hwe/themes/` | **your** themes; git knows nothing about them |

Your themes live **outside the repo** on purpose: they don't show up in `git status`, don't
conflict on `git pull`, and don't disappear when you reinstall the checkout. Both roots are
visible in `hwe theme list` (yours are marked `(yours)`), and `apply`/`validate`/`pick`/`wall`
work the same with either.

A theme whose name matches a shipped one **overrides** it — that's how you retune `frost`
for yourself without touching the repo. The path to your own root is overridden with `HWE_THEMES_USER`.

## Anatomy of a theme folder

```
<root>/<name>/
├── theme.toml            # THE single source of truth: [palette] + [sem] + [params] + [font]
├── wallpaper.png         # generated wallpaper (genwall.py) — tracked in git for shipped themes
├── wallpaper.gif         # (opt.) animated mesh wallpaper for awww
├── preview.png           # preview card for the rofi gallery (genpreview.py)
└── wallpapers/           # (opt.) your own photos/GIFs — in .gitignore, not shipped
```

Only `theme.toml` is required. `wallpaper.png`/`preview.png` are generated (see below).

## `[palette]` versus `[sem]`

- **`[palette]`** is the theme's private "kitchen" (the full Catppuccin set, say). You need it
  as a reference while picking colors. Templates **never see it**.
- **`[sem]`** is the semantic **contract**: the set of roles the templates read. The code never
  reaches for raw palette names, only for roles. A missing role is a render error (fail-loud),
  not a silent black screen.

```toml
name = "My Theme"

[palette]                  # optional, for yourself
mauve = "#cba6f7"

[sem]                      # required — the contract (see the roles table)
accent = "#cba6f7"
# …

[params]                  # optional — geometry/opacity (see the table)
font = "JetBrains Mono"
```

## `[sem]` roles (required — all 19)

| Group | Roles |
|---|---|
| Surfaces (dark → light) | `bg_dark` `bg_normal` `bg_light` `bg_lighter` |
| Text (dim → contrasting) | `fg_dim` `fg_normal` `fg_bright` `fg_white` |
| Accent | `accent` `accent_soft` |
| Raw colors | `red` `green` `yellow` `orange` `blue` `magenta` `cyan` |
| Utility | `border` `urgent` |

Values are hex strings, `"#rrggbb"`. Skip any role and `hwe theme validate` and `apply` fail
with an explicit list of what's missing (you can force it with `--lenient`, and then the gaps
are filled with a screaming `#ff00ff`).

## Value shape (checked before rendering)

The contract says which keys must be there; this says what they are allowed **to be**.
Hyprland values in `config/hypr/theme.lua` are emitted through an explicit Lua serializer
(strings, booleans, numbers and arrays), so quotes, backslashes and newlines remain data.
All templates are rendered into staging first; a failure leaves the live files unchanged,
and `theme.lua` is replaced atomically. A theme is data, not code.

| What | Rule |
|---|---|
| `[sem]` roles, `border_inactive` | exactly `#rrggbb` |
| `border_gradient` | non-empty list of `#rrggbb` |
| `opacity`, `active_opacity`, `inactive_opacity` | number 0…1 |
| `border_angle` | number 0…360 |
| other numeric `[params]` | number ≥ 0 (`true` won't pass for 1) |
| `bar_height` | number ≥ 1 |
| `bar_float` | `true`/`false` |
| `bar_ws_indicator` | one of `glow` `underline` `pill` `dot` |
| `name`, `font.family` | non-empty string, no control characters and no `" ; { } \ */ /*` |
| `[font]` sizes | positive number |
| `[palette]` | free form (templates don't read it) — but no control characters |
| theme folder name | letters/digits and `. _ -`, not starting with a dot or a hyphen |

An unknown key in `[params]` is **not** an error: a theme written for a future HWE should
degrade, not crash (the templates simply don't read it). A typo in `[font]`, on the other hand,
gives a warning — there the full set of keys is known.

A shape violation is **not** forgiven by `--lenient`: it fills in what a theme *forgot*, not
what it stated incorrectly.

**Auto-aliases** (you may leave them out — they're derived from the raw colors):
`good`←`green`, `warn`←`yellow`, `bad`←`red`, `info`←`blue`. Plus `transparent` = `#00000000`
is injected.

**Derived roles `on_accent` and `on_urgent`** — readable "ink" for text or a glyph drawn
**on top of** the corresponding fill (selected rows, the active workspace pill, accent buttons).
The renderer compares the theme's `bg_dark` and `fg_white`, with pure black/white as fallbacks
for mid-luminance fills where neither theme extreme reaches 4.5:1. You can pin either role in
`[sem]`; neither is part of the 19-role contract.

## `[params]` parameters

Every parameter has a default — you can omit all of `[params]`, and the theme renders as the base one.

| Parameter | Default | Purpose |
|---|---|---|
| `rounding` | `10` | window corner rounding |
| `border_size` | `2` | border thickness |
| `gaps_in` / `gaps_out` | `5` / `12` | inner / outer gaps |
| `opacity` | `0.94` | base opacity (terminal; focus) |
| `blur_size` / `blur_passes` | `6` / `3` | blur radius and number of passes |
| `border_gradient` | `[accent_soft, accent]` | colors of the animated border (list of hex) |
| `border_angle` | `270` | starting angle of the border gradient |
| `border_animate` | `100` | ds per revolution; higher = quieter, `0` = static |
| `border_inactive` | `bg_lighter` | border of an inactive window |
| `active_opacity` / `inactive_opacity` | `opacity` / `opacity-0.04` | alpha of whole windows |
| `bar_height` | `28` | quiet waybar height; shipped themes keep at least 28px |
| `bar_float` | `false` | a "floating" island instead of a glued-on bar |
| `bar_gap` / `bar_gap_x` / `bar_radius` | `6` / `8` / `14` | gaps and rounding of the floating bar |
| `bar_opacity` | `0.94` | backing opacity that preserves text contrast on arbitrary wallpapers |
| `bar_ws_indicator` | `underline` | active-tag marker: `glow` `underline` `pill` `dot` |
| `bar_ws_speed` | `220` | calm transition duration; personal reduced motion forces `0` |
| `scheme` | `dark` | `dark`/`light` — lightness scheme (GTK, Kvantum, kitty ANSI swaps, SDDM/hyprlock scrim) |
| `anim_speed` | `1.0` | speed multiplier for window animations: higher = snappier, `0` = turn everything off |
| `icon_theme` | `Adwaita` | GTK icon theme |
| `cursor_theme` | `` (empty) | cursor theme; empty = don't touch the system/Hyprland cursor |
| `gtk_theme` | `Adwaita` | GTK theme name (e.g. `adw-gtk3-dark`) |

> `opacity_unfocused` is derived from `opacity` automatically — no need to set it.
> The rofi window rounding is derived from `rounding` (`rounding + 6`); there is no separate key.

**Every theme's signature is its animated border:** the gradient rotates forever, and the colors
"flow" around the active window. `neon` and `amethyst` use a slower rainbow (`border_animate = 60`),
the rest are a quiet single-color shimmer. To turn it off: `border_animate = 0`, or use the
persistent reduced-motion block in `~/.config/hwe/hypr.lua`.

## Typography `[font]`

A separate **contract** table: the font family plus a size for each surface. Templates read
**only** these values (nothing hardcodes a font anywhere). Any line may be omitted — the
renderer's default (fallback) is substituted. Sizes are in pt (px for the bar); `terminal` may
be fractional.

| Key | Default | Surface |
|---|---|---|
| `family` | `JetBrains Mono` | mono font: kitty, waybar, rofi, mako, hyprlock |
| `icon_family` | `Symbols Nerd Font Mono` | standalone icon glyphs, used as a fallback after the text font |
| `fallback_family` | `JetBrains Mono` | packaged mono fallback when the theme's `family` is unavailable |
| `ui_family` | `Sans` | proportional UI font for GTK applications (size comes from `gtk`) |
| `terminal` | `9.5` | kitty (starship inherits it — it has no size of its own) |
| `bar` | `12` | waybar |
| `launcher` | `12` | rofi menus — the **base**; derived surfaces adjust it where appropriate |
| `notify` | `11` | mako |
| `gtk` | `11` | font size of GTK applications (family comes from `ui_family`) |

```toml
[font]
family   = "JetBrains Mono"
terminal = 11        # larger in the terminal
launcher = 12        # and in the launcher
```

> Change `family` and it changes across all mono surfaces at once (kitty/waybar/rofi/mako/
> hyprlock). GTK has a separate `ui_family` (`Sans` by default, a UI font) so the mono font
> doesn't creep into applications; the GTK size is the `gtk` key.

## Light themes (`scheme = "light"`)

The `[sem]` contract is neutral with respect to lightness: the same 19-role table, just filled
in from the light end (dark ink on light surfaces). The order of the roles doesn't change —
`bg_dark` is still the **darkest** surface (a soft gray in a light theme), and `fg_white` is
the **most contrasting** text (nearly black in a light theme).

`scheme = "light"` in `[params]` additionally switches what can't be expressed with color:

- GTK/libadwaita `prefer-dark` → off, and `gsettings color-scheme` → `prefer-light`;
- in kitty the ANSI "black"/"white" (0/7/8/15) swap ends, so that "black" text stays dark on
  light paper instead of being painted the color of the surface;
- Waybar's StatusNotifier tray gets an accent chip behind applications' icons, which CSS
  cannot reliably recolour like text; symbolic tray icons use the matching `on_accent` ink.

There are two shipped examples: the sharp reference **`paper`** (full brightness — it proves
the neutrality) and the soft, warm **`linen`** (low peak brightness, for a light theme in a
dark room). Kvantum selects `KvArc` for light schemes and `KvArcDark` for dark ones, with the
other installed Arc base as fallback. An explicit `HWE_KVANTUM_BASE` always wins. SDDM and
hyprlock use a scheme-coloured 94% scrim so text does not depend on wallpaper brightness.

All shipped themes clear **4.5:1 for meaningful small text**, including `fg_dim`, accent and
urgent roles, and **3:1 for meaningful non-text UI**. Tests cover `on_accent`/`on_urgent`,
selected states and actual alpha-composited bar/access-screen backgrounds over white, black
and grey wallpapers. `fg_bright` retains a stricter 6:1 design target. The 3:1 large-text
threshold is never used to excuse 12px labels. Custom themes receive non-fatal accessibility
warnings instead of losing backward compatibility.

## Bar layout — outside the theme (`~/.config/hwe/waybar.jsonc`)

**Which** widgets are on the bar, in what order, and what a click does is the user's choice,
not the theme's. That's why it isn't in `theme.toml`. Drop in an optional
`~/.config/hwe/waybar.jsonc` and `hwe theme apply` will **deep-merge** it over the generated
`config.jsonc` on every apply (`scripts/wbmerge.py`):

```jsonc
{
    // reorder/remove widgets: the array is replaced wholesale
    "modules-right": ["battery", "pulseaudio", "tray", "custom/cpu"],
    // but an object is merged by key — we only fix the clock format
    "clock": { "format": "{:%H:%M}" },
    // null deletes a generated key
    "custom/temp": null
}
```

Merge rules: objects merge recursively by key; arrays/strings/numbers are replaced wholesale;
`null` deletes a key. One small untracked file survives both theme switching and `git pull`.
Broken JSON does not fail the apply: you get a warning and the generated config is used.

## How to add your own theme

```bash
# 1. Copy any theme as a base — into YOUR root, not the repo
mkdir -p ~/.local/share/hwe/themes
cp -r themes/mocha ~/.local/share/hwe/themes/mytheme
cd ~/.local/share/hwe/themes/mytheme
rm -f wallpaper.png preview.png    # these are mocha's images, we'll make our own now

# 2. Edit theme.toml
#    → name, [sem] roles; [palette], [params], [font], [wallpaper] are optional

# 3. Check the contract
hwe theme validate mytheme

# 4. Generate the wallpaper and preview (<repo> = your HWE checkout; needs python-numpy from pkg/dev.lst)
python3 <repo>/scripts/genwall.py    --theme theme.toml wallpaper.png
python3 <repo>/scripts/genpreview.py theme.toml preview.png

# 5. Apply
hwe theme apply mytheme          # or interactively: hwe theme pick (SUPER+SHIFT+T)
```

You don't have to edit a single template or a single config — only `theme.toml`.

> The wallpaper is optional: without `wallpaper.png` the theme applies fine, it just won't
> touch the current wallpaper. Without `preview.png` it shows up in `hwe theme pick` with no image.
>
> `just walls` / `just previews` regenerate the **shipped** themes (`themes/*/`) — for your own,
> call the generators directly, as above.

## Wallpapers and previews

- **`wallpaper.png`** is generated by `scripts/genwall.py` — procedural art from `[sem]` and
  the `[wallpaper]` block. 100% our own, with no third-party images or licenses — which is why
  it's tracked in git. Regenerate: `just walls` (needs `python-numpy` from `pkg/dev.lst`).

  ```toml
  [wallpaper]
  style     = "aurora"   # see the table below; "mesh" by default
  seed      = 42         # (opt.) reroll the composition without renaming the theme
  intensity = 0.65       # (opt.) accent volume, 1.0 by default
  animated  = true       # (opt.) also generate wallpaper.gif; mesh only
  ```

  For `animated = true`, `just walls` also generates a seamless 144-frame, 24fps GIF at
  1280×720 using `ffmpeg` from `pkg/dev.lst`. `awww` displays it on the desktop while
  hyprlock/SDDM retain `wallpaper.png`; without `awww`, the static PNG is used instead.

  | style     | what it draws                             | who it suits          |
  |-----------|-------------------------------------------|-----------------------|
  | `mesh`    | soft cloudy gradient + glows              | restrained themes     |
  | `aurora`  | ribbons of light (domain-warped noise)    | organic, flowing ones |
  | `voronoi` | crystalline facets with glowing edges     | icy, low-poly ones |
  | `rust`    | brushed steel, oxidation and dark pitting   | industrial, corroded ones |
  | `grid`    | synthwave: a sun in stripes + a grid in perspective | loud, retro ones |
  | `signal`  | a barely smoldering phosphor trail in the void | near-black, empty ones |
  | `skyline` | neon night city: rooftop silhouettes + pink/cyan windows | dark, cinematic ones |

  The style is chosen **by the character of the theme**, not for the sake of variety: `neon` is
  cyberpunk, a city at night, hence `skyline`; `amethyst` is quiet everywhere except its border,
  hence the quiet `aurora`; `void` is "a barely traceable signal in the emptiness of endless
  space", hence `signal`, where the emptiness is the subject. The composition (gradient angle,
  the number and positions of the glows, the cell count)
  is derived from seed = crc32 of the theme name — each theme gets its own picture, not a shared
  one in a different shade. `intensity` is for dark themes with a bright accent: `void` has a
  `#050508` background against a `#00ffd2` accent, and at full volume the wallpaper shouts over
  the desktop.
- **`preview.png`** is generated by `scripts/genpreview.py` — a graphic identity card built
  from the theme palette, its typeface and a distinctive geometric motif. A softly blurred,
  darkened wallpaper sits behind the artwork; fake desktop widgets are not used. The name is
  part of the artwork; selection is only an outline. Enter applies, and Escape cancels without
  changing the theme. Regenerate: `just previews`.
- Your own photos/GIFs: drop them into `~/.config/hwe/themes/<name>/wallpapers/` — they show
  up in `hwe wall pick` next to the generated ones and stay outside the checkout. The legacy
  `themes/<name>/wallpapers/` directory is still supported. The active choice is remembered
  beside them in `.current_wallpaper`.

## How it works under the hood

`scripts/render-theme.py` reads `theme.toml`, checks the `[sem]` contract, then walks all of
`templates/**/*.j2` and renders each into `config/…` (Jinja2, `StrictUndefined` — touching an
undefined variable is an error). There are filters for the different syntaxes: `noh`
(`#cba6f7`→`cba6f7`), `rgb`/`rgba` (Hyprland), `hexa` (`#cba6f7ed` — rofi/CSS parsers),
`kcol` (`203,166,247` for KDE). After that,
`hwe theme apply` symlinks the result into `~/.config` and reloads the running applications.
