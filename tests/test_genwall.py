"""Tests for scripts/genwall.py — the procedural wallpaper generator.

genwall is a maintainer tool whose *outputs* are committed, which is exactly why
determinism is a correctness property here and not a nicety: if a given theme
stops producing byte-identical pixels, `just walls` silently dirties the working
tree on every run. The rest is the maths — clamping, ranges, the hand-rolled PNG
encoder — where a mistake yields a plausible-looking but wrong image.
"""
import struct
import zlib

import numpy as np
import pytest

from conftest import theme_ids, theme_paths

STYLES = ["mesh", "aurora", "voronoi", "grid", "signal", "skyline"]


@pytest.fixture
def small_grid(genwall):
    """A tiny canvas — the maths is size-independent, so tests need not be 4K."""
    return genwall.Grid(64, 36)


# ── colour helpers ────────────────────────────────────────────────────────
def test_hexrgb_parses_with_and_without_the_hash(genwall):
    assert np.array_equal(genwall.hexrgb("#1e1e2e"), np.array([30, 30, 46], dtype=np.float32))
    assert np.array_equal(genwall.hexrgb("1e1e2e"), np.array([30, 30, 46], dtype=np.float32))


def test_hexrgb_spans_the_full_byte_range(genwall):
    assert np.array_equal(genwall.hexrgb("#000000"), np.zeros(3, dtype=np.float32))
    assert np.array_equal(genwall.hexrgb("#ffffff"), np.full(3, 255, dtype=np.float32))


def test_hexrgb_keeps_channels_in_order(genwall):
    assert np.array_equal(genwall.hexrgb("#ff0000"), np.array([255, 0, 0], dtype=np.float32))
    assert np.array_equal(genwall.hexrgb("#0000ff"), np.array([0, 0, 255], dtype=np.float32))


def test_mix_lerps_between_two_colours(genwall):
    a = np.zeros((2, 2, 3), dtype=np.float32)
    b = np.full((2, 2, 3), 100.0, dtype=np.float32)
    out = genwall.mix(a, b, np.full((2, 2), 0.25, dtype=np.float32))
    assert np.allclose(out, 25.0)


def test_mix_endpoints_are_exact(genwall):
    a = np.zeros((2, 2, 3), dtype=np.float32)
    b = np.full((2, 2, 3), 255.0, dtype=np.float32)
    assert np.allclose(genwall.mix(a, b, np.zeros((2, 2), dtype=np.float32)), a)
    assert np.allclose(genwall.mix(a, b, np.ones((2, 2), dtype=np.float32)), b)


def test_smoothstep_is_bounded_and_has_flat_ends(genwall):
    t = np.linspace(-1.0, 2.0, 50, dtype=np.float32)
    out = genwall.smoothstep(t)
    assert out.min() == 0.0 and out.max() == 1.0
    assert genwall.smoothstep(np.float32(0.5)) == pytest.approx(0.5)


def test_smoothstep_is_monotonic(genwall):
    out = genwall.smoothstep(np.linspace(0.0, 1.0, 50, dtype=np.float32))
    assert np.all(np.diff(out) >= 0)


def test_ramp_hits_its_stops_and_clamps_outside(genwall):
    black, white = genwall.hexrgb("#000000"), genwall.hexrgb("#ffffff")
    stops = [(0.0, black), (1.0, white)]
    out = genwall.ramp(np.array([-1.0, 0.0, 0.5, 1.0, 2.0], dtype=np.float32), stops)
    assert np.allclose(out[0], 0.0) and np.allclose(out[1], 0.0)   # clamped low
    assert np.allclose(out[2], 127.5)
    assert np.allclose(out[3], 255.0) and np.allclose(out[4], 255.0)  # clamped high


def test_stretch_rescales_a_field_to_span_zero_to_one(genwall):
    a = np.array([2.0, 3.0, 4.0], dtype=np.float32)
    out = genwall.stretch(a)
    assert out.min() == pytest.approx(0.0) and out.max() == pytest.approx(1.0)
    assert out[1] == pytest.approx(0.5)


def test_stretch_of_a_constant_field_is_zero_not_a_nan(genwall):
    """A flat field would divide by zero; the guard is what keeps the PNG clean."""
    out = genwall.stretch(np.full(5, 7.0, dtype=np.float32))
    assert np.all(out == 0.0) and not np.any(np.isnan(out))


# ── the grid ──────────────────────────────────────────────────────────────
def test_grid_uv_spans_the_unit_square(small_grid):
    assert small_grid.u.min() == pytest.approx(0.0)
    assert small_grid.u.max() == pytest.approx(1.0)
    assert small_grid.v.min() == pytest.approx(0.0)
    assert small_grid.v.max() == pytest.approx(1.0)


def test_grid_x_is_aspect_corrected_so_circles_stay_round(small_grid):
    """x = u * aspect is what stops every glow rendering as an ellipse."""
    assert small_grid.aspect == pytest.approx(64 / 36)
    assert small_grid.x.max() == pytest.approx(small_grid.aspect)
    assert small_grid.y.max() == pytest.approx(1.0)


def test_grid_fields_have_the_canvas_shape(small_grid):
    assert small_grid.u.shape == (36, 64)
    assert small_grid.x.shape == (36, 64)


# ── palette resolution ────────────────────────────────────────────────────
def test_palette_reads_the_declared_roles(genwall):
    pal = genwall._palette({"accent": "#ff0000"})
    assert np.array_equal(pal["accent"], genwall.hexrgb("#ff0000"))


def test_palette_falls_back_to_accent_when_soft_is_absent(genwall):
    """A theme omitting accent_soft must stay monochrome, not go Catppuccin-blue."""
    pal = genwall._palette({"accent": "#ff0000"})
    assert np.array_equal(pal["accent_soft"], genwall.hexrgb("#ff0000"))


def test_palette_keeps_an_explicit_accent_soft(genwall):
    pal = genwall._palette({"accent": "#ff0000", "accent_soft": "#00ff00"})
    assert np.array_equal(pal["accent_soft"], genwall.hexrgb("#00ff00"))


def test_palette_supplies_every_role_the_styles_read(genwall):
    """An empty [sem] must still yield a complete palette — styles index it blind."""
    pal = genwall._palette({})
    assert set(pal) == set(genwall._ROLES)


# ── theme input ───────────────────────────────────────────────────────────
def _write_theme(tmp_path, body: str):
    path = tmp_path / "theme.toml"
    path.write_text(body)
    return path


def test_read_theme_defaults_to_mesh_at_full_intensity(genwall, tmp_path):
    path = _write_theme(tmp_path, 'name = "t"\n[sem]\naccent = "#ff0000"\n')
    _pal, style, _seed, k = genwall.read_theme(path)
    assert style == "mesh" and k == 1.0


def test_read_theme_reads_the_wallpaper_block(genwall, tmp_path):
    path = _write_theme(
        tmp_path,
        'name = "t"\n[sem]\naccent = "#ff0000"\n'
        '[wallpaper]\nstyle = "aurora"\nseed = 42\nintensity = 0.5\n',
    )
    _pal, style, seed, k = genwall.read_theme(path)
    assert (style, seed, k) == ("aurora", 42, 0.5)


def test_read_theme_rejects_an_unknown_style(genwall, tmp_path):
    path = _write_theme(tmp_path, 'name = "t"\n[wallpaper]\nstyle = "plaid"\n')
    with pytest.raises(SystemExit) as exc:
        genwall.read_theme(path)
    assert "unknown wallpaper style" in str(exc.value)


def test_read_theme_refuses_a_malformed_value(genwall, tmp_path):
    """genwall reuses render-theme's value gate: a value that isn't theme data —
    here a name that would break out of a generated file's comment — is refused
    on the maintainer's box, before it can reach a committed wallpaper's inputs."""
    path = _write_theme(tmp_path, 'name = "evil */ x /*"\n[sem]\naccent = "#ff0000"\n')
    with pytest.raises(SystemExit) as exc:
        genwall.read_theme(path)
    assert "malformed theme" in str(exc.value)


def test_read_theme_refuses_a_non_hex_colour(genwall, tmp_path):
    """The same gate turns a bad colour into a clear refusal rather than a raw
    ValueError deep inside hexrgb()."""
    path = _write_theme(tmp_path, 'name = "t"\n[sem]\naccent = "not-a-colour"\n')
    with pytest.raises(SystemExit) as exc:
        genwall.read_theme(path)
    assert "malformed theme" in str(exc.value)


def test_seed_derives_from_the_theme_name_stably(genwall, tmp_path):
    """crc32, never hash(): hash() is salted per process and would reroll the
    wallpaper on every run, dirtying the tree."""
    path = _write_theme(tmp_path, 'name = "stable"\n[sem]\naccent = "#ff0000"\n')
    seeds = {genwall.read_theme(path)[2] for _ in range(3)}
    assert seeds == {zlib.crc32(b"stable")}


def test_different_theme_names_get_different_compositions(genwall, tmp_path):
    (tmp_path / "a").mkdir()
    (tmp_path / "b").mkdir()
    alpha = _write_theme(tmp_path / "a", 'name = "alpha"\n[sem]\naccent = "#ff0000"\n')
    beta = _write_theme(tmp_path / "b", 'name = "beta"\n[sem]\naccent = "#ff0000"\n')
    assert genwall.read_theme(alpha)[2] != genwall.read_theme(beta)[2]


def test_seed_falls_back_to_the_directory_when_a_theme_is_unnamed(genwall, tmp_path):
    theme_dir = tmp_path / "anonymous"
    theme_dir.mkdir()
    path = _write_theme(theme_dir, '[sem]\naccent = "#ff0000"\n')
    assert genwall.read_theme(path)[2] == zlib.crc32(b"anonymous")


# ── the PNG encoder (hand-rolled — no Pillow dependency) ──────────────────
def _parse_png(blob: bytes):
    """Minimal PNG reader: returns (width, height, chunk_tags, pixel_bytes)."""
    assert blob[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG signature"
    pos, tags, idat, w, h = 8, [], b"", None, None
    while pos < len(blob):
        (length,) = struct.unpack(">I", blob[pos : pos + 4])
        tag = blob[pos + 4 : pos + 8]
        data = blob[pos + 8 : pos + 8 + length]
        crc = struct.unpack(">I", blob[pos + 8 + length : pos + 12 + length])[0]
        assert crc == zlib.crc32(tag + data) & 0xFFFFFFFF, f"bad CRC on {tag!r}"
        tags.append(tag)
        if tag == b"IHDR":
            w, h = struct.unpack(">II", data[:8])
        elif tag == b"IDAT":
            idat += data
        pos += 12 + length
    return w, h, tags, zlib.decompress(idat)


def test_to_png_writes_a_structurally_valid_png(genwall, small_grid):
    img = np.zeros((36, 64, 3), dtype=np.float32)
    w, h, tags, raw = _parse_png(genwall.to_png(img, small_grid))
    assert (w, h) == (64, 36)
    assert tags == [b"IHDR", b"IDAT", b"IEND"]
    # Each scanline is a filter byte + w RGB triples.
    assert len(raw) == 36 * (1 + 64 * 3)


def test_to_png_scanline_filters_are_all_none(genwall, small_grid):
    img = np.zeros((36, 64, 3), dtype=np.float32)
    _w, _h, _tags, raw = _parse_png(genwall.to_png(img, small_grid))
    stride = 1 + 64 * 3
    assert all(raw[row * stride] == 0 for row in range(36))


def test_to_png_clamps_out_of_range_values(genwall, small_grid):
    """Styles composite additively and can overshoot; clamping is what keeps
    an over-bright glow from wrapping around to black."""
    img = np.full((36, 64, 3), 400.0, dtype=np.float32)
    _w, _h, _tags, raw = _parse_png(genwall.to_png(img, small_grid))
    assert max(raw[1:97]) == 255

    img = np.full((36, 64, 3), -50.0, dtype=np.float32)
    _w, _h, _tags, raw = _parse_png(genwall.to_png(img, small_grid))
    assert min(raw[1:97]) == 0


def test_to_png_dithers_a_flat_field(genwall, small_grid):
    """The Bayer dither is what stops a smooth gradient from banding."""
    img = np.full((36, 64, 3), 127.3, dtype=np.float32)
    _w, _h, _tags, raw = _parse_png(genwall.to_png(img, small_grid))
    stride = 1 + 64 * 3
    row = [raw[1 + i] for i in range(stride - 1)]
    assert len(set(row)) > 1, "a flat field came out perfectly flat — dither is not applied"


# ── the styles ────────────────────────────────────────────────────────────
def test_every_documented_style_is_registered(genwall):
    assert sorted(genwall.STYLES) == sorted(STYLES)


@pytest.mark.parametrize("style", STYLES)
def test_style_renders_in_range_pixels(genwall, small_grid, style):
    rng = np.random.default_rng(7)
    pal = genwall._palette({"accent": "#cba6f7", "accent_soft": "#89b4fa"})
    img = genwall.STYLES[style](small_grid, rng, pal, 1.0)
    assert img.shape == (36, 64, 3)
    assert not np.any(np.isnan(img)), f"{style} produced NaNs"
    # to_png clamps, but a style straying far outside 0..255 means the maths is off.
    assert img.min() > -50 and img.max() < 400


@pytest.mark.parametrize("style", STYLES)
def test_style_is_deterministic_for_a_given_seed(genwall, small_grid, style):
    """Same (seed, style) -> same pixels, or `just walls` dirties the tree."""
    pal = genwall._palette({"accent": "#cba6f7", "accent_soft": "#89b4fa"})
    a = genwall.STYLES[style](small_grid, np.random.default_rng(11), pal, 1.0)
    b = genwall.STYLES[style](small_grid, np.random.default_rng(11), pal, 1.0)
    assert np.array_equal(a, b)


@pytest.mark.parametrize("style", STYLES)
def test_style_composition_varies_with_the_seed(genwall, small_grid, style):
    pal = genwall._palette({"accent": "#cba6f7", "accent_soft": "#89b4fa"})
    a = genwall.STYLES[style](small_grid, np.random.default_rng(1), pal, 1.0)
    b = genwall.STYLES[style](small_grid, np.random.default_rng(2), pal, 1.0)
    assert not np.array_equal(a, b), f"{style} ignores its seed"


def test_intensity_scales_how_hard_the_accent_is_laid_on(genwall, small_grid):
    """The knob a near-black theme turns down so the wallpaper stops shouting."""
    pal = genwall._palette({"accent": "#ff0000", "accent_soft": "#ff8800"})
    quiet = genwall.STYLES["mesh"](small_grid, np.random.default_rng(3), pal, 0.2)
    loud = genwall.STYLES["mesh"](small_grid, np.random.default_rng(3), pal, 1.0)
    assert quiet.mean() < loud.mean()


# ── end-to-end, against the shipped themes ────────────────────────────────
@pytest.mark.parametrize("theme_path", theme_paths(), ids=theme_ids())
def test_every_shipped_theme_generates_a_wallpaper(genwall, theme_path, tmp_path):
    out = tmp_path / "wall.png"
    assert genwall.main(["--theme", str(theme_path), "--size", "64x36", str(out)]) == 0
    w, h, _tags, _raw = _parse_png(out.read_bytes())
    assert (w, h) == (64, 36)


def test_main_rejects_a_malformed_size(genwall, tmp_path):
    with pytest.raises(SystemExit) as exc:
        genwall.main(["--size", "big", str(tmp_path / "o.png")])
    assert "bad --size" in str(exc.value)


def test_main_creates_the_output_directory(genwall, tmp_path):
    out = tmp_path / "nested" / "deeper" / "wall.png"
    assert genwall.main(["--size", "64x36", str(out)]) == 0
    assert out.exists()


def test_main_without_a_theme_renders_the_standalone_default(genwall, tmp_path):
    out = tmp_path / "wall.png"
    assert genwall.main(["--size", "64x36", str(out)]) == 0
    assert out.stat().st_size > 0


def test_main_is_reproducible_end_to_end(genwall, tmp_path):
    a, b = tmp_path / "a.png", tmp_path / "b.png"
    for out in (a, b):
        genwall.main(["--size", "64x36", "--style", "mesh", "--seed", "5", str(out)])
    assert a.read_bytes() == b.read_bytes()
