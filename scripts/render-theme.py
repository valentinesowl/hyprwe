#!/usr/bin/env python3
"""render-theme.py — HWE theme generator.

Reads ONE source of truth (themes/<name>/theme.toml: semantic palette + params)
and renders every component's colour file from Jinja2 templates, so colours are
authored once and all configs regenerate.

Usage:
    render-theme.py <theme.toml> <templates_dir> <out_dir> [--check]

  --check   validate the theme against the role contract and exit (render nothing)

Templates read semantic ROLES, never a theme's private palette; a missing role
fails loud (clear error, non-zero). Values are shape-checked before anything is
rendered — see check_values().
"""
from __future__ import annotations

import math
import re
import sys
import tomllib
from pathlib import Path
from typing import TYPE_CHECKING

# jinja2 is imported lazily (inside make_env) rather than here so the value-shape
# validators below — check_values/validate — can be imported on a box without
# python-jinja. The maintainer tools (genwall.py, genpreview.py) reuse them to
# hold a stranger's theme to the SAME safety line as the runtime renderer,
# without dragging in a dependency they don't otherwise need. The type-checking
# import keeps the make_env return annotation meaningful without importing at run.
if TYPE_CHECKING:
    from jinja2 import Environment

# ── The role contract every theme must satisfy ────────────────────────────
REQUIRED_ROLES = [
    # surfaces (dark -> light)
    "bg_dark", "bg_normal", "bg_light", "bg_lighter",
    # text (dim -> max contrast)
    "fg_dim", "fg_normal", "fg_bright", "fg_white",
    # accent
    "accent", "accent_soft",
    # raw colours (widget multicolour)
    "red", "green", "yellow", "orange", "blue", "magenta", "cyan",
    # service
    "border", "urgent",
]
# Semantic aliases derived from raw colours if a theme doesn't set them.
ALIASES = {"good": "green", "warn": "yellow", "bad": "red", "info": "blue"}

UGLY = "#ff00ff"  # loud placeholder so a forgotten role screams on screen

# ── Typography contract ───────────────────────────────────────────────────
# Font family + per-surface sizes are a first-class part of a theme (table
# [font] in theme.toml), parallel to the [sem] colour contract. These are the
# nice defaults (== the current look) that fill in for any key a theme omits —
# so a theme can tune one surface without redeclaring the rest. Every shipped
# theme still declares the whole block for discoverability.
FONT_DEFAULTS = {
    # The mono font a theme is written in (terminal, bar, rofi, mako, lock).
    # A PLAIN family on purpose: the icon glyphs come from icon_family below,
    # not from a patched copy of this one.
    "family":    "JetBrains Mono",
    # Where the bar's and launcher's icons come from. Splitting it out of
    # `family` is what lets a theme choose its typeface freely: any font can be
    # the text font, because none of them has to carry the icons as well. It
    # also shrinks what has to be trusted — one small glyph font instead of a
    # patched build of every family — and every surface below declares it as a
    # fallback, so a missing glyph resolves here instead of rendering as tofu.
    "icon_family": "Symbols Nerd Font Mono",
    # What to fall back to when `family` is not installed. Every surface names it
    # between the theme's font and the icons, so a theme whose typeface is not
    # packaged on this distribution degrades to a good mono rather than to
    # whatever the system happens to pick. JetBrains Mono because it is packaged
    # everywhere HWE runs — that is the whole requirement for this slot.
    "fallback_family": "JetBrains Mono",
    "ui_family": "Sans",  # the UI/proportional font for GTK apps (size from [font].gtk)
    "terminal":  9.5,   # kitty
    "bar":       12,    # waybar
    "launcher":  11,    # rofi menus — base size; pickers scale ± from it in their templates
    "notify":    11,    # mako
    "gtk":       11,    # GTK apps (proportional; family is ui_family, this is the size)
}
FONT_ROLES = list(FONT_DEFAULTS)
# The two [font] keys that are FAMILIES (strings), not point sizes.
FONT_FAMILY_KEYS = ("family", "icon_family", "fallback_family", "ui_family")

# ── Waybar workspace focus indicator ──────────────────────────────────────
# How the ACTIVE tag is marked. GTK3 CSS has no `transform` (it is simply not a
# registered property) and every tag is its own GtkButton, so an indicator that
# SLIDES from tag to tag cannot exist here — each style below instead animates
# in place, using only GTK-animatable properties (color, text-shadow,
# background-size/-position, min-width, box-shadow, background-color).
BAR_WS_INDICATORS = {
    "glow":      "text glows in the accent — nothing moves (calmest)",
    "underline": "accent underline growing out from the centre",
    "pill":      "the tag widens into a soft accent pill, nudging its neighbours",
    "dot":       "a small accent dot rising from below the tag",
}


# ── Value shapes ──────────────────────────────────────────────────────────
# The role contract says WHICH keys a theme must set; this says what a value is
# allowed to BE. It is not politeness towards typos (though it catches those):
# every value here is interpolated verbatim into a config file, and
# config/hypr/theme.conf is `source`d by hyprland.conf. A colour carrying a
# newline would therefore append arbitrary Hyprland directives — `exec-once =
# <anything>` — and run them at login. A theme is data, not code; these checks
# are what keep that true, and what makes a theme from a stranger safe to render.
#
# Each checker returns None when the value is fine, else the complaint.
HEX_RE = re.compile(r"#[0-9a-fA-F]{6}")


def _renderable(value):
    """Anything written into a config file: no control characters."""
    if isinstance(value, str) and any(ord(ch) < 0x20 or ord(ch) == 0x7F for ch in value):
        return "must not contain control characters (a newline injects config directives)"
    return None


def _text(value):
    """A non-empty single-line string (a font family, a theme's name)."""
    if not isinstance(value, str):
        return "must be a string"
    if not value.strip():
        return "must not be empty"
    return _renderable(value)


# A value that lands in a config file's HEADER COMMENT (a theme's `name`) or in a
# QUOTED value (a font family) needs more than "no control characters". Colours
# and numbers are already inert everywhere — they match a fixed shape. These two
# are free-form strings, and the files they reach are not all forgiving: rofi
# .rasi and waybar/gtk .css use `/* … */` block comments and double-quoted values,
# so `*/` (or `/*`) ends a comment and `"` ends a value, after which the rest is
# read as live config. (Hyprland/kitty comment to end-of-line, so a newline — the
# one sequence that could inject an `exec-once` — is what matters there, and
# _renderable already bars it.) `;{}\` are structural in rasi/CSS too. Barring the
# set below is what keeps "a theme from a stranger is safe to render" true for
# rofi and waybar, not just for the compositor.
_UNSAFE_INLINE = ('"', ";", "{", "}", "\\", "*/", "/*")


def _inline(value):
    """A non-empty single-line string that stays inert wherever it is interpolated."""
    problem = _text(value)
    if problem:
        return problem
    for bad in _UNSAFE_INLINE:
        if bad in value:
            return f"must not contain {bad!r} (it would break out of a comment or a quoted value)"
    return None


def _colour(value):
    if not isinstance(value, str) or not HEX_RE.fullmatch(value):
        return "must be a #rrggbb colour"
    return None


def _colours(value):
    if not isinstance(value, list) or not value:
        return "must be a non-empty list of #rrggbb colours"
    for entry in value:
        if _colour(entry):
            return f"holds {entry!r}, which is not a #rrggbb colour"
    return None


def _boolean(value):
    return None if isinstance(value, bool) else "must be true or false"


def _number(low=None, high=None):
    def check(value):
        # bool is an int in Python — `blur_size = true` must not read as 1.
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return "must be a number"
        # TOML has literal inf/nan. They pass the bound checks (nan compares
        # False both ways; inf slips any unbounded param) and then either crash
        # the renderer on arithmetic or render the token 'inf' into a config —
        # a malicious theme turned into a desktop DoS.
        if isinstance(value, float) and not math.isfinite(value):
            return "must be a finite number"
        if low is not None and value < low:
            return f"must be >= {low}"
        if high is not None and value > high:
            return f"must be <= {high}"
        return None

    return check


def _one_of(allowed):
    def check(value):
        if value not in allowed:
            return f"must be one of: {', '.join(allowed)}"
        return None

    return check


# [params]. Unknown keys are deliberately absent from the check: a theme written
# for a newer HWE must degrade quietly, not explode. Templates use
# StrictUndefined, so a key nothing reads is simply never rendered.
PARAM_SPEC = {
    "rounding":         _number(0),
    "border_size":      _number(0),
    "gaps_in":          _number(0),
    "gaps_out":         _number(0),
    "blur_size":        _number(0),
    "blur_passes":      _number(0),
    "opacity":          _number(0, 1),
    "active_opacity":   _number(0, 1),
    "inactive_opacity": _number(0, 1),
    "border_gradient":  _colours,
    "border_angle":     _number(0, 360),
    "border_animate":   _number(0),
    "border_inactive":  _colour,
    "bar_height":       _number(1),
    "bar_float":        _boolean,
    "bar_gap":          _number(0),
    "bar_gap_x":        _number(0),
    "bar_radius":       _number(0),
    "bar_ws_indicator": _one_of(BAR_WS_INDICATORS),
    "bar_ws_speed":     _number(0),
    "bar_opacity":      _number(0, 1),  # bar backdrop alpha over the wallpaper
    "anim_speed":       _number(0),     # window-animation speed multiplier; 0 = off
    "scheme":           _one_of(("dark", "light")),  # light/dark preference (GTK, KDE)
    "icon_theme":       _inline,
    "cursor_theme":     _inline,
    "gtk_theme":        _inline,
    "font":             _inline,  # legacy family alias; [font].family supersedes it
}

# [font]: sizes are points (px for the bar). No upper bound — an absurd size is
# the author's business; a negative one is a bug.
FONT_SPEC = {
    **{key: _inline for key in FONT_FAMILY_KEYS},
    **{key: _number(0.1) for key in FONT_DEFAULTS if key not in FONT_FAMILY_KEYS},
}


def check_values(theme: dict) -> list[str]:
    """Return every malformed value in the theme ([] means all shapes are sound).

    Separate from validate(): a missing role is an incomplete theme (--lenient
    may force it through with the placeholder), while a malformed value is not
    theme data at all and is never rendered.
    """
    errors: list[str] = []

    def check(label, value, checker):
        problem = checker(value)
        if problem:
            # !r keeps a smuggled newline from breaking the error across lines.
            errors.append(f"{label} {problem} (got {value!r})")

    check("name", theme.get("name"), _inline)

    for role, value in sorted(theme.get("sem", {}).items()):
        # An absent role is validate()'s to report — don't say it twice.
        if value == "" or value is None:
            continue
        check(f"sem.{role}", value, _colour)

    for key, value in sorted(theme.get("params", {}).items()):
        if key in PARAM_SPEC:
            check(f"params.{key}", value, PARAM_SPEC[key])

    for key, value in sorted(theme.get("font", {}).items()):
        if key in FONT_SPEC:
            check(f"font.{key}", value, FONT_SPEC[key])

    # [palette] is the theme's private workbench — free-form by design and read
    # by no template. It still reaches the render context, so hold it to the one
    # rule that is about safety rather than shape.
    for key, value in sorted(theme.get("palette", {}).items()):
        check(f"palette.{key}", value, _renderable)

    return errors


def load_theme(path: Path) -> dict:
    with path.open("rb") as fh:
        data = tomllib.load(fh)
    data.setdefault("name", path.parent.name)
    data.setdefault("sem", {})
    data.setdefault("params", {})
    data.setdefault("font", {})
    return data


def validate(theme: dict) -> list[str]:
    """Return the list of missing roles ([] means the contract is satisfied)."""
    sem = theme.get("sem", {})
    missing = [r for r in REQUIRED_ROLES if not sem.get(r)]
    return missing


def _relative_luminance(hex_colour: str) -> float:
    """WCAG relative luminance of an #rrggbb colour (0.0 black .. 1.0 white).

    Used only to pick a legible ink for text drawn ON the accent (on_accent) —
    the same maths the contrast tests use, kept dependency-free here."""
    h = hex_colour.lstrip("#")
    try:
        channels = [int(h[i : i + 2], 16) / 255 for i in (0, 2, 4)]
    except (ValueError, IndexError):
        return 0.0

    def linear(c: float) -> float:
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4

    r, g, b = (linear(c) for c in channels)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def _contrast(a: str, b: str) -> float:
    la, lb = _relative_luminance(a), _relative_luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def _pick_on_accent(accent: str, bg_dark: str, fg_white: str) -> str:
    """Legible ink for text/glyphs on an ACCENT fill. Picks whichever of the two
    role extremes — bg_dark (the darkest surface) and fg_white (the max-contrast
    text) — reads better ON the accent. These two sit at opposite ends of the
    luminance range in EITHER scheme (in a light theme bg_dark is a pale grey and
    fg_white is near-black), so choosing by contrast, not by a fixed 'accent is
    dark → use white' rule, is what keeps this correct for light themes too."""
    return bg_dark if _contrast(accent, bg_dark) >= _contrast(accent, fg_white) else fg_white


def build_context(theme: dict, *, lenient: bool) -> dict:
    sem = dict(theme.get("sem", {}))
    for role in REQUIRED_ROLES:
        if not sem.get(role):
            sem[role] = UGLY if lenient else sem.get(role)
    # fill aliases from raw colours unless the theme set them explicitly
    for alias, source in ALIASES.items():
        sem.setdefault(alias, sem.get(source, UGLY))
    sem["transparent"] = "#00000000"

    # on_accent: legible ink for text/glyphs painted ON an accent fill (the pill
    # workspace chip, accent buttons). Auto-derived from the accent's luminance
    # so a theme never has to think about it, but a theme MAY pin it in [sem].
    # Not a REQUIRED role: every existing theme renders unchanged.
    sem.setdefault(
        "on_accent",
        _pick_on_accent(sem.get("accent", UGLY), sem.get("bg_dark", UGLY), sem.get("fg_white", UGLY)),
    )

    # Signature HWE animated border: the gradient angle rotates forever so colours
    # flow around the focused window. Themes only tune it; all shimmer unless a
    # theme sets border_animate = 0.
    # Typography contract: [font] merged over the nice defaults (the fallback).
    # Unknown keys are almost always typos — surface them loudly, don't swallow.
    font = dict(FONT_DEFAULTS)
    for key, val in theme.get("font", {}).items():
        if key not in FONT_DEFAULTS:
            sys.stderr.write(f"[theme] warning: unknown [font] key '{key}' (ignored)\n")
            continue
        font[key] = val

    params = dict(theme.get("params", {}))
    # Back-compat alias: a few templates historically read params.font (family).
    params["font"] = font["family"]
    params.setdefault("border_gradient", [sem.get("accent_soft", UGLY), sem.get("accent", UGLY)])
    params.setdefault("border_angle", 270)
    params.setdefault("border_animate", 100)   # ds per rotation; higher = quieter, 0 = static
    params.setdefault("border_inactive", sem.get("bg_lighter", UGLY))

    # Translucency, per-theme; defaults preserve historic HWE values. `opacity` is
    # base terminal (kitty) alpha; active/inactive apply to whole windows.
    params.setdefault("opacity", 0.94)
    # Derived so a theme tunes one knob (0.94 -> 0.90).
    params["opacity_unfocused"] = round(float(params["opacity"]) - 0.04, 4)
    # Default active/inactive to opacity so EVERY window (not just terminals) shows
    # blur through. A theme may pin them (void: active == inactive). Applied via a
    # global windowrule in hypr/theme.conf whose 3rd value forces fullscreen opaque.
    params.setdefault("active_opacity", params["opacity"])
    params.setdefault("inactive_opacity", params["opacity_unfocused"])

    # Window geometry, rendered into hypr/theme.conf (sourced after and overriding
    # appearance.conf). Defaults mirror that baseline so omitting them renders
    # unchanged and StrictUndefined never trips on a missing key.
    params.setdefault("border_size", 2)
    params.setdefault("rounding", 10)
    params.setdefault("gaps_in", 5)
    params.setdefault("gaps_out", 12)

    # Two independent knobs: blur_size = kernel radius per pass (strength),
    # blur_passes = passes stacked (quality, costlier). Drive window blur (theme.conf)
    # and the hyprlock background; defaults mirror appearance.conf.
    params.setdefault("blur_size", 6)
    params.setdefault("blur_passes", 3)

    # Waybar geometry — glued & flat by default. `bar_float = true` opts into the
    # floating "frosted island": edge gap via JSON margins (CSS margin on
    # window#waybar is unreliable, Waybar #1533) + rounding/border/shadow. The
    # numeric knobs only take effect while floating.
    params.setdefault("bar_height", 26)
    params.setdefault("bar_float", False)
    params.setdefault("bar_gap", 6)      # top gap when floating
    params.setdefault("bar_gap_x", 8)    # side gap when floating
    params.setdefault("bar_radius", 14)  # corner radius when floating

    # Waybar workspace focus indicator — see BAR_WS_INDICATORS. The whole
    # #workspaces block lives in the generated theme.css (style.css must not
    # restate it: style.css @imports theme.css, so its own rules would win).
    params.setdefault("bar_ws_indicator", "glow")
    if params["bar_ws_indicator"] not in BAR_WS_INDICATORS:
        sys.exit(
            f"[theme] '{theme['name']}': unknown bar_ws_indicator "
            f"'{params['bar_ws_indicator']}'\n[theme] expected one of: "
            + ", ".join(BAR_WS_INDICATORS)
        )
    params.setdefault("bar_ws_speed", 220)  # ms for the indicator to settle
    # Bar backdrop alpha over the wallpaper (the frosted-glass strength). Was a
    # literal 0.62 buried in style.css; now a theme knob rendered into theme.css.
    params.setdefault("bar_opacity", 0.62)

    # Desktop look-and-feel knobs that used to be hardcoded outside the theme:
    #   scheme        — light/dark preference handed to GTK (prefer-dark) and KDE.
    #   anim_speed    — a single multiplier over the window-animation durations in
    #                   the generated theme.conf; 1.0 = the historic feel, higher =
    #                   snappier, 0 = animations off. A quiet theme can slow down.
    #   *_theme       — icon / cursor / GTK theme names, previously pinned to
    #                   Adwaita in the templates. Defaults keep the current look.
    params.setdefault("scheme", "dark")
    params.setdefault("anim_speed", 1.0)
    params.setdefault("icon_theme", "Adwaita")
    params.setdefault("cursor_theme", "")   # "" = leave the system/Hyprland cursor
    params.setdefault("gtk_theme", "Adwaita")
    # Convenience flags for templates (StrictUndefined-friendly booleans).
    params["is_light"] = params["scheme"] == "light"
    params["prefer_dark"] = 0 if params["is_light"] else 1

    # Window-animation durations (deciseconds), scaled by anim_speed. The base
    # values mirror the historic appearance.conf set; anim_speed is a "faster"
    # knob (higher = shorter = snappier), and 0 turns animations off entirely
    # (params.anim = None → the template writes `enabled = 0`). Clamped to >= 1ds
    # because Hyprland rejects a zero-duration animation.
    _anim_base = {"windows": 5, "windowsIn": 5, "windowsOut": 4,
                  "windowsMove": 4, "border": 8, "fade": 6, "workspaces": 5}
    _speed = float(params["anim_speed"])
    params["anim"] = (
        {name: max(1, round(base / _speed)) for name, base in _anim_base.items()}
        if _speed > 0 else None
    )

    # Absolute path to the repo's scripts/ so generated configs (e.g. the waybar
    # cpu/ram/temp modules) can reference helper scripts wherever HWE lives.
    scripts_dir = str(Path(__file__).resolve().parent)

    # [palette] is the theme's private workbench and no template reads it, so it
    # is deliberately NOT put in the render context: injecting a free-form,
    # loosely-checked value that nothing uses only widens the surface. A future
    # template that wants it will fail loudly on StrictUndefined — the signal to
    # add it here AND tighten its check — rather than smuggle syntax silently.
    return {"name": theme["name"], "sem": sem, "params": params, "font": font,
            "scripts_dir": scripts_dir}


# ── Jinja filters for the various config colour syntaxes ───────────────────
def _noh(c: str) -> str:
    """'#cba6f7' -> 'cba6f7' (Hyprland rgb(), kitty, etc.)."""
    return str(c).lstrip("#")


def _rgb(c: str) -> str:
    """'#cba6f7' -> 'rgb(cba6f7)' (Hyprland)."""
    return f"rgb({_noh(c)})"


def _rgba(c: str, alpha: str = "ff") -> str:
    """'#cba6f7' -> 'rgba(cba6f7ff)' (Hyprland, alpha as 2 hex digits)."""
    return f"rgba({_noh(c)}{alpha})"


def _hexa(c: str, alpha: float = 1.0) -> str:
    """'#cba6f7', 0.93 -> '#cba6f7ed' (CSS #RRGGBBAA — rofi and other CSS-ish parsers).

    Distinct from `rgba`, which emits Hyprland's `rgba(cba6f7ed)` — same idea, wrong
    syntax for anything that speaks CSS.
    """
    a = max(0, min(255, round(float(alpha) * 255)))
    return f"#{_noh(c)}{a:02x}"


def _kcol(c: str) -> str:
    """'#cba6f7' -> '203,166,247' (KDE kdeglobals / KColorScheme r,g,b)."""
    h = _noh(c)
    return f"{int(h[0:2], 16)},{int(h[2:4], 16)},{int(h[4:6], 16)}"


def make_env(templates_dir: Path) -> Environment:
    try:
        from jinja2 import Environment, FileSystemLoader, StrictUndefined
    except ModuleNotFoundError:
        sys.exit("render-theme: missing dependency 'python-jinja' (pacman -S python-jinja)")
    env = Environment(
        loader=FileSystemLoader(str(templates_dir)),
        undefined=StrictUndefined,       # referencing an undefined var is an error
        keep_trailing_newline=True,
        autoescape=False,
    )
    env.filters["noh"] = _noh
    env.filters["rgb"] = _rgb
    env.filters["rgba"] = _rgba
    env.filters["hexa"] = _hexa
    env.filters["kcol"] = _kcol
    return env


def render_all(theme: dict, templates_dir: Path, out_dir: Path, *, lenient: bool) -> list[Path]:
    ctx = build_context(theme, lenient=lenient)
    env = make_env(templates_dir)
    written = []
    for tmpl_path in sorted(templates_dir.rglob("*.j2")):
        rel = tmpl_path.relative_to(templates_dir).with_suffix("")  # drop .j2
        dest = out_dir / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        rendered = env.get_template(str(tmpl_path.relative_to(templates_dir))).render(**ctx)
        dest.write_text(rendered)
        written.append(dest)
    return written


def main(argv: list[str]) -> int:
    args = [a for a in argv if not a.startswith("--")]
    check_only = "--check" in argv
    lenient = "--lenient" in argv
    if len(args) < 1:
        sys.exit(__doc__)

    theme_path = Path(args[0])
    theme = load_theme(theme_path)

    # Shape first: a malformed value is not theme data, so --lenient does not
    # forgive it and nothing gets rendered from it. Label by directory — the
    # theme's own `name` is one of the things in question here.
    label = theme_path.parent.name
    problems = check_values(theme)
    if problems:
        for problem in problems:
            sys.stderr.write(f"[theme] '{label}': {problem}\n")
        sys.stderr.write(
            f"[theme] refusing to render '{label}': a theme is data, and the value(s) "
            "above are not valid theme data\n"
        )
        return 2

    missing = validate(theme)
    if missing:
        sys.stderr.write(
            f"[theme] '{theme['name']}' is missing {len(missing)} role(s): "
            f"{', '.join(missing)}\n"
        )
        if not lenient:
            sys.stderr.write("[theme] refusing to render an incomplete theme (use --lenient to force)\n")
            return 2
    if check_only:
        if not missing:
            print(f"[theme] '{theme['name']}' satisfies the contract ({len(REQUIRED_ROLES)} roles)")
        return 2 if missing else 0

    templates_dir = Path(args[1])
    out_dir = Path(args[2])
    written = render_all(theme, templates_dir, out_dir, lenient=lenient)
    for p in written:
        print(f"[theme] rendered {p}")
    print(f"[theme] applied '{theme['name']}' -> {len(written)} file(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
