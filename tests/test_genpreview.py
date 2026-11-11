"""Tests for the graphic identity preview generator."""
import shutil

import pytest

from conftest import theme_ids, theme_paths

magick_required = pytest.mark.skipif(not shutil.which("magick"), reason="ImageMagick not installed")


@pytest.fixture
def sem() -> dict:
    return {
        "accent": "#cba6f7",
        "accent_soft": "#b4befe",
        "on_accent": "#11111b",
        "bg_dark": "#11111b",
        "bg_normal": "#1e1e2e",
        "bg_light": "#313244",
        "bg_lighter": "#45475a",
        "border": "#45475a",
        "fg_white": "#ffffff",
        "fg_bright": "#cdd6f4",
        "fg_normal": "#a6adc8",
        "fg_dim": "#8b8fa2",
        "red": "#f38ba8",
        "orange": "#fab387",
        "yellow": "#f9e2af",
        "green": "#a6e3a1",
        "cyan": "#94e2d5",
        "blue": "#89b4fa",
        "magenta": "#f5c2e7",
    }


def preview_cmd(genpreview, sem, tmp_path, name="neon", display="Neon", size=(480, 480)):
    w, h = size
    return genpreview.build_cmd(
        name,
        sem,
        display,
        "DejaVu-Sans-Bold",
        tmp_path / "wallpaper.png",
        tmp_path / "preview.png",
        w,
        h,
    )


def test_rgba_emits_the_magick_dialect(genpreview):
    assert genpreview.rgba("#cba6f7", 0.5) == "rgba(203,166,247,0.5)"
    assert genpreview.rgba("cba6f7") == "rgba(203,166,247,1.0)"


def test_build_cmd_starts_at_magick_and_ends_at_the_output(genpreview, sem, tmp_path):
    cmd = preview_cmd(genpreview, sem, tmp_path)
    assert cmd[0] == "magick"
    assert cmd[-1] == str(tmp_path / "preview.png")
    assert cmd.count("(") == cmd.count(")")
    assert all(isinstance(argument, str) for argument in cmd)


def test_build_cmd_uses_palette_fallback_without_wallpaper(genpreview, sem, tmp_path):
    cmd = preview_cmd(genpreview, sem, tmp_path)
    assert "gradient:#1e1e2e-#11111b" in cmd
    assert "DejaVu-Sans-Bold" in cmd
    assert "Neon" in cmd
    assert str(tmp_path / "wallpaper.png") not in cmd
    assert "-annotate" in cmd


def test_build_cmd_softens_wallpaper_behind_identity(genpreview, sem, tmp_path):
    wall = tmp_path / "wallpaper.png"
    wall.write_bytes(b"\x89PNG\r\n\x1a\n")
    cmd = preview_cmd(genpreview, sem, tmp_path)
    assert cmd[1] == str(wall)
    assert "0x3" in cmd
    assert "78,90" in cmd
    assert "gradient:rgba(30,30,46,0.24)-rgba(17,17,27,0.42)" in cmd
    assert "Neon" in cmd


def test_every_shipped_motif_is_distinct(genpreview, sem):
    motifs = [genpreview.motif_layers(kind, sem) for kind in genpreview.MOTIFS.values()]
    assert len({repr(motif) for motif in motifs}) == len(genpreview.MOTIFS)


def test_custom_theme_falls_back_to_the_palette_orbit(genpreview, sem, tmp_path):
    cmd = preview_cmd(genpreview, sem, tmp_path, name="custom")
    assert "circle 220,164 220,77" in cmd


def test_long_display_names_use_a_smaller_title(genpreview, sem, tmp_path):
    cmd = preview_cmd(genpreview, sem, tmp_path, display="Catppuccin Mocha")
    assert cmd[cmd.index("-pointsize") + 1] == "34"


def test_build_cmd_scales_the_completed_card_and_strips_metadata(genpreview, sem, tmp_path):
    cmd = preview_cmd(genpreview, sem, tmp_path, size=(96, 96))
    assert "96x96!" in cmd
    assert "-strip" in cmd


def test_main_without_imagemagick_says_so(genpreview, monkeypatch, tmp_path):
    monkeypatch.setattr(genpreview.shutil, "which", lambda _: None)
    with pytest.raises(SystemExit) as exc:
        genpreview.main([str(tmp_path / "theme.toml"), str(tmp_path / "o.png")])
    assert "ImageMagick" in str(exc.value)


def test_main_needs_both_arguments(genpreview, tmp_path):
    with pytest.raises(SystemExit):
        genpreview.main([str(tmp_path / "theme.toml")])


def test_main_refuses_a_malformed_theme(genpreview, monkeypatch, tmp_path):
    monkeypatch.setattr(genpreview.shutil, "which", lambda _: "/usr/bin/magick")
    theme = tmp_path / "theme.toml"
    theme.write_text('name = "evil */ x /*"\n[sem]\naccent = "#ff0000"\n')
    with pytest.raises(SystemExit) as exc:
        genpreview.main([str(theme), str(tmp_path / "o.png")])
    assert "malformed theme" in str(exc.value)


@pytest.mark.parametrize(
    "toml_line",
    [
        'name = "@/etc/passwd"',
        'tagline = "@/etc/passwd"',
        'tagline = "100%w wide"',
        'tagline = "line one\\nexec"',
    ],
)
def test_main_refuses_an_imagemagick_metacharacter(genpreview, monkeypatch, tmp_path, toml_line):
    monkeypatch.setattr(genpreview.shutil, "which", lambda _: "/usr/bin/magick")
    theme = tmp_path / "theme.toml"
    theme.write_text(f'{toml_line}\n[sem]\naccent = "#ff0000"\n')
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


@magick_required
@pytest.mark.slow
def test_generation_is_byte_deterministic(genpreview, tmp_path):
    theme = theme_paths()[0]
    first, second = tmp_path / "first.png", tmp_path / "second.png"
    genpreview.main([str(theme), str(first), "--size", "96x96"])
    genpreview.main([str(theme), str(second), "--size", "96x96"])
    assert first.read_bytes() == second.read_bytes()
