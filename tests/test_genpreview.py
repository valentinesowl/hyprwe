"""Tests for scripts/genpreview.py — the theme preview card generator.

genpreview builds an ImageMagick argv rather than pixels, so most of what can go
wrong is in that list: an unbalanced layer group, a colour spelled in a syntax
magick won't parse, a decor key left behind after a theme rename. Those are all
checkable without invoking magick — and the one end-to-end test that does invoke
it skips cleanly where ImageMagick isn't installed.
"""
import shutil
import subprocess

import pytest

from conftest import theme_ids, theme_paths

DECOR_KINDS = ["glow", "particles", "sparks", "leaves", "scanlines"]

magick_required = pytest.mark.skipif(
    not shutil.which("magick"), reason="ImageMagick not installed"
)


@pytest.fixture
def sem() -> dict:
    return {
        "accent": "#cba6f7",
        "bg_dark": "#11111b",
        "bg_normal": "#1e1e2e",
        "fg_white": "#ffffff",
        "yellow": "#f9e2af",
    }


# ── colour syntax ─────────────────────────────────────────────────────────
def test_rgba_emits_the_magick_dialect(genpreview):
    assert genpreview.rgba("#cba6f7", 0.5) == "rgba(203,166,247,0.5)"


def test_rgba_accepts_a_bare_hex(genpreview):
    assert genpreview.rgba("cba6f7", 1.0) == "rgba(203,166,247,1.0)"


def test_rgba_spans_the_byte_range(genpreview):
    assert genpreview.rgba("#000000", 0) == "rgba(0,0,0,0)"
    assert genpreview.rgba("#ffffff", 1) == "rgba(255,255,255,1)"


# ── the per-theme decor layers ────────────────────────────────────────────
def test_no_decor_adds_no_layer(genpreview, sem):
    assert genpreview.decor_layer("none", sem, 480, 480) == []


def test_an_unknown_decor_kind_is_ignored_rather_than_fatal(genpreview, sem):
    assert genpreview.decor_layer("hologram", sem, 480, 480) == []


@pytest.mark.parametrize("kind", DECOR_KINDS)
def test_decor_layer_is_a_balanced_magick_group(genpreview, sem, kind):
    """An unbalanced ( ) group makes magick misread the whole rest of the argv."""
    layer = genpreview.decor_layer(kind, sem, 480, 480)
    assert layer, f"{kind} produced no layer"
    assert layer.count("(") == layer.count(")"), f"{kind}: unbalanced parens"
    assert layer[0] == "("


@pytest.mark.parametrize("kind", DECOR_KINDS)
def test_decor_layer_composites_itself_onto_the_card(genpreview, sem, kind):
    layer = genpreview.decor_layer(kind, sem, 480, 480)
    assert layer[-1] == "-composite", f"{kind}: layer is built but never composited"


@pytest.mark.parametrize("kind", DECOR_KINDS)
def test_decor_layer_is_every_argument_a_string(genpreview, sem, kind):
    """subprocess wants str; a stray int here is a TypeError at generation time."""
    assert all(isinstance(a, str) for a in genpreview.decor_layer(kind, sem, 480, 480))


@pytest.mark.parametrize("kind", ["glow", "sparks", "leaves"])
def test_accent_driven_decor_uses_the_themes_accent(genpreview, sem, kind):
    """Decor must come from [sem], never a per-theme hardcoded colour."""
    layer = genpreview.decor_layer(kind, sem, 480, 480)
    assert any("203,166,247" in a for a in layer)


def test_decor_scales_with_the_card_size(genpreview, sem):
    small = genpreview.decor_layer("glow", sem, 100, 100)
    large = genpreview.decor_layer("glow", sem, 480, 480)
    assert "100x100" in small and "480x480" in large


# ── the assembled command ─────────────────────────────────────────────────
def test_build_cmd_starts_at_magick_and_ends_at_the_output(genpreview, sem, tmp_path):
    out = tmp_path / "preview.png"
    cmd = genpreview.build_cmd(
        "mocha", sem, "Mocha", "Cozy", tmp_path / "missing.png", "Font", out, 480, 480
    )
    assert cmd[0] == "magick"
    assert cmd[-1] == str(out)


def test_build_cmd_is_balanced_overall(genpreview, sem, tmp_path):
    cmd = genpreview.build_cmd(
        "mocha", sem, "Mocha", "Cozy", tmp_path / "missing.png", "Font", tmp_path / "o.png",
        480, 480,
    )
    assert cmd.count("(") == cmd.count(")")


def test_build_cmd_uses_the_wallpaper_when_there_is_one(genpreview, sem, tmp_path):
    wall = tmp_path / "wallpaper.png"
    wall.write_bytes(b"\x89PNG\r\n\x1a\n")
    cmd = genpreview.build_cmd(
        "mocha", sem, "Mocha", "Cozy", wall, "Font", tmp_path / "o.png", 480, 480
    )
    assert str(wall) in cmd
    # centre-cropped to fill the square tile, not letterboxed
    assert "480x480^" in cmd


def test_build_cmd_falls_back_to_a_gradient_without_a_wallpaper(genpreview, sem, tmp_path):
    cmd = genpreview.build_cmd(
        "mocha", sem, "Mocha", "Cozy", tmp_path / "missing.png", "Font", tmp_path / "o.png",
        480, 480,
    )
    assert any(a.startswith("gradient:") for a in cmd)


def test_build_cmd_renders_the_name_and_tagline(genpreview, sem, tmp_path):
    cmd = genpreview.build_cmd(
        "mocha", sem, "Mocha Display", "Cozy · Catppuccin", tmp_path / "m.png", "Font",
        tmp_path / "o.png", 480, 480,
    )
    assert "Mocha Display" in cmd
    assert "Cozy · Catppuccin" in cmd


def test_build_cmd_omits_the_tagline_layer_when_there_is_none(genpreview, sem, tmp_path):
    with_tag = genpreview.build_cmd(
        "mocha", sem, "Mocha", "Cozy", tmp_path / "m.png", "Font", tmp_path / "o.png", 480, 480
    )
    without = genpreview.build_cmd(
        "mocha", sem, "Mocha", "", tmp_path / "m.png", "Font", tmp_path / "o.png", 480, 480
    )
    assert len(without) < len(with_tag)


def test_build_cmd_arguments_are_all_strings(genpreview, sem, tmp_path):
    cmd = genpreview.build_cmd(
        "ember", sem, "Ember", "Warm", tmp_path / "m.png", "Font", tmp_path / "o.png", 480, 480
    )
    assert all(isinstance(a, str) for a in cmd)


def test_build_cmd_applies_the_themes_decor(genpreview, sem, tmp_path):
    """The card for a decorated theme must differ from an undecorated one."""
    plain = genpreview.build_cmd(
        "default", sem, "D", "", tmp_path / "m.png", "Font", tmp_path / "o.png", 480, 480
    )
    decorated = genpreview.build_cmd(
        "void", sem, "V", "", tmp_path / "m.png", "Font", tmp_path / "o.png", 480, 480
    )
    assert len(decorated) > len(plain)


# ── font resolution ───────────────────────────────────────────────────────
def test_resolve_font_returns_a_usable_name(genpreview):
    font = genpreview.resolve_font()
    assert isinstance(font, str) and font


def test_resolve_font_falls_back_when_fc_match_is_absent(genpreview, monkeypatch):
    """A box without fontconfig must still render a card, not traceback."""
    def boom(*_a, **_kw):
        raise OSError("fc-match not found")

    monkeypatch.setattr(genpreview.subprocess, "run", boom)
    assert genpreview.resolve_font() == "DejaVu-Sans-Bold"


def test_resolve_font_falls_back_when_fc_match_fails(genpreview, monkeypatch):
    def boom(*_a, **_kw):
        raise subprocess.CalledProcessError(1, "fc-match")

    monkeypatch.setattr(genpreview.subprocess, "run", boom)
    assert genpreview.resolve_font() == "DejaVu-Sans-Bold"


# ── the per-theme tables stay in step with the themes ─────────────────────
def test_every_tagline_key_names_a_real_theme(genpreview):
    """Catches a table entry left behind after a theme is renamed or dropped."""
    names = set(theme_ids())
    assert set(genpreview.TAGLINES) <= names, (
        f"stale TAGLINES keys: {sorted(set(genpreview.TAGLINES) - names)}"
    )


def test_every_decor_key_names_a_real_theme(genpreview):
    names = set(theme_ids())
    assert set(genpreview.DECOR) <= names, (
        f"stale DECOR keys: {sorted(set(genpreview.DECOR) - names)}"
    )


def test_every_decor_value_is_a_kind_that_draws_something(genpreview):
    assert set(genpreview.DECOR.values()) <= set(DECOR_KINDS)


@pytest.mark.parametrize("theme_path", theme_paths(), ids=theme_ids())
def test_every_shipped_theme_has_a_tagline(genpreview, theme_path):
    """The card's subtitle — an untagged theme renders a blank line."""
    import tomllib

    with theme_path.open("rb") as fh:
        declared = tomllib.load(fh).get("tagline")
    assert declared or genpreview.TAGLINES.get(theme_path.parent.name), (
        f"{theme_path.parent.name}: no tagline in theme.toml nor in TAGLINES"
    )


# ── end to end ────────────────────────────────────────────────────────────
def test_main_without_imagemagick_says_so(genpreview, monkeypatch, tmp_path):
    monkeypatch.setattr(genpreview.shutil, "which", lambda _: None)
    with pytest.raises(SystemExit) as exc:
        genpreview.main([str(tmp_path / "theme.toml"), str(tmp_path / "o.png")])
    assert "ImageMagick" in str(exc.value)


def test_main_needs_both_arguments(genpreview, tmp_path):
    with pytest.raises(SystemExit):
        genpreview.main([str(tmp_path / "theme.toml")])


def test_main_refuses_a_malformed_theme(genpreview, monkeypatch, tmp_path):
    """genpreview reuses render-theme's value gate — a value that isn't theme data
    is refused before any of it reaches an ImageMagick argument. (magick is faked
    present so the refusal, not a missing-dependency exit, is what we observe.)"""
    monkeypatch.setattr(genpreview.shutil, "which", lambda _: "/usr/bin/magick")
    theme = tmp_path / "theme.toml"
    theme.write_text('name = "evil */ x /*"\n[sem]\naccent = "#ff0000"\n')
    with pytest.raises(SystemExit) as exc:
        genpreview.main([str(theme), str(tmp_path / "o.png")])
    assert "malformed theme" in str(exc.value)


@magick_required
@pytest.mark.slow
@pytest.mark.parametrize("theme_path", theme_paths(), ids=theme_ids())
def test_every_shipped_theme_renders_a_card(genpreview, theme_path, tmp_path):
    out = tmp_path / "preview.png"
    assert genpreview.main([str(theme_path), str(out), "--size", "96x96"]) == 0
    assert out.read_bytes()[:8] == b"\x89PNG\r\n\x1a\n"
