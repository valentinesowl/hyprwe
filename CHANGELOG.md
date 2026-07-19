# Changelog

Format — [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versioning — [Semantic Versioning](https://semver.org/).

The version lives in `bin/hwe` (`HWE_VERSION`). The release workflow will not publish
a tag that disagrees with it, and a test pins it to the newest entry in this file — so
the three sources cannot drift apart.

## [Unreleased]

### Added

- **A personal layer in `~/.config/hwe/`** — the settings that are yours rather
  than the repository's, kept outside the checkout. `hypr.conf` (sourced last by
  Hyprland, so your displays, input and keybinds override what HWE ships),
  `packages.lst` and `packages-aur.lst` (extra packages for this machine,
  installed and drift-checked exactly like HWE's own lists), and the Waybar
  overrides that already lived there. The files are created once on install and
  never rewritten — `hwe update` only ever puts back one you deleted.

  This closes a collision between two things HWE promised. `config/` is deployed
  by symlink, so personalising the environment meant editing tracked files —
  and `hwe update`'s fast-forward pull refuses to run on a dirty tree. Setting
  up your monitors used to cost you the ability to update. Now `git status`
  stays clean whatever you change, and a pull can never conflict with it.

### Changed

- `hwe doctor host` reports the personal layer: a file of your own is stated as
  such and never counted as drift, a missing one is a finding. `config/hypr/monitors.conf`
  now says where your monitor lines belong instead of inviting an edit in place.

- `hwe update` on a branch with no upstream now names the way out instead of just
  the problem: the exact `git branch --set-upstream-to=…` command when the matching
  remote branch exists, and what is actually missing when it does not. A clone sets
  tracking up on its own, so this is mostly a checkout built locally and pushed
  without `-u`.
- The release badge in both READMEs is a static one, pinned to `HWE_VERSION` by
  `tests/test_release.py`. The dynamic `shields.io/github/v/release` endpoint was
  answering 520 and rendering as broken alt text.

## [1.1.0] — 2026-07-19

Lifecycle: keeping an installed machine in line with the repository, and testing a
change before committing it.

### Added

- **`hwe update`** — bring the machine in line with the repository: `git pull
  --ff-only` (safe — it refuses on uncommitted changes or diverged history and
  leaves those to you), relink the configs, re-apply the current theme, install
  packages that are missing (core + dev, AUR best-effort; it asks before
  installing). `hwe update --check` is a read-only drift report and nothing else.
- **`hwe vm up --uncommitted`** (and `hwe vm rebuild --uncommitted`) — deploy the
  working tree into the VM as it is: the branch's history plus everything
  uncommitted on top of it (modified, staged, deleted and new files). Testing a
  change used to require committing it first. The snapshot is built through a
  separate index and a temporary `--shared` clone — your index, working tree and
  branches do not move, and no commit appears in your history. Ignored files stay
  behind: they are generator output, and the guest builds its own.
- **`hwe doctor host`** — check an installed machine for drift: are the `~/.config`
  symlinks intact, are the packages from the lists installed, is `hyprctl
  configerrors` clean, is zsh the login shell. Read-only, it changes nothing.
  Bare `hwe doctor` now means `hwe doctor host`; the former VM prerequisite check
  moved under an explicit **`hwe doctor vm`**.

### Fixed

- Deployment no longer creates inert `~/.config/{color-schemes,kvantum,sddm}` symlinks.
  Those three `config/<name>/` dirs are `theme apply` output that is read from other
  paths (XDG_DATA for the colour scheme, assembled into `~/.config/Kvantum/HWE`,
  installed into `/usr/share/sddm/themes/hwe`) rather than from `~/.config`. The shared
  `_config_is_staging` predicate excludes them from the deploy and from `hwe doctor host`
  alike, so the check cannot diverge from the install.

## [1.0.0] — 2026-07-18

The first stable release. From here on `hwe` is a public interface: breaking changes
to it only ship in 2.0.0.

### Added

- **A dev VM in one command.** `hwe vm up` brings up an Arch VM through
  `libvirt`/`virt-install` (visible in virt-manager), provisions it fully
  automatically with `cloud-init` and deploys the chosen **local** git branch —
  with no push to GitHub. The cloud image is verified by GPG signature against a
  pinned arch-boxes key, with a SHA256 cross-check, before anything is built.
- **One theme engine.** A single `themes/<name>/theme.toml` → the colours of every
  component. A contract of 19 semantic roles, rendered through Jinja2 into
  `config/<app>/colors.*`; a missing role fails the render outright instead of
  painting the screen black. `hwe theme apply` changes the whole desktop live.
- **Ten built-in themes** — eight dark (default, mocha, ember, frost, garden, neon,
  void, amethyst) and two light (**`paper`**, the crisp reference, and **`linen`**,
  soft and warm with a low peak brightness for light-in-the-dark). `neon` is
  cyberpunk / neon-noir. Each comes with a procedurally generated wallpaper and a
  preview card; each one's contrast clears the WCAG threshold (pinned by
  `tests/test_theme_contrast.py`).
- **Light mode** — `scheme = "dark"|"light"` in `[params]`. It switches GTK
  `prefer-dark`, `gsettings color-scheme` and the kitty ANSI swaps (black and white
  stay at their own ends).
- **Your own themes live outside the repository** — `~/.local/share/hwe/themes/`
  (the path is overridable via `HWE_THEMES_USER`). They are built exactly like the
  shipped ones: `list`/`validate`/`apply`/`pick`/`wall` treat both roots the same.
  Your themes never surface in `git status`, never conflict on `git pull` and never
  disappear with a checkout. A theme named like a shipped one **overrides** it —
  `hwe theme list` marks yours as `(yours)`.
- **The `on_accent` role** — the derived "ink" for text on top of an accent fill (the
  solid pill of the active workspace stays readable on any accent). It is picked by
  contrast from `bg_dark`/`fg_white`, is correct in a light theme too, and can be
  pinned in `[sem]`. It is not part of the 19-role contract.
- **`[params]` customisation**: `bar_opacity` (alpha of the bar's backdrop),
  `anim_speed` (window animation speed; `0` disables them), `icon_theme` /
  `cursor_theme` / `gtk_theme`. The rofi window's rounding follows `rounding`.
  `[font].ui_family` is a separate UI font for GTK applications (`Sans` by default),
  so the mono family does not creep into GTK.
- **The bar layout lives outside the theme**: `~/.config/hwe/waybar.jsonc` is deep-merged
  over the generated `config.jsonc` on every apply (`scripts/wbmerge.py`). Move, drop or
  add widgets without editing a generated file.
- **Procedural wallpapers** (`scripts/genwall.py`): six styles (mesh, aurora, voronoi,
  grid, signal, skyline), with the palette taken from the theme. Not a single
  third-party image — everything is computed from the palette, so it ships in the
  repository with no licensing tail. The composition is deterministic per theme name.
- **A modular Hyprland config** — hyprland, kitty, waybar, rofi, mako, hyprlock and
  hypridle wired together with `source` includes.
- **Waybar**: a thin monospaced bar where every indicator is a single Nerd Font glyph
  that morphs with the level; exact values live in the tooltip. The CPU/RAM/temperature
  widgets (`scripts/wbstat.py`) find the sensor by chip name (coretemp, k10temp,
  zenpower, cpu_thermal, acpitz) rather than by hwmon number, and hide themselves when
  there is no sensor.
- **NVIDIA on bare metal** (experimental). The installer detects NVIDIA via `lspci` and
  sets up the driver (open modules for Turing+, proprietary for older cards by chip
  code), DRM modesetting, initramfs modules and a pacman rebuild hook. The driver
  selection logic and the `mkinitcpio.conf` edits are covered by tests
  (`tests/bats/gpu.bats`), but the path itself is **untested on live NVIDIA hardware**.
  `HWE_NO_NVIDIA=1` skips it; `HWE_NVIDIA_DRIVER` pins the package. Intel/AMD are not
  touched by any of this. `hwe uninstall` does not roll it back.
- **The `hwe` CLI**: `vm`, `install`, `uninstall`, `theme`, `wall`, `power`, `keys`,
  `clip`, `record`, `checkconfig`, `doctor`, `version`.
- **An SDDM theme** — a QML greeter, kept in sync with the active palette.
- **Quality gates**: shellcheck + ruff + pytest + bats, all run by the single command
  `just check`, and by the same command in CI.

### Security

- **Theme values are checked for shape before the render, not just for presence.**
  `config/hypr/theme.conf` is sourced by `hyprland.conf`, so a role like
  `accent = "#000000\nexec-once = …"` (`\n` being a legal TOML escape) would append
  arbitrary Hyprland directives to it, executed at login. Colours must be `#rrggbb`,
  numbers must be numbers within their ranges, strings must carry no control
  characters; otherwise nothing renders at all, and `--lenient` does not forgive it.
  An unknown key in `[params]` is not an error — a theme written for a future HWE
  degrades instead of failing.
- **A theme name is validated as a directory name** (letters/digits and `. _ -`, not
  leading with a dot or a hyphen): `hwe theme apply ../../etc` cannot escape the theme
  roots, and a name with a leading hyphen cannot be read as an option.

### Known limitations

- A foreign config in `/etc/sddm.conf.d` left behind by another environment can override
  ours: SDDM reads every file in that directory and the alphabetically last one wins.
  HWE deliberately does not touch files it does not own — removing them is the job of
  that environment's uninstaller. If the login screen looks foreign after
  `hwe theme sddm`, look at what is in that directory.

[Unreleased]: https://github.com/valentinesowl/hyprwe/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/valentinesowl/hyprwe/releases/tag/v1.1.0
[1.0.0]: https://github.com/valentinesowl/hyprwe/releases/tag/v1.0.0
