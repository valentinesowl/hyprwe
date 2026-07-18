"""Tests for the legibility of every shipped theme — the WCAG contrast floor.

A theme is data, and until now nothing held that data to a *readability* line:
render-theme.py checks a colour is a well-formed #rrggbb, never that you can see
it. A theme could satisfy the whole role contract and still paint dim text you
cannot read (ember's fg_dim once sat at 1.90:1, void's fg_normal at 2.98:1).

These tests are that missing line. They compute the WCAG 2.1 contrast ratio for
the role pairings that actually reach the screen as text/glyph, and hold every
shipped theme to a documented floor. The thresholds ARE the spec the palettes
are tuned against — loosen one only with a reason, in this file, on purpose.

The pairings mirror what the templates render:
  * fg_* on bg_normal      — body / bright / dim text on the base surface
  * accent on bg_dark      — the active workspace glyph (bar bg is bg_dark @ .62)
                             and the rofi prompt (bg_dark @ opacity); bg_dark is
                             the conservative opaque floor, ignoring the wallpaper
                             showing through, so passing here passes everywhere.
  * red / urgent on bg_normal — alert ink must stay legible, not just present.
"""
import tomllib

import pytest

from conftest import theme_ids, theme_paths

# ── The readability floor (WCAG 2.1 relative-luminance contrast ratio) ─────
# 4.5 = AA for body text; 3.0 = AA for large text and UI components. The bar
# glyphs, workspace numbers and rofi prompt are all "large" by WCAG's measure,
# so 3.0 is their honest floor; fg_normal is body text and earns the full 4.5.
FG_NORMAL_MIN = 4.5   # primary reading text (kitty fg, mako body, rofi entry)
# fg_bright is high-emphasis text; 6.0 sits between AA body (4.5) and AAA body
# (7.0). It is deliberately NOT 7.0: ember's signature is a MUTED dusty rose, and
# forcing AAA there would bleach the one thing that makes the theme itself. 6.0
# still guarantees fg_bright reads emphatically above fg_normal.
FG_BRIGHT_MIN = 6.0
FG_DIM_MIN = 3.0      # secondary text: inactive tags, placeholders, mako second line
ACCENT_ON_BAR_MIN = 3.0   # accent as a glyph on the bar / rofi prompt (over bg_dark)
ALERT_MIN = 3.0       # red / urgent must read as an alert, not a smudge


def _relative_luminance(hex_colour: str) -> float:
    """WCAG 2.1 relative luminance of an #rrggbb colour (0.0 black .. 1.0 white)."""
    h = hex_colour.lstrip("#")
    channels = (int(h[i : i + 2], 16) / 255 for i in (0, 2, 4))

    def linear(c: float) -> float:
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4

    r, g, b = (linear(c) for c in channels)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast_ratio(a: str, b: str) -> float:
    """WCAG contrast ratio between two colours, 1.0 (identical) .. 21.0 (b&w)."""
    la, lb = _relative_luminance(a), _relative_luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def _sem(theme_path) -> dict:
    """The [sem] table of a theme, straight from disk (no resolution needed —
    contrast is a property of the authored colours, not the derived params)."""
    with open(theme_path, "rb") as fh:
        return tomllib.load(fh)["sem"]


# ── The contrast helper itself, so a bug in it can't silently pass a theme ─
def test_contrast_of_black_on_white_is_the_wcag_maximum():
    assert contrast_ratio("#000000", "#ffffff") == pytest.approx(21.0, abs=0.01)


def test_contrast_is_symmetric():
    assert contrast_ratio("#123456", "#abcdef") == contrast_ratio("#abcdef", "#123456")


def test_identical_colours_have_no_contrast():
    assert contrast_ratio("#808080", "#808080") == pytest.approx(1.0)


# ── Every shipped theme must clear the floor ───────────────────────────────
@pytest.mark.parametrize("theme_path", theme_paths(), ids=theme_ids())
def test_body_text_is_legible(theme_path):
    sem = _sem(theme_path)
    ratio = contrast_ratio(sem["fg_normal"], sem["bg_normal"])
    assert ratio >= FG_NORMAL_MIN, (
        f"fg_normal on bg_normal is {ratio:.2f}:1, below the AA body floor "
        f"{FG_NORMAL_MIN} — primary text would be hard to read"
    )


@pytest.mark.parametrize("theme_path", theme_paths(), ids=theme_ids())
def test_bright_text_is_emphatic(theme_path):
    sem = _sem(theme_path)
    ratio = contrast_ratio(sem["fg_bright"], sem["bg_normal"])
    assert ratio >= FG_BRIGHT_MIN, (
        f"fg_bright on bg_normal is {ratio:.2f}:1, below {FG_BRIGHT_MIN}"
    )


@pytest.mark.parametrize("theme_path", theme_paths(), ids=theme_ids())
def test_dim_text_stays_readable(theme_path):
    sem = _sem(theme_path)
    ratio = contrast_ratio(sem["fg_dim"], sem["bg_normal"])
    assert ratio >= FG_DIM_MIN, (
        f"fg_dim on bg_normal is {ratio:.2f}:1, below the large-text/UI floor "
        f"{FG_DIM_MIN} — inactive tags and placeholders would vanish"
    )


@pytest.mark.parametrize("theme_path", theme_paths(), ids=theme_ids())
def test_accent_reads_as_a_glyph_on_the_bar(theme_path):
    sem = _sem(theme_path)
    ratio = contrast_ratio(sem["accent"], sem["bg_dark"])
    assert ratio >= ACCENT_ON_BAR_MIN, (
        f"accent on bg_dark is {ratio:.2f}:1, below {ACCENT_ON_BAR_MIN} — the "
        f"active workspace glyph and rofi prompt would be near-invisible"
    )


@pytest.mark.parametrize("theme_path", theme_paths(), ids=theme_ids())
@pytest.mark.parametrize("role", ["red", "urgent"])
def test_alert_ink_is_legible(theme_path, role):
    sem = _sem(theme_path)
    ratio = contrast_ratio(sem[role], sem["bg_normal"])
    assert ratio >= ALERT_MIN, (
        f"{role} on bg_normal is {ratio:.2f}:1, below {ALERT_MIN} — an alert "
        f"that dim does not alert"
    )
