# Contributing to HWE

**English** · [Русский](CONTRIBUTING.ru.md)

Thanks for stopping by. HWE is a reproducible Wayland + Hyprland environment on Arch, built
around two principles: **everything is automated** and **color lives in one place**. Stick to
them and your patch will fall into place naturally.

## Getting started

The best way to develop HWE is **inside its own dev VM**: it is isolated from your machine,
comes up with a single command, and deploys **your local branch** (no push to GitHub
required).

```bash
./bin/hwe doctor vm            # check the host (libvirtd, groups, KVM, network)
./bin/hwe vm up --uncommitted  # fast loop: deploy the working tree as it is
./bin/hwe vm up                # or deploy the branch's last commit
./bin/hwe vm ssh               # step inside
./bin/hwe vm rebuild           # rebuild from scratch after big changes
```

Configs inside the VM are deployed as **symlinks** into the repository, so edits in
`~/hwe/config/...` show up immediately. Workflow details are in the
[README](README.md#sandbox-and-development-vm).

> **Never run `hwe install` / `hwe theme apply` / `hwe wall set` on your working machine
> just to test something** — they restart the compositor and the bar, and they change your
> login shell. That is what the VM is for. On bare metal the installer will refuse to start
> from a graphical session anyway.

## Before you open a PR

One command — and it is also the CI:

```bash
just check
```

Green locally means green in the pipeline: CI runs the same gates with the same tools you
do. The tools arrive through `hwe install` (`pkg/dev.lst`); CI installs the same set inline
in the `.github/workflows/` jobs — keep the two in sync when you add a gate. What's inside:

```bash
just lint        # shellcheck -x over bin/hwe, lib/*.sh, provision/*.sh
just lint-py     # ruff check over the whole repo (in practice scripts/ + tests/)
just lint-ci     # actionlint + yamllint over .github/
just test        # = test-py (pytest) + test-sh (bats)
```

**Formatting is not a gate — deliberately.** `just fmt` (shfmt) and `just fmt-py`
(ruff format) exist, use them if you like. But CI does not require them, and no patch gets
turned away over layout: the code has a lot of intentional column alignment (the hint table
in `vm_doctor`, the color tables in `genwall.py`, the theme palettes), and both formatters
come from the `gofmt` school and flatten it with no way to opt out. Linters catch **bugs**,
so they are strict; formatters catch **style**, so they are voluntary.

The Python scripts (`scripts/*.py`) are pure stdlib wherever that is possible. The
exceptions are narrow: `render-theme.py` pulls in jinja2, `genwall.py` uses numpy,
`genpreview.py` calls imagemagick (as an external process). All of it installs from
`pkg/dev.lst`.

## Tests

```
tests/                  pytest — theme engine, generators, waybar module, repo hygiene
tests/bats/             bats   — lib/common.sh, the hwe CLI, hwe theme
```

If you touch `scripts/*.py` or `lib/*.sh`, bring a test along. Some pointers on what to
cover:

- **The theme engine** — the role contract and its fail-loud behavior. A broken color does
  not crash the desktop, it repaints it; the only way to catch that is a test.
- **`wbstat.py`** — the sensor lookup logic is written to travel across Intel/AMD/ARM/VM.
  Your machine exercises exactly one of those branches; the tests feed it a fake `hwmon`
  and check the rest.
- **`genwall.py`** — determinism: the wallpapers are committed, and if a theme stops
  producing the same bytes, `just walls` will start quietly dirtying the working tree on
  every run.
- **`tests/test_repo_hygiene.py`** — guards the git index itself. `.gitignore` is a filter,
  not a guarantee: it has no effect on an already tracked file. The test catches images in
  the root, stray directories and generated configs.

Tests never touch the live system: not `~/.config`, not the compositor, not packages.
Anything that needs real hardware (`hwe install`, `vm`, `theme apply`) belongs in the VM,
not in the tests.

## How everything gets painted (must-read before touching color)

No config hardcodes a color. The single source of truth is the theme palette
`themes/<name>/theme.toml`, section `[sem]` (~19 semantic roles). `render-theme.py` turns
the roles in `templates/<app>/*.j2` into generated `config/<app>/colors.*` (which are in
`.gitignore`), and the configs `source`/`@import`/`include` them.

Hence the rule: **if you change the look, change the template or the theme, not the
generated file.** Files like `config/waybar/config.jsonc`, `config/*/colors.*`,
`config/mako/config`, `hyprlock.conf` are **generated** and overwritten on every
`hwe theme apply` — your hand edit there will be lost. Look for the matching
`templates/*.j2`.

- **Add or change a theme** → [`themes/README.md`](themes/README.md) (the full guide to the
  role contract and `[params]`). Always run `hwe theme validate <name>` — the contract is
  fail-loud, a missing role breaks the render immediately instead of via a silent black
  screen.
- **Add a package** → to `pkg/core.lst` (official repos) or `pkg/aur.lst` (AUR, only if
  there is no way around it; mark anything optional with a comment). Anything that
  generates files in `~/.config` goes into `.gitignore` and into the deploy
  (`_deploy_configs`) as well.
- **Add a keybind** → `config/hypr/keybindings.conf`. The rule: arrows are for focus and
  window movement, and no key is bound twice. Afterwards, update the keybind table in the
  README.

## Commits and PRs

- Commits are short and to the point, in the present tense (`waybar: add cpu graph widget`).
- One PR, one logical topic. Split anything large into a series.
- If your change affects behavior on live hardware (login shell, greeter, autostart),
  describe in the PR how you verified it (ideally in the VM).

## License

HWE is distributed under [GPL-3.0](LICENSE). By opening a PR you agree that your
contribution is licensed on the same terms.
