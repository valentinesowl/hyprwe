#!/usr/bin/env python3
"""genwall.py — generate an HWE theme wallpaper from its semantic palette + style.

Procedural art (no third-party image, no licence) so it ships in the repo free and
clear. A theme declares BOTH its colours ([sem]) and the character of its wallpaper
([wallpaper] style + seed); everything else — gradient angle, glow placement, cell
count, ribbon turns — is drawn from a PRNG seeded on the theme name, so each theme
gets its own composition rather than the same picture in a different hue.

Styles:
    mesh     soft warped gradient lit by accent glows  — restrained, the default
    aurora   domain-warped ribbons of light            — organic, flowing
    voronoi  crystalline facets with lit edges         — icy, low-poly
    grid     synthwave horizon: sun + perspective grid — loud, retro
    signal   a faint phosphor trace across emptiness   — near-black, sparse
    skyline  neon-noir city at night: rooflines + lit  — dark, atmospheric
             windows under a low haze

A theme tunes its wallpaper through [wallpaper] alone, never by editing this file:

    style      one of the above (default: mesh)
    seed       reroll the composition without renaming the theme
    intensity  scale how hard the accent is laid on (default 1.0). Themes with a
               near-black bg and a hot accent need this below 1 or the wallpaper
               shouts over the desktop it is supposed to sit behind.

Usage:
    genwall.py --theme <theme.toml> <out.png> [--size WxH] [--style S] [--seed N]
    genwall.py <out.png>                        # standalone Catppuccin-Mocha default

MAINTAINER TOOL. Run via `just walls`; the PNGs it writes are committed, so a fresh
clone never generates anything and this never runs on a user's machine. That is why
it may depend on numpy — do NOT add such deps to lib/*.sh or bin/hwe, which do.
"""

from __future__ import annotations

import argparse
import math
import struct
import sys
import zlib
from pathlib import Path

import numpy as np

F32 = np.float32


# ── colour helpers ─────────────────────────────────────────────────────────
def hexrgb(c: str) -> np.ndarray:
    """'#1e1e2e' | '1e1e2e' -> float32 [30., 30., 46.]."""
    c = str(c).lstrip("#")
    return np.array([int(c[i : i + 2], 16) for i in (0, 2, 4)], dtype=F32)


def ramp(t: np.ndarray, stops: list[tuple[float, np.ndarray]]) -> np.ndarray:
    """Map t (any shape, 0..1) through colour stops -> (..., 3). Clamps outside."""
    pos = np.array([s[0] for s in stops], dtype=F32)
    cols = np.array([s[1] for s in stops], dtype=F32)
    return np.stack([np.interp(t, pos, cols[:, i]).astype(F32) for i in range(3)], -1)


def mix(a: np.ndarray, b: np.ndarray, t: np.ndarray) -> np.ndarray:
    """Lerp colour field a -> colour b by scalar field t. Broadcasts t to (...,1)."""
    return a + (b - a) * t[..., None]


def smoothstep(t: np.ndarray) -> np.ndarray:
    t = np.clip(t, 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def stretch(a: np.ndarray) -> np.ndarray:
    """Rescale a field to span exactly 0..1.

    fbm() does NOT return 0..1: it averages octaves, so its output bunches around
    0.5 (typically ~0.35..0.85). Thresholding it against a literal therefore gates
    almost nothing. Stretch first, then threshold.
    """
    lo, hi = float(a.min()), float(a.max())
    return (a - lo) / (hi - lo) if hi > lo else np.zeros_like(a)


# ── the grid every style draws on ──────────────────────────────────────────
class Grid:
    """UV coordinate fields for one canvas.

    `x` is u scaled by the aspect ratio, so distances and noise cells are square:
    measuring in raw uv on a 16:9 canvas stretches every circle into an ellipse.
    """

    def __init__(self, w: int, h: int):
        self.w, self.h = w, h
        self.aspect = w / h
        u = np.linspace(0.0, 1.0, w, dtype=F32)[None, :]
        v = np.linspace(0.0, 1.0, h, dtype=F32)[:, None]
        self.u = np.broadcast_to(u, (h, w))
        self.v = np.broadcast_to(v, (h, w))
        self.x = self.u * self.aspect
        self.y = self.v


# ── noise ──────────────────────────────────────────────────────────────────
def _vnoise(x: np.ndarray, y: np.ndarray, lat: np.ndarray) -> np.ndarray:
    """Value noise: smoothstep-interpolated random lattice. x/y in lattice units.

    Indices wrap, so the field is seamless and callers may sample outside [0, res)
    freely — which domain warping does by construction.
    """
    ly, lx = lat.shape
    x0 = np.floor(x)
    y0 = np.floor(y)
    fx = smoothstep(x - x0)
    fy = smoothstep(y - y0)
    xi = x0.astype(np.int32)
    yi = y0.astype(np.int32)
    x0m, x1m = np.mod(xi, lx), np.mod(xi + 1, lx)
    y0m, y1m = np.mod(yi, ly), np.mod(yi + 1, ly)
    n00, n10 = lat[y0m, x0m], lat[y0m, x1m]
    n01, n11 = lat[y1m, x0m], lat[y1m, x1m]
    a = n00 + (n10 - n00) * fx
    b = n01 + (n11 - n01) * fx
    return a + (b - a) * fy


def fbm(
    g: Grid,
    rng: np.random.Generator,
    octaves: int = 5,
    base: float = 3.0,
    gain: float = 0.5,
    lac: float = 2.0,
    x: np.ndarray | None = None,
    y: np.ndarray | None = None,
) -> np.ndarray:
    """Fractal value noise in 0..1. Pass x/y to sample a warped domain."""
    x = g.x if x is None else x
    y = g.y if y is None else y
    total = np.zeros((g.h, g.w), dtype=F32)
    amp, norm, f = 1.0, 0.0, base
    for _ in range(octaves):
        ry = max(2, round(f))
        rx = max(2, round(f * g.aspect))
        lat = rng.random((ry, rx), dtype=F32)
        # x spans 0..aspect and the lattice is rx wide over exactly that span.
        total += amp * _vnoise(x * (rx / g.aspect), y * ry, lat)
        norm += amp
        amp *= gain
        f *= lac
    return total / norm


def noise1d(
    xs: np.ndarray, rng: np.random.Generator, octaves: int = 4, base: float = 4.0,
    gain: float = 0.5, lac: float = 2.0,
) -> np.ndarray:
    """Fractal value noise along one axis. Same caveat as fbm: NOT 0..1 — see stretch()."""
    total = np.zeros_like(xs)
    amp, norm, f = 1.0, 0.0, base
    for _ in range(octaves):
        r = max(2, round(f))
        lat = rng.random(r, dtype=F32)
        t = xs * r
        i0 = np.floor(t).astype(np.int32)
        fr = smoothstep(t - i0)
        a, b = lat[i0 % r], lat[(i0 + 1) % r]
        total += amp * (a + (b - a) * fr)
        norm += amp
        amp *= gain
        f *= lac
    return total / norm


def _soften(a: np.ndarray) -> np.ndarray:
    """Cheap 3x3 tent blur by array shifts — turns razor-thin pixels into something with
    a halo. No scipy needed for a kernel this small."""
    out = a * 2.0
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            if dx or dy:
                out += np.roll(np.roll(a, dy, 0), dx, 1)
    return out / 10.0


# ── shared composition pieces ──────────────────────────────────────────────
def base_surface(g: Grid, rng: np.random.Generator, pal: dict) -> tuple[np.ndarray, np.ndarray]:
    """bg_normal -> bg_dark ramp under a seeded angle. Returns (rgb, t)."""
    angle = rng.uniform(0.0, 2.0 * math.pi)
    dx, dy = math.cos(angle), math.sin(angle)
    p = g.x * dx + g.y * dy
    # Normalise over the projection's range across the canvas so the ramp spans it
    # exactly, whatever the angle.
    lo, hi = float(p.min()), float(p.max())
    t = (p - lo) / (hi - lo) if hi > lo else np.zeros_like(p)
    return ramp(t, [(0.0, pal["bg_normal"]), (1.0, pal["bg_dark"])]), t


def glow_sites(
    g: Grid, rng: np.random.Generator, n: int, sep: float = 0.55
) -> list[tuple[float, float]]:
    """Rejection-sample glow centres in aspect-space, kept apart and off-centre.

    Both rules are taste, learned the hard way: without separation two glows merge
    into one blob, and a large glow sitting on the centre washes the whole frame
    into an even haze. The old hardcoded composition encoded the same taste as
    constants — this keeps it while letting the layout vary per theme.
    """
    pts: list[tuple[float, float]] = []
    for _ in range(600):
        if len(pts) == n:
            break
        p = (rng.uniform(0.14, 0.86), rng.uniform(0.16, 0.84))
        if math.hypot((p[0] - 0.5) * g.aspect, p[1] - 0.5) < 0.30:
            continue  # too close to the centre
        if all(math.hypot((p[0] - q[0]) * g.aspect, p[1] - q[1]) > sep for q in pts):
            pts.append(p)
    return pts


def add_glows(
    img: np.ndarray,
    g: Grid,
    rng: np.random.Generator,
    pal: dict,
    k: float,
    n: int,
    warp: np.ndarray | None = None,
) -> np.ndarray:
    """Blend soft radial accent glows over img. `warp` bends them out of round."""
    for i, (ux, uy) in enumerate(glow_sites(g, rng, n)):
        gx, gy = ux * g.aspect, uy
        radius = rng.uniform(0.42, 0.70)
        strength = rng.uniform(0.50, 0.62) if i == 0 else rng.uniform(0.26, 0.38)
        col = pal["accent"] if i % 2 == 0 else pal["accent_soft"]
        d = np.hypot(g.x - gx, g.y - gy) / radius
        if warp is not None:
            d = d + (warp - 0.5) * 0.55
        img = mix(img, col, smoothstep(1.0 - d) * strength * k)
    return img


# ── styles ─────────────────────────────────────────────────────────────────
def st_mesh(g: Grid, rng: np.random.Generator, pal: dict, k: float) -> np.ndarray:
    """Soft warped gradient + accent glows. The restrained one."""
    img, _ = base_surface(g, rng, pal)
    # Soft cloud structure. Restrained is the brief, but a pure radial falloff reads
    # as an out-of-focus placeholder — there has to be something to look at.
    warp = stretch(fbm(g, rng, octaves=5, base=2.0))
    img = mix(img, pal["bg_light"], smoothstep((warp - 0.52) * 2.4) * 0.60 * k)
    img = mix(img, pal["bg_dark"], smoothstep((0.48 - warp) * 2.4) * 0.40)
    return add_glows(img, g, rng, pal, k, n=int(rng.integers(2, 4)), warp=warp)


def st_aurora(g: Grid, rng: np.random.Generator, pal: dict, k: float) -> np.ndarray:
    """Domain-warped ribbons of light."""
    img, _ = base_surface(g, rng, pal)

    # Two independent noise fields displace the domain; sampling fbm at the warped
    # coordinates is what turns concentric bands into drifting ribbons.
    wx = fbm(g, rng, octaves=4, base=2.0)
    wy = fbm(g, rng, octaves=4, base=2.0)
    amp = rng.uniform(0.45, 0.80)
    n = fbm(g, rng, octaves=5, base=2.5, x=g.x + (wx - 0.5) * amp, y=g.y + (wy - 0.5) * amp)

    turns = rng.uniform(2.0, 3.4)
    phase = rng.uniform(0.0, 2.0 * math.pi)
    ribbons = 0.5 + 0.5 * np.sin(n * (2.0 * math.pi * turns) + phase)
    ribbons = ribbons ** rng.uniform(2.2, 3.4)  # sharpen crests into ribbons

    # An envelope keeps the ribbons a band of light rather than an even rash.
    band_c = rng.uniform(0.30, 0.68)
    env = smoothstep(1.0 - np.abs(g.v - band_c) / rng.uniform(0.42, 0.62))
    inten = ribbons * env

    img = mix(img, pal["accent_soft"], inten * 0.55 * k)
    img = mix(img, pal["accent"], (inten**2.2) * 0.60 * k)
    return add_glows(img, g, rng, pal, k, n=1, warp=wx)


def st_voronoi(g: Grid, rng: np.random.Generator, pal: dict, k: float) -> np.ndarray:
    """Crystalline facets with lit edges."""
    n = int(rng.integers(13, 24))
    # Sites overflow the canvas so border cells are cropped facets, not whole ones.
    sx = rng.uniform(-0.12, 1.12, n).astype(F32) * g.aspect
    sy = rng.uniform(-0.12, 1.12, n).astype(F32)

    f1 = np.full((g.h, g.w), np.inf, dtype=F32)
    f2 = np.full((g.h, g.w), np.inf, dtype=F32)
    cid = np.zeros((g.h, g.w), dtype=np.int32)
    for i in range(n):
        d = np.hypot(g.x - sx[i], g.y - sy[i])
        closer = d < f1
        # F2 must absorb the old F1 wherever this site takes over, else the
        # second-nearest distance is lost and the edges vanish.
        f2 = np.where(closer, f1, np.minimum(f2, d))
        cid = np.where(closer, i, cid)
        f1 = np.where(closer, d, f1)

    # Flat-shade each facet by where its site sits along a seeded gradient.
    angle = rng.uniform(0.0, 2.0 * math.pi)
    proj = sx * math.cos(angle) + sy * math.sin(angle)
    ct = (proj - proj.min()) / max(float(np.ptp(proj)), 1e-6)
    cell_rgb = ramp(ct, [(0.0, pal["bg_light"]), (0.55, pal["bg_normal"]), (1.0, pal["bg_dark"])])
    img = cell_rgb[cid]

    # Shade within each facet toward its site: gives the flat cells some volume.
    img *= (0.80 + 0.34 * smoothstep(1.0 - f1 / 0.55))[..., None]

    edge = np.clip(1.0 - (f2 - f1) / 0.014, 0.0, 1.0) ** 1.6
    img = mix(img, pal["accent"], edge * 0.62 * k)
    return add_glows(img, g, rng, pal, k, n=1)


def _lines(phase: np.ndarray, dphase_px: np.ndarray) -> np.ndarray:
    """Anti-aliased unit-period lines, fading out where they'd alias.

    dphase_px is |d(phase)/d(pixel)|. Line width tracks it, so lines stay ~2px on
    screen as perspective compresses them; past ~half a period per pixel no line can
    be resolved, and the fade turns them into haze instead of moire.
    """
    f = phase - np.floor(phase)
    d = np.minimum(f, 1.0 - f)
    width = np.maximum(dphase_px * 1.6, 1e-7)
    line = np.clip(1.0 - d / width, 0.0, 1.0)
    return line * np.clip(1.0 / (dphase_px * 22.0 + 1.0), 0.0, 1.0)


def st_grid(g: Grid, rng: np.random.Generator, pal: dict, k: float) -> np.ndarray:
    """Synthwave horizon: banded sun over a perspective grid."""
    hz = rng.uniform(0.50, 0.58)

    # sky
    sky = ramp(np.clip(g.v / hz, 0.0, 1.0), [(0.0, pal["bg_dark"]), (1.0, pal["bg_normal"])])

    # sun — a disc of accent, cut by horizontal bands that thicken toward its foot
    sun_r = rng.uniform(0.17, 0.24)
    sun_x = rng.uniform(0.34, 0.66) * g.aspect
    sd = np.hypot(g.x - sun_x, g.y - hz) / sun_r
    # Only the sun's top half is ever visible — the ground paints over the rest — so
    # q must span hz-sun_r..hz, not the whole disc, or the bands never widen and the
    # sun renders as a solid semicircle.
    q = (g.v - (hz - sun_r)) / sun_r  # 0 at sun top, 1 at the horizon
    band = (q * rng.uniform(5.0, 7.0)) % 1.0
    gap = np.clip((q - 0.30) / 0.70, 0.0, 1.0) * 0.80
    sun = (sd < 1.0) & (band > gap)
    sun_col = ramp(np.clip(q, 0.0, 1.0), [(0.0, pal["accent_soft"]), (1.0, pal["accent"])])
    sky = np.where(sun[..., None], sun_col, sky)
    sky = mix(sky, pal["accent"], smoothstep(1.0 - (sd - 1.0) / 1.5) * 0.22 * k)  # halo

    # ground — perspective grid, lines converging at the horizon
    depth = np.maximum(g.v - hz, 1e-4)
    z = 1.0 / depth
    kz, kx = rng.uniform(0.10, 0.16), rng.uniform(1.6, 2.6)
    # Line width tracks |grad(phase)| per pixel. For the radial lines that gradient
    # is NOT just its x part: phase carries z = 1/depth, so it also races along y,
    # and near the horizon that term dominates. Sizing on dx alone left those lines
    # thinner than a pixel out at the sides, which sampled them into dashes.
    h_lines = _lines(z * kz, kz * z * z / g.h)
    vx_g = kx * z * g.aspect / g.w
    vy_g = np.abs(g.x - sun_x) * kx * z * z / g.h
    v_lines = _lines((g.x - sun_x) * z * kx, np.hypot(vx_g, vy_g))
    ground = ramp(smoothstep(depth * 2.2), [(0.0, pal["bg_normal"]), (1.0, pal["bg_dark"])])
    lines = np.maximum(h_lines, v_lines)
    # Distance haze: near the horizon the lattice is finer than the pixel grid, so
    # fade the grid into the surface there rather than letting it boil into moire.
    lines *= smoothstep(depth / 0.035)
    ground = mix(ground, pal["accent"], lines * 0.85 * k)
    ground = mix(ground, pal["accent_soft"], smoothstep(1.0 - depth / 0.30) * 0.20 * k)  # glow

    return np.where((g.v < hz)[..., None], sky, ground)


def st_signal(g: Grid, rng: np.random.Generator, pal: dict, k: float) -> np.ndarray:
    """A faint trace across an empty field — "едва отслеживающийся сигнал в пустоте".

    Deliberately mostly nothing: a near-flat ground, one distant glow for depth, a sparse
    noise floor of stars, and a single phosphor trace that stays quiet for most of its run
    and only occasionally has anything to say. The emptiness IS the subject — every
    temptation to fill it makes the signal mean less.
    """
    img, _ = base_surface(g, rng, pal)

    # One far-off glow. Kept at 0.10 so it reads as distance, not as a feature.
    ux, uy = glow_sites(g, rng, 1)[0]
    d = np.hypot(g.x - ux * g.aspect, g.y - uy) / rng.uniform(0.55, 0.85)
    img = mix(img, pal["accent_soft"], smoothstep(1.0 - d) * 0.10 * k)

    # Noise floor. Thresholding white noise is what makes stars POINTS rather than a haze;
    # two populations (many dim / few bright) is what stops them reading as sensor dirt.
    n = rng.random((g.h, g.w), dtype=F32)
    far = np.clip((n - 0.9988) / 0.0012, 0.0, 1.0)
    near = np.clip((n - 0.99984) / 0.00016, 0.0, 1.0)
    img = mix(img, pal["fg_dim"], np.clip(_soften(far), 0.0, 1.0) * 0.55)
    img = mix(img, pal["fg_bright"], np.clip(_soften(_soften(near)) * 3.0, 0.0, 1.0) * 0.5 * k)

    # The trace. Built per-COLUMN as a 1-D curve, then measured against every pixel's y —
    # a 1-D signal broadcast over the grid, not a 2-D field that happens to look linear.
    xs = np.linspace(0.0, 1.0, g.w, dtype=F32)
    base_y = rng.uniform(0.40, 0.60)
    quiet = (noise1d(xs, rng, 4, 6.0) - 0.5) * 0.012  # a flatline is never perfectly flat
    # Bursts: a couple of regions along x where the signal wakes up; zero almost everywhere.
    burst = smoothstep((stretch(noise1d(xs, rng, 2, 3.0)) - 0.58) * 3.2)
    detail = (noise1d(xs, rng, 5, 24.0) - 0.5) * 2.0
    trace_y = base_y + quiet + burst * detail * rng.uniform(0.09, 0.15)

    # How loud the trace reads along its run — mostly barely. Floor at 0.14: the thread
    # must never break, or it stops being one signal and becomes scattered dashes.
    vis = smoothstep((stretch(noise1d(xs, rng, 3, 4.0)) - 0.30) * 1.8)
    vis = 0.14 + 0.86 * vis * (0.30 + 0.70 * burst)

    dy = np.abs(g.v - trace_y[None, :])
    core = np.exp(-((dy / 0.0016) ** 2))   # the filament itself
    bloom = np.exp(-((dy / 0.022) ** 2))   # phosphor halo around it
    img = mix(img, pal["accent_soft"], bloom * vis[None, :] * 0.30 * k)
    img = mix(img, pal["accent"], core * vis[None, :] * 0.95 * k)
    return img


def _skyline_profile(
    g: Grid, rng: np.random.Generator, top_lo: float, top_hi: float, wmin: int, wmax: int
) -> np.ndarray:
    """A city rooflines as a per-column height field (shape (w,), in v units).

    Piecewise-constant with vertical edges = rectangular building tops, so the
    silhouette is `v >= top`. Buildings get an occasional raised crown (a stepped
    setback) and a scatter of thin antenna spikes — the two cues that read "city"
    rather than "bar chart".
    """
    w = g.w
    top = np.empty(w, dtype=F32)
    x = 0
    while x < w:
        bw = int(rng.integers(wmin, wmax + 1))
        x1 = min(x + bw, w)
        h = float(rng.uniform(top_lo, top_hi))
        top[x:x1] = h
        # A narrower crown block stepped up off the roof — the classic setback tier.
        if rng.random() < 0.32 and x1 - x > max(12, wmin // 2):
            cw = int((x1 - x) * rng.uniform(0.28, 0.55))
            cx = x + int((x1 - x - cw) * rng.uniform(0.0, 1.0))
            top[cx : cx + cw] = h - rng.uniform(0.02, 0.055)
        x = x1
    # Antennas: 1-3px slivers rising well above their roof.
    aw = max(1, w // 900)
    for _ in range(int(rng.integers(5, 12))):
        c = int(rng.integers(0, w - aw))
        top[c : c + aw] = max(0.02, top[c] - rng.uniform(0.05, 0.12))
    return np.clip(top, 0.0, 1.0)


def _windows(
    g: Grid,
    rng: np.random.Generator,
    mask: np.ndarray,
    roof: np.ndarray,
    pal: dict,
    k: float,
    cw: int,
    ch: int,
    density: float,
    bright: float,
) -> np.ndarray:
    """A lattice of lit windows over the buildings in `mask`.

    Screen-space lattice, not per-building: a regular grid of cells, each randomly
    lit and coloured, masked to building interior below its roofline. Windows never
    line up with building edges that way, but on a near-black stylised skyline that
    reads fine and stays fully vectorised. Pink+cyan is the cyberpunk signature; a
    per-cell brightness (many dim, few bright) keeps it a living city, not a checker.
    Returns an additive light field (h, w, 3) — windows are emissive, so they ADD.
    """
    W, H = g.w, g.h
    xi = np.arange(W, dtype=np.int32)[None, :]
    yi = np.arange(H, dtype=np.int32)[:, None]
    gw, gh = W // cw + 1, H // ch + 1
    lit = rng.random((gh, gw)) < density
    hue = rng.random((gh, gw)).astype(F32)
    brt = rng.uniform(0.30, 1.0, (gh, gw)).astype(F32) ** 1.8  # skew toward dim
    ci, ri = xi // cw, yi // ch
    # Leave a gutter around each window so lit cells read as panes, not solid bands.
    inx = ((xi % cw) >= cw // 4) & ((xi % cw) < cw - cw // 4)
    iny = ((yi % ch) >= ch // 3) & ((yi % ch) < ch - ch // 5)
    on = lit[ri, ci] & inx & iny & mask & (g.v >= roof[None, :] + 0.012)

    # Ground the foreground: fade windows out into the dark bottom edge so the near
    # buildings sink into black instead of ending in an even field of confetti.
    fade = smoothstep((1.0 - g.v) / 0.14)
    val = np.where(on, brt[ri, ci], 0.0).astype(F32) * fade
    # Two-colour split: mostly accent, a cyan minority. accent_soft carries the bloom.
    pick = np.where(hue[ri, ci] < 0.66, 0, 1)
    cols = np.stack([pal["accent"], pal["cyan"]]).astype(F32)
    col = cols[np.where(on, pick, 0)]

    add = col * (val * bright * k)[..., None]
    bloom = _soften(_soften(val))
    add = add + pal["accent_soft"][None, None, :] * (bloom * 0.22 * k)[..., None]
    return add


def st_skyline(g: Grid, rng: np.random.Generator, pal: dict, k: float) -> np.ndarray:
    """Neon-noir city at night: layered rooflines under a haze, windows lit pink+cyan.

    Near-black by construction — the sky is dark, the buildings darker, and the only
    light is a low glow bleeding up from behind the skyline plus a sparse scatter of
    windows. Three silhouette layers with atmospheric perspective (distant = lighter
    and hazier, near = blackest) give the frame depth without filling it.
    """
    hz = float(rng.uniform(0.50, 0.58))  # where the far rooflines sit

    # Sky: dark at the top, warming toward a glow band just behind the skyline.
    img = ramp(
        smoothstep(np.clip(g.v / (hz + 0.10), 0.0, 1.0)),
        [(0.0, pal["bg_dark"]), (1.0, pal["bg_normal"])],
    )
    # Faint stars up high — the same two-population trick as `signal`, kept very quiet.
    nz = rng.random((g.h, g.w), dtype=F32)
    stars = np.clip((nz - 0.9990) / 0.0010, 0.0, 1.0) * smoothstep((hz - g.v) / 0.25)
    img = mix(img, pal["fg_dim"], np.clip(_soften(stars), 0.0, 1.0) * 0.45)
    # City glow: light pollution blooming up from the rooflines.
    glow = smoothstep(1.0 - np.abs(g.v - (hz + 0.02)) / rng.uniform(0.22, 0.32))
    glow = glow * np.where(g.v > hz + 0.02, 0.55, 1.0)  # taper the downward half
    img = img + pal["accent_soft"][None, None, :] * (glow * 0.16 * k)[..., None]
    # One distant hazy light source (a far sign / low moon) behind the towers.
    lx, ly = rng.uniform(0.18, 0.82) * g.aspect, hz - rng.uniform(0.04, 0.14)
    d = np.hypot(g.x - lx, g.y - ly) / rng.uniform(0.30, 0.45)
    img = img + pal["accent"][None, None, :] * (smoothstep(1.0 - d) * 0.10 * k)[..., None]

    wmin, wmax = max(8, g.w // 64), max(20, g.w // 15)
    far = mix(pal["bg_dark"], pal["bg_light"], np.float32(0.42))  # hazy distance
    far = mix(far[None, None, :], pal["accent_soft"], np.float32(0.10 * k))[0, 0]
    layers = [
        # (top_lo, top_hi, colour, win cell w, win cell h, density, brightness)
        (hz - 0.07, hz + 0.03, far, 7, 9, 0.16, 0.30),
        (hz - 0.01, hz + 0.12, pal["bg_dark"] * 0.80, 10, 13, 0.13, 0.55),
        (hz + 0.06, hz + 0.24, pal["bg_dark"] * 0.42, 14, 18, 0.10, 0.85),
    ]
    for top_lo, top_hi, col, cw, ch, dens, bright in layers:
        roof = _skyline_profile(g, rng, top_lo, top_hi, wmin, wmax)
        mask = g.v >= roof[None, :]
        # A touch of vertical shade down each face keeps the silhouette from reading flat.
        shade = (0.82 + 0.18 * smoothstep((g.v - roof[None, :]) / 0.5))[..., None]
        col_field = np.broadcast_to(np.asarray(col, F32), (g.h, g.w, 3)) * shade
        img = np.where(mask[..., None], col_field, img)
        img = img + _windows(g, rng, mask, roof, pal, k, cw, ch, dens, bright)
    return img


STYLES = {
    "mesh": st_mesh,
    "aurora": st_aurora,
    "voronoi": st_voronoi,
    "grid": st_grid,
    "signal": st_signal,
    "skyline": st_skyline,
}


# ── finish ─────────────────────────────────────────────────────────────────
# Ordered (Bayer 8x8) dither to break 8-bit banding on smooth dark gradients.
# Unlike random hash-noise, this pattern is PERIODIC, so PNG compresses it almost
# as well as the gradient itself — a random dither bloats the file ~5x. Values
# 0..63 map to a threshold in ~[-1, 1) LSB, enough to dissolve 1-level steps.
_BAYER8 = np.array(
    [
        [0, 32, 8, 40, 2, 34, 10, 42],
        [48, 16, 56, 24, 50, 18, 58, 26],
        [12, 44, 4, 36, 14, 46, 6, 38],
        [60, 28, 52, 20, 62, 30, 54, 22],
        [3, 35, 11, 43, 1, 33, 9, 41],
        [51, 19, 59, 27, 49, 17, 57, 25],
        [15, 47, 7, 39, 13, 45, 5, 37],
        [63, 31, 55, 23, 61, 29, 53, 21],
    ],
    dtype=F32,
)


def vignette(img: np.ndarray, g: Grid, rng: np.random.Generator) -> np.ndarray:
    vx = (g.u - 0.5) * 2.0
    vy = (g.v - 0.5) * 2.0
    k = rng.uniform(0.12, 0.20)
    return img * (1.0 - k * (vx * vx + vy * vy))[..., None]


def to_png(img: np.ndarray, g: Grid) -> bytes:
    d = np.tile(_BAYER8, (g.h // 8 + 1, g.w // 8 + 1))[: g.h, : g.w]
    d = (d + 0.5) / 32.0 - 1.0
    px = np.clip(img + d[..., None], 0.0, 255.0).astype(np.uint8)

    # PNG scanlines are each prefixed with a filter byte; 0 = None.
    raw = np.zeros((g.h, 1 + g.w * 3), dtype=np.uint8)
    raw[:, 1:] = px.reshape(g.h, g.w * 3)

    def chunk(tag: bytes, data: bytes) -> bytes:
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    out = b"\x89PNG\r\n\x1a\n"
    out += chunk(b"IHDR", struct.pack(">IIBBBBB", g.w, g.h, 8, 2, 0, 0, 0))  # 8-bit RGB
    out += chunk(b"IDAT", zlib.compress(raw.tobytes(), 9))
    out += chunk(b"IEND", b"")
    return out


# ── theme input ────────────────────────────────────────────────────────────
MOCHA_SEM = {
    "bg_dark": "#181825",
    "bg_normal": "#1e1e2e",
    "bg_light": "#313244",
    "fg_dim": "#6c7086",
    "fg_bright": "#cdd6f4",
    "accent": "#cba6f7",
    "accent_soft": "#b4befe",
}
_ROLES = {
    "bg_dark": "#11111b",
    "bg_normal": "#1e1e2e",
    "bg_light": "#313244",
    "fg_dim": "#6c7086",
    "fg_bright": "#cdd6f4",
    "accent": "#cba6f7",
    "accent_soft": "#89b4fa",
    "cyan": "#89dceb",
}


def _palette(sem: dict) -> dict:
    pal = {k: hexrgb(sem.get(k) or default) for k, default in _ROLES.items()}
    # accent_soft is optional in the contract; falling back to accent keeps a theme
    # that omits it monochrome rather than silently Catppuccin-blue.
    if not sem.get("accent_soft") and sem.get("accent"):
        pal["accent_soft"] = hexrgb(sem["accent"])
    return pal


def _theme_validators():
    """render-theme.py's value validators, loaded by path (its hyphen makes it
    unimportable the normal way). Reusing them keeps ONE definition of "is this a
    safe theme to render" — so a submitted theme is held to the same line here as
    at runtime, instead of being trusted blindly on the maintainer's box."""
    import importlib.util

    mod_name = "hwe_render_theme"
    if mod_name in sys.modules:
        return sys.modules[mod_name]
    spec = importlib.util.spec_from_file_location(mod_name, Path(__file__).with_name("render-theme.py"))
    mod = importlib.util.module_from_spec(spec)
    sys.modules[mod_name] = mod
    spec.loader.exec_module(mod)
    return mod


def _reject_malformed_theme(doc: dict, path: Path) -> None:
    rt = _theme_validators()
    checked = dict(doc)
    checked.setdefault("name", path.parent.name)
    problems = rt.check_values(checked)
    if problems:
        sys.exit(f"{path}: refusing a malformed theme:\n  " + "\n  ".join(problems))


def read_theme(path: Path) -> tuple[dict, str, int, float]:
    import tomllib

    with path.open("rb") as fh:
        doc = tomllib.load(fh)
    _reject_malformed_theme(doc, path)
    wp = doc.get("wallpaper", {})

    style = wp.get("style", "mesh")
    if style not in STYLES:
        sys.exit(f"{path}: unknown wallpaper style {style!r} (have: {', '.join(STYLES)})")

    seed = wp.get("seed")
    if seed is None:
        # crc32 of the theme name, not hash() — hash() is salted per process, so the
        # wallpaper would differ on every run and dirty the working tree.
        seed = zlib.crc32(str(doc.get("name") or path.parent.name).encode())

    return _palette(doc.get("sem", {})), style, int(seed), float(wp.get("intensity", 1.0))


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("out", help="output PNG path")
    ap.add_argument("--theme", type=Path, help="theme.toml to read [sem] + [wallpaper] from")
    ap.add_argument("--size", default="2560x1440", metavar="WxH")
    ap.add_argument("--style", choices=sorted(STYLES), help="override the theme's style")
    ap.add_argument("--seed", type=int, help="override the theme's seed")
    ap.add_argument("--intensity", type=float, help="override the theme's accent intensity")
    a = ap.parse_args(argv)

    if a.theme:
        pal, style, seed, k = read_theme(a.theme)
    else:
        pal, style, seed, k = _palette(MOCHA_SEM), "mesh", zlib.crc32(b"Catppuccin Mocha"), 1.0
    style = a.style or style
    seed = a.seed if a.seed is not None else seed
    k = a.intensity if a.intensity is not None else k

    try:
        w, h = (int(v) for v in a.size.lower().split("x"))
    except ValueError:
        sys.exit(f"bad --size {a.size!r}, want WxH e.g. 2560x1440")

    g = Grid(w, h)
    # One generator drawn in a fixed order = a stable composition per (seed, style).
    rng = np.random.default_rng(seed)
    img = vignette(STYLES[style](g, rng, pal, k), g, rng)
    png = to_png(img, g)

    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(png)
    print(f"wrote {out} ({len(png)} bytes, {w}x{h}, {style}/{seed}/k={k:g})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
