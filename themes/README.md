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
├── preview.png           # preview card for the rofi gallery (genpreview.py)
├── wallpapers/           # (opt.) your own photos — in .gitignore, not shipped
└── .current_wallpaper    # (runtime) remembered wallpaper choice — in .gitignore
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
font = "JetBrainsMono Nerd Font"
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

The contract says which keys must be there; this says what they are allowed **to be**. Every
value is substituted into a config verbatim, and `config/hypr/theme.conf` is **sourced** by
`hyprland.conf` — so a color with a newline inside it would append arbitrary Hyprland
directives (`exec-once = …`) to that file, and they would run at login. A theme is data, not
code; the checks below are what makes that true.

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

**Derived role `on_accent`** — readable "ink" for text or a glyph drawn **on top of** an accent
fill (the solid pill of the active workspace, accent buttons). It's picked automatically from
the two edges of the contract — `bg_dark` and `fg_white` — whichever contrasts more with
`accent` (which is why it works the same in a dark and a light theme). You can pin it by hand
in `[sem]`; it is **not** part of the 19-role contract.

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
| `bar_height` | `26` | waybar height |
| `bar_float` | `false` | a "floating" island instead of a glued-on bar |
| `bar_gap` / `bar_gap_x` / `bar_radius` | `6` / `8` / `14` | gaps and rounding of the floating bar |
| `bar_opacity` | `0.62` | alpha of the bar backdrop over the wallpaper (how much "glass" is in the bar) |
| `bar_ws_indicator` | `glow` | how the active tag is marked: `glow` `underline` `pill` `dot` |
| `scheme` | `dark` | `dark`/`light` — lightness scheme (GTK prefer-dark, KDE, kitty ANSI swaps) |
| `anim_speed` | `1.0` | speed multiplier for window animations: higher = snappier, `0` = turn everything off |
| `icon_theme` | `Adwaita` | GTK icon theme |
| `cursor_theme` | `` (empty) | cursor theme; empty = don't touch the system/Hyprland cursor |
| `gtk_theme` | `Adwaita` | GTK theme name (e.g. `adw-gtk3-dark`) |

> `opacity_unfocused` is derived from `opacity` automatically — no need to set it.
> The rofi window rounding is derived from `rounding` (`rounding + 6`); there is no separate key.

**Every theme's signature is its animated border:** the gradient rotates forever, and the colors
"flow" around the active window. `neon` and `amethyst` are a loud rainbow (`border_animate = 25`),
the rest are a quiet single-color shimmer. To turn it off: `border_animate = 0`.

## Typography `[font]`

A separate **contract** table: the font family plus a size for each surface. Templates read
**only** these values (nothing hardcodes a font anywhere). Any line may be omitted — the
renderer's default (fallback) is substituted. Sizes are in pt (px for the bar); `terminal` may
be fractional.

| Key | Default | Surface |
|---|---|---|
| `family` | `JetBrainsMono Nerd Font` | mono font: kitty, waybar, rofi, mako, hyprlock |
| `ui_family` | `Sans` | proportional UI font for GTK applications (size comes from `gtk`) |
| `terminal` | `9.5` | kitty (starship inherits it — it has no size of its own) |
| `bar` | `12` | waybar |
| `launcher` | `11` | rofi menus — the **base**; pickers take ± from it (launcher +2, powermenu +1, keys +0, theme/wallpaper −1/−2) |
| `notify` | `11` | mako |
| `gtk` | `11` | font size of GTK applications (family comes from `ui_family`) |

```toml
[font]
family   = "JetBrainsMono Nerd Font"
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
  light paper instead of being painted the color of the surface.

There are two shipped examples: the sharp reference **`paper`** (full brightness — it proves
the neutrality) and the soft, warm **`linen`** (low peak brightness, for a light theme in a
dark room). All shipped themes pass the WCAG contrast threshold from
`tests/test_theme_contrast.py`.

> Limitation: Qt/Kvantum widgets take their geometry from the dark base `KvArcDark`
> (`HWE_KVANTUM_BASE`), so under a light theme the borders of Qt applications may look a bit
> dark. The palette is light nonetheless. GTK is the main target of light mode.

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
  ```

  | style     | what it draws                             | who it suits          |
  |-----------|-------------------------------------------|-----------------------|
  | `mesh`    | soft cloudy gradient + glows              | restrained themes     |
  | `aurora`  | ribbons of light (domain-warped noise)    | organic, flowing ones |
  | `voronoi` | crystalline facets with glowing edges     | icy, low-poly ones |
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
- **`preview.png`** is generated by `scripts/genpreview.py` — a card over the wallpaper for the
  rofi gallery (`hwe theme pick`). Regenerate: `just previews`.
- Your own photos: drop them into `themes/<name>/wallpapers/` (which is in `.gitignore`) — they
  show up in `hwe wall pick` next to the generated ones. The active choice is remembered in `.current_wallpaper`.

## How it works under the hood

`scripts/render-theme.py` reads `theme.toml`, checks the `[sem]` contract, then walks all of
`templates/**/*.j2` and renders each into `config/…` (Jinja2, `StrictUndefined` — touching an
undefined variable is an error). There are filters for the different syntaxes: `noh`
(`#cba6f7`→`cba6f7`), `rgb`/`rgba` (Hyprland), `hexa` (`#cba6f7ed` — rofi/CSS parsers),
`kcol` (`203,166,247` for KDE). After that,
`hwe theme apply` symlinks the result into `~/.config` and reloads the running applications.
