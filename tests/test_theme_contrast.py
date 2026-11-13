"""WCAG contrast checks for the semantic roles used by every shipped theme.

Small text needs 4.5:1. The 3:1 floor is reserved for large text and meaningful
non-text UI, never for the 12px bar or secondary labels. The bar is tested after
alpha compositing over black, white and a mid-grey wallpaper, not just against
its authored background colour.
"""
import tomllib

import pytest

from conftest import theme_ids, theme_paths

TEXT_MIN = 4.5
FG_BRIGHT_MIN = 6.0
UI_MIN = 3.0
CONTROL_WALLPAPERS = ("#000000", "#ffffff", "#808080")


def _relative_luminance(hex_colour: str) -> float:
    h = hex_colour.lstrip("#")
    channels = (int(h[i : i + 2], 16) / 255 for i in (0, 2, 4))

    def linear(c: float) -> float:
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4

    r, g, b = (linear(c) for c in channels)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast_ratio(a: str, b: str) -> float:
    la, lb = _relative_luminance(a), _relative_luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def composite(foreground: str, background: str, alpha: float) -> str:
    channels = [
        round(int(foreground[i : i + 2], 16) * alpha + int(background[i : i + 2], 16) * (1 - alpha))
        for i in (1, 3, 5)
    ]
    return "#" + "".join(f"{channel:02x}" for channel in channels)


def _theme(theme_path) -> dict:
    with open(theme_path, "rb") as fh:
        return tomllib.load(fh)


def _sem(theme_path) -> dict:
    return _theme(theme_path)["sem"]


def _light_theme_paths() -> list:
    return [
        path for path in theme_paths()
        if _theme(path).get("params", {}).get("scheme") == "light"
    ]


def _context(theme_path, render_theme) -> dict:
    return render_theme.build_context(_theme(theme_path), lenient=False)


def test_contrast_of_black_on_white_is_the_wcag_maximum():
    assert contrast_ratio("#000000", "#ffffff") == pytest.approx(21.0, abs=0.01)


def test_contrast_is_symmetric():
    assert contrast_ratio("#123456", "#abcdef") == contrast_ratio("#abcdef", "#123456")


def test_identical_colours_have_no_contrast():
    assert contrast_ratio("#808080", "#808080") == pytest.approx(1.0)


def test_composite_over_white_uses_both_colours():
    assert composite("#000000", "#ffffff", 0.5) == "#808080"


@pytest.mark.parametrize("theme_path", theme_paths(), ids=theme_ids())
@pytest.mark.parametrize("role", ["fg_normal", "fg_dim"])
def test_small_text_is_legible_on_the_base_surface(theme_path, role):
    sem = _sem(theme_path)
    ratio = contrast_ratio(sem[role], sem["bg_normal"])
    assert ratio >= TEXT_MIN, f"{role} on bg_normal is {ratio:.2f}:1, below {TEXT_MIN}"


@pytest.mark.parametrize("theme_path", theme_paths(), ids=theme_ids())
def test_bright_text_is_emphatic(theme_path):
    sem = _sem(theme_path)
    ratio = contrast_ratio(sem["fg_bright"], sem["bg_normal"])
    assert ratio >= FG_BRIGHT_MIN, f"fg_bright on bg_normal is {ratio:.2f}:1, below {FG_BRIGHT_MIN}"


@pytest.mark.parametrize("theme_path", theme_paths(), ids=theme_ids())
@pytest.mark.parametrize("surface", ["bg_dark", "bg_normal"])
def test_accent_small_text_is_legible(theme_path, surface):
    sem = _sem(theme_path)
    ratio = contrast_ratio(sem["accent"], sem[surface])
    assert ratio >= TEXT_MIN, f"accent on {surface} is {ratio:.2f}:1, below {TEXT_MIN}"


@pytest.mark.parametrize("theme_path", theme_paths(), ids=theme_ids())
@pytest.mark.parametrize("role", ["red", "urgent"])
def test_alert_small_text_is_legible(theme_path, role):
    sem = _sem(theme_path)
    ratio = contrast_ratio(sem[role], sem["bg_normal"])
    assert ratio >= TEXT_MIN, f"{role} on bg_normal is {ratio:.2f}:1, below {TEXT_MIN}"


@pytest.mark.parametrize("theme_path", theme_paths(), ids=theme_ids())
@pytest.mark.parametrize("role", ["accent", "urgent"])
def test_selected_rows_have_legible_ink(theme_path, role, render_theme):
    sem = _context(theme_path, render_theme)["sem"]
    ink = sem[f"on_{role}"]
    ratio = contrast_ratio(ink, sem[role])
    assert ratio >= TEXT_MIN, f"{ink} on {role} is {ratio:.2f}:1, below {TEXT_MIN}"


@pytest.mark.parametrize("theme_path", theme_paths(), ids=theme_ids())
@pytest.mark.parametrize("role", ["fg_normal", "fg_dim", "accent", "orange"])
@pytest.mark.parametrize("wallpaper", CONTROL_WALLPAPERS)
def test_bar_text_survives_compositing(theme_path, role, wallpaper):
    theme = _theme(theme_path)
    sem = theme["sem"]
    alpha = theme.get("params", {}).get("bar_opacity", 0.94)
    actual_background = composite(sem["bg_dark"], wallpaper, alpha)
    ratio = contrast_ratio(sem[role], actual_background)
    assert ratio >= TEXT_MIN, (
        f"{role} on the bar over {wallpaper} is {ratio:.2f}:1 "
        f"(alpha={alpha}, composite={actual_background}), below {TEXT_MIN}"
    )


@pytest.mark.parametrize("theme_path", _light_theme_paths(), ids=lambda path: path.parent.name)
def test_light_theme_terminal_colours_are_legible(theme_path):
    sem = _sem(theme_path)
    for role in ("red", "green", "yellow", "orange", "blue", "magenta", "cyan"):
        ratio = contrast_ratio(sem[role], sem["bg_normal"])
        assert ratio >= TEXT_MIN, f"{role} on the terminal is {ratio:.2f}:1, below {TEXT_MIN}"


@pytest.mark.parametrize("theme_path", _light_theme_paths(), ids=lambda path: path.parent.name)
def test_light_theme_soft_accent_text_is_legible(theme_path):
    sem = _sem(theme_path)
    backgrounds = [sem["bg_normal"], sem["bg_dark"]]
    backgrounds += [composite(sem["bg_dark"], wallpaper, 0.96) for wallpaper in CONTROL_WALLPAPERS]
    for background in backgrounds:
        ratio = contrast_ratio(sem["accent_soft"], background)
        assert ratio >= TEXT_MIN, (
            f"accent_soft on {background} is {ratio:.2f}:1, below {TEXT_MIN}"
        )


@pytest.mark.parametrize("theme_path", _light_theme_paths(), ids=lambda path: path.parent.name)
def test_light_tray_chip_has_legible_symbolic_icon_ink(theme_path, render_theme):
    sem = _context(theme_path, render_theme)["sem"]
    ratio = contrast_ratio(sem["on_accent"], sem["accent"])
    assert ratio >= TEXT_MIN, f"tray icon contrast is {ratio:.2f}:1, below {TEXT_MIN}"


@pytest.mark.parametrize("theme_path", theme_paths(), ids=theme_ids())
@pytest.mark.parametrize("role", ["accent", "urgent"])
def test_meaningful_nontext_ui_clears_the_component_floor(theme_path, role):
    sem = _sem(theme_path)
    ratio = contrast_ratio(sem[role], sem["bg_normal"])
    assert ratio >= UI_MIN, f"{role} UI on bg_normal is {ratio:.2f}:1, below {UI_MIN}"
