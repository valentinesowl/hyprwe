# Customization and Hyprland configuration

**English** · [Русский](CUSTOMIZATION.ru.md) · [Back to the project](../README.md)

## Your own settings

Some things cannot come from the repository, because they are not the same twice: your
displays, the keys your hands already know, the packages this particular machine needs.
Those live in `~/.config/hwe/` — **outside the checkout**, created for you on install and
never rewritten afterwards.

| File | What it holds |
|---|---|
| `hypr.lua` | displays, input, keybinds — required **last**, so it overrides what hyprwe ships |
| `packages.lst` | extra packages for this machine (the distribution's own) |
| `packages-aur.lst` | the same, from the AUR (Arch; skipped on Ubuntu) |
| `waybar.jsonc` | your bar's composition — merged over the generated config on every theme apply |
| `hyprsunset.conf` | your night-light schedule — `hwe sunset` toggles it |
| `kanshi.conf` | your monitor profiles — dock and the layout follows, undock and it snaps back |
| `themes/` | hyprwe's own notes per theme — which theme is applied, which wallpaper each one uses |

```bash
$EDITOR ~/.config/hwe/hypr.lua    # your monitors go here, not in config/hypr/monitors.lua
hyprctl reload                     # SUPER+SHIFT+R
```

For reduced motion, uncomment `local reduced_motion = true` in that file, reload Hyprland
and run `hwe theme apply` once. The personal block disables window animations, blur and the
infinite `borderangle` loop; the renderer also sets every Waybar transition to zero. Without
it, workspaces and indicators keep their calm 220ms transitions. The setting survives updates.

For a laptop that meets a dock, `kanshi.conf` is the better home for the monitors: a
profile applies the moment its outputs are all connected. Use one owner per output — a
display managed by kanshi should not also have an `hl.monitor` call in `hypr.lua`.

**Upgrading from hyprwe 1.4:** an untouched legacy `hypr.conf` gains a new `hypr.lua`
automatically. If you changed `hypr.conf`, `hwe update` stops before deployment until you
create `hypr.lua` yourself. The old file is preserved for reference and is never executed
or deleted by hyprwe. See the skeleton for `hl.monitor`, `hl.config`, `hl.bind` and
`hyprland.start` examples. The other Hypr* tools still use their `.conf` files.

The location is the whole point. `config/` is deployed as symlinks into the repository, so
tuning something in place would be an edit to a **tracked file** — and `hwe update` refuses
to pull onto a dirty tree. Kept in `~/.config/hwe/` instead, `git status` stays clean whatever
you change, a pull can never conflict with your setup, and replacing the checkout does not
take your settings with it.

A theme of your own goes in `~/.local/share/hwe/themes/<name>/`, where it shadows a shipped
theme of the same name. See [Writing a theme](../themes/README.md).

`hwe doctor` states what you have made your own and never calls it drift. The one thing it
does report is a **missing** file — `hwe update` puts it back. A file you have edited is
never rewritten; one you have *not* quietly keeps up with the shipped defaults. To restore
the defaults, `hwe update --reset-defaults` keeps your versions beside them as `*.hwe-bak`.

## The Hyprland config

The entry point is `config/hypr/hyprland.lua`, which requires each module separately:

| File | What it covers |
|---|---|
| `environment.lua` | session environment variables |
| `monitors.lua` | the fallback output rule (**yours** go in `~/.config/hwe/hypr.lua`) |
| `appearance.lua` | general / decoration / blur / curves / animations |
| `theme.lua` | **generated** — border, geometry, opacity and animation speed |
| `input.lua` | keyboard (us/ru), touchpad, gestures |
| `keybindings.lua` | described keybinds |
| `windowrules.lua` | window and layer rules |
| `session-layout.lua` | Lua layout provider for exact session restore |
| `autostart.lua` | one `hyprland.start` handler for session programs |

Last of all, `~/.config/hwe/hypr.lua` overrides everything above it. `hypridle.conf` handles
idle → lock/DPMS, and `hyprlock.conf` is generated. On every login `hwe checkconfig --notify`
puts syntax errors on screen, should Hyprland change its grammar.

## Main keybindings

`SUPER+T` terminal · `SUPER+N` files · `SUPER+B` browser · `SUPER+R` launcher ·
`SUPER+Q` close · `SUPER+V` floating · `SUPER+F` fullscreen · `SUPER+←↑↓→` focus ·
`SUPER+SHIFT+←↑↓→` move the window · `SUPER+1..0` workspaces · `SUPER+X` scratchpad ·
`SUPER+S` then `1..9` save session · `SUPER+S` then `SHIFT+1..9` restore session ·
`SUPER+L` / `SUPER+Escape` lock · `SUPER+Space` us↔ru layout ·
`SUPER+SHIFT+T` theme · `SUPER+SHIFT+W` wallpaper · `SUPER+SHIFT+E` power menu ·
`SUPER+/` bind cheatsheet · `SUPER+C` clipboard · `SUPER+SHIFT+C` colour picker ·
`SUPER+ALT+R` / `SUPER+ALT+S` screen recording (whole / region) ·
`Print` screenshot → clipboard · `SHIFT+Print` region → clipboard ·
`SUPER+Print` region → `~/Pictures` ·
`SUPER+SHIFT+Print` / `SUPER+P` region with annotation → `~/Pictures`.
