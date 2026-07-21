# justfile — dev tasks for HWE. Run `just` to list, `just <task>` to invoke.
# Requires: just (installed by pkg/dev.lst). https://github.com/casey/just

# Default: show available tasks
default:
    @just --list

# --- VM workflow ----------------------------------------------------------

# Check host prerequisites for the VM
doctor:
    ./bin/hwe doctor

# Boot a VM deploying the current (or given) local branch
up branch="":
    ./bin/hwe vm up {{branch}}

# SSH into the running VM
ssh:
    ./bin/hwe vm ssh

# Show VM status/IP
status:
    ./bin/hwe vm status

# Fresh reprovision of the VM
rebuild branch="":
    ./bin/hwe vm rebuild {{branch}}

# Tear the VM down and delete its disks
destroy:
    ./bin/hwe vm destroy

# --- Quality gates --------------------------------------------------------
# `just check` is THE gate: it is exactly what CI runs, so a green check here
# means a green pipeline. Every tool it needs is installed by `hwe install`
# (pkg/dev.lst) — see also tests/test_repo_hygiene.py, which enforces that.
#
# Formatters are deliberately NOT part of it: shfmt/ruff-format are gofmt-school
# tools with no way to preserve the column alignment this codebase uses on
# purpose (vm_doctor's hint table, genwall's colour tables, the theme palettes).
# `just fmt` is here for whoever wants it; nothing rejects a patch over layout.

# Everything CI checks. Run before opening a PR.
check: lint lint-py lint-ci test

# --- Linters (these find BUGS — they gate) ---

# Lint every shell script with shellcheck
# -x: follow `source`d files, so the `# shellcheck source=` directives resolve
# instead of being reported as SC1091. Severity stays at the default (info) —
# the few info findings we consider wrong carry a justified inline disable.
lint:
    shellcheck -x bin/hwe lib/*.sh provision/*.sh scripts/*.sh

# Ruff comes from the distro where it is packaged (Arch); Ubuntu's archive has
# neither ruff nor uv, so there it runs through uv — `pipx install uv` once
# (pipx IS packaged), and uvx fetches ruff on first use. Same tool, same
# pyproject.toml config, two delivery channels. Measured 2026-07-20 against
# the 26.04 archive: uv has no candidate under any name.
ruff_cmd := `command -v ruff >/dev/null 2>&1 && echo ruff || echo "uvx ruff"`

# Lint the Python tools + tests with ruff (config: pyproject.toml)
lint-py:
    {{ruff_cmd}} check .

# Lint the CI workflows themselves — a typo'd `on:` silently never runs
# -s: treat yamllint warnings as errors. They are all things we would fix anyway,
# and a "passing" gate that prints complaints trains everyone to ignore it.
lint-ci:
    yamllint -s .github/
    actionlint

# --- Tests ---

# Everything: Python tools + shell CLI
test: test-py test-sh

# Python: the theme renderer, wallpaper/preview generators, waybar module, repo hygiene
test-py:
    python3 -m pytest

# Shell: lib/common.sh helpers, the hwe CLI, `hwe theme`
test-sh:
    bats tests/bats/

# --- Formatters (these find STYLE — they do NOT gate) ---

# Format shell scripts with shfmt (4-space indent)
fmt:
    shfmt -w -i 4 -ci bin/hwe lib/*.sh provision/*.sh

# Check shell formatting without writing
fmt-check:
    shfmt -d -i 4 -ci bin/hwe lib/*.sh provision/*.sh

# Format Python with ruff
fmt-py:
    {{ruff_cmd}} format .

# Review and pin the fonts HWE fetches itself (pkg/fonts.lock).
# Reports only. Read what it prints before you pin: it compares the download
# against the same font from a signed Arch package, parses every table, and says
# what changed since the current pin. Needs ttf-nerd-fonts-symbols-mono (the
# reference to compare against) and python-fonttools.
#   just fonts-lock --write     pin it, once the report is clean
#   just fonts-lock --verify    only ask whether the pinned bytes still match
#                               (what the scheduled Font watch job runs)
fonts-lock *ARGS:
    python3 scripts/fontlock.py {{ARGS}}

# The map records ~20 facts about someone else's package archive; archives move,
# and a rename nobody noticed breaks `hwe install` on Ubuntu silently. Runs in a
# throwaway container so the answer is about a CLEAN machine — on a box that
# already has the packages the check cannot fail, and so proves nothing. This is
# what the scheduled Apt map watch job runs.
# Ask whether pkg/map/apt.map still describes Ubuntu's archive
apt-map-check:
    docker run --rm -v "$PWD:/hwe:ro" -w /hwe ubuntu:26.04 bash scripts/aptmapcheck.sh

# Regenerate every theme's wallpaper gradient
walls:
    for t in themes/*/theme.toml; do python3 scripts/genwall.py --theme "$t" "$(dirname "$t")/wallpaper.png"; done

# Regenerate every theme's preview thumbnail (rofi picker / gallery)
previews:
    for t in themes/*/theme.toml; do python3 scripts/genpreview.py "$t" "$(dirname "$t")/preview.png"; done

# Rebuild the README theme gallery (assets/themes.png) from every preview.png.
# 5 columns, alphabetical (the glob's order); 480px cards in 536px cells on #0d0d12.
gallery:
    montage themes/*/preview.png -tile 5x -geometry 480x480+28+28 -background '#0d0d12' -depth 8 assets/themes.png
    # 2:1 variant for GitHub's social preview (it crops anything else; ≤1MB)
    magick assets/themes.png -background '#0d0d12' -gravity center -extent 2680x1340 -depth 8 assets/social-preview.png
