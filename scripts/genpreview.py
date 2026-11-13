#!/usr/bin/env python3
"""genpreview.py — render a graphic identity card for an HWE theme.

Cards combine the theme palette, its typeface and a distinctive geometric motif.
A softly blurred, darkened wallpaper sits behind the identity artwork; fictitious
desktop widgets are deliberately not part of the preview.

Depends on ImageMagick (`magick`) and fontconfig (`fc-match`), both shipped in HWE.

Usage: genpreview.py <theme.toml> <out.png> [--size WxH]
"""
import math
import shutil
import subprocess
import sys
import tomllib
from pathlib import Path

CANVAS = 480
MOTIFS = {
    "amethyst": "crystal",
    "default": "orbit",
    "ember": "flame",
    "frost": "snowflake",
    "garden": "branch",
    "linen": "weave",
    "mocha": "palette",
    "mono": "monogram",
    "neon": "bolt",
    "paper": "fold",
    "rust": "hazard",
    "void": "signal",
}


def _theme_validators():
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
    tag = checked.get("tagline")
    if tag is not None:
        problem = rt._inline(tag)
        if problem:
            problems.append(f"tagline {problem}")
    for label in ("name", "tagline"):
        value = checked.get(label)
        if not isinstance(value, str):
            continue
        if value.lstrip().startswith("@"):
            problems.append(f"{label} must not begin with '@'")
        elif "%" in value:
            problems.append(f"{label} must not contain '%'")
    if problems:
        sys.exit(f"{path}: refusing a malformed theme:\n  " + "\n  ".join(problems))


def rgba(hexs: str, a: float = 1.0) -> str:
    h = str(hexs).lstrip("#")
    return f"rgba({int(h[0:2],16)},{int(h[2:4],16)},{int(h[4:6],16)},{a})"


def resolve_font(family: str = "JetBrains Mono") -> str:
    try:
        font = subprocess.run(
            ["fc-match", "-f", "%{file}", f"{family}:weight=bold"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        if font:
            return font
    except (OSError, subprocess.CalledProcessError):
        pass
    return "DejaVu-Sans-Bold"


def _layer(draw: list[str], blur: int = 0) -> list[str]:
    layer = ["(", "-size", f"{CANVAS}x{CANVAS}", "xc:none", *draw]
    if blur:
        layer += ["-blur", f"0x{blur}"]
    return [*layer, ")", "-compose", "over", "-composite"]


def _frost_draw(accent: str) -> list[str]:
    draw = ["-fill", "none", "-stroke", accent, "-strokewidth", "7", "-draw", "stroke-linecap round"]
    cx, cy, radius = 240, 170, 100
    for spoke in range(6):
        angle = math.radians(spoke * 60 - 90)
        ex, ey = cx + radius * math.cos(angle), cy + radius * math.sin(angle)
        draw += ["-draw", f"line {cx},{cy} {ex:.1f},{ey:.1f}"]
        bx, by = cx + 60 * math.cos(angle), cy + 60 * math.sin(angle)
        for side in (-1, 1):
            branch = angle + side * math.radians(42)
            tx, ty = bx - 27 * math.cos(branch), by - 27 * math.sin(branch)
            draw += ["-draw", f"line {bx:.1f},{by:.1f} {tx:.1f},{ty:.1f}"]
    return draw


def motif_layers(kind: str, sem: dict) -> list[str]:
    accent = sem["accent"]
    soft = sem["accent_soft"]
    bright = sem["fg_bright"]

    if kind == "crystal":
        silhouette = "polygon 240,52 337,146 285,282 195,282 143,146"
        facets = [
            "-fill", rgba(accent, 0.20), "-stroke", accent, "-strokewidth", "4",
            "-draw", silhouette,
            "-fill", rgba(soft, 0.38), "-stroke", "none",
            "-draw", "polygon 240,52 240,196 143,146",
            "-fill", rgba(bright, 0.13),
            "-draw", "polygon 240,52 337,146 240,196",
            "-fill", rgba(accent, 0.36),
            "-draw", "polygon 143,146 240,196 195,282",
            "-fill", rgba(soft, 0.23),
            "-draw", "polygon 337,146 285,282 240,196",
            "-fill", "none", "-stroke", rgba(bright, 0.65), "-strokewidth", "2",
            "-draw", "polyline 143,146 240,196 337,146",
            "-draw", "line 240,52 240,196",
            "-draw", "line 240,196 240,282",
        ]
        return _layer(["-fill", rgba(accent, 0.28), "-draw", silhouette], 18) + _layer(facets)

    if kind == "flame":
        outer = "path 'M 240,286 C 150,268 142,199 188,143 C 205,122 224,92 232,57 C 277,111 264,145 294,157 C 321,169 337,217 313,252 C 296,276 270,287 240,286 Z'"
        inner = "path 'M 241,270 C 198,259 190,222 216,190 C 231,172 242,151 246,128 C 278,167 297,190 285,226 C 278,252 262,267 241,270 Z'"
        core = "path 'M 242,260 C 222,247 222,226 238,205 C 249,191 253,180 254,169 C 274,204 270,238 242,260 Z'"
        return (
            _layer(["-fill", rgba(accent, 0.32), "-draw", outer], 20)
            + _layer(["-fill", soft, "-stroke", "none", "-draw", outer])
            + _layer(["-fill", accent, "-draw", inner])
            + _layer(["-fill", sem["yellow"], "-draw", core])
        )

    if kind == "snowflake":
        return _layer(_frost_draw(rgba(accent, 0.30)), 16) + _layer(_frost_draw(accent))

    if kind == "branch":
        leaves = [
            "path 'M 229,185 C 174,185 148,156 151,112 C 195,111 225,135 229,185 Z'",
            "path 'M 248,150 C 250,101 280,74 324,77 C 323,121 294,149 248,150 Z'",
            "path 'M 213,243 C 169,244 142,222 137,185 C 179,177 208,199 213,243 Z'",
            "path 'M 259,224 C 270,183 300,166 337,174 C 326,214 299,231 259,224 Z'",
        ]
        draw = [
            "-fill", "none", "-stroke", accent, "-strokewidth", "7", "-draw", "stroke-linecap round",
            "-draw", "path 'M 198,285 C 226,240 239,182 273,112'",
            "-fill", rgba(soft, 0.85), "-stroke", "none", "-draw", leaves[0],
            "-fill", accent, "-draw", leaves[1],
            "-fill", rgba(accent, 0.72), "-draw", leaves[2],
            "-fill", rgba(sem["green"], 0.90), "-draw", leaves[3],
        ]
        return _layer(draw)

    if kind == "weave":
        paths = [
            (soft, 18, "path 'M 64,128 C 139,61 208,195 282,128 C 329,85 369,84 416,121'"),
            (accent, 14, "path 'M 64,183 C 133,116 207,250 282,183 C 332,138 371,141 416,176'"),
            (sem["blue"], 9, "path 'M 64,238 C 137,171 205,303 282,238 C 330,195 371,196 416,231'"),
        ]
        layers = []
        for colour, width, path in paths:
            layers += _layer([
                "-fill", "none", "-stroke", rgba(colour, 0.82), "-strokewidth", str(width),
                "-draw", "stroke-linecap round", "-draw", path,
            ])
        return layers

    if kind == "palette":
        circles = [
            (sem["magenta"], "circle 183,133 183,82"),
            (sem["blue"], "circle 293,133 293,82"),
            (sem["orange"], "circle 183,239 183,188"),
            (sem["green"], "circle 293,239 293,188"),
        ]
        draw = []
        for colour, circle in circles:
            draw += ["-fill", rgba(colour, 0.88), "-stroke", "none", "-draw", circle]
        draw += [
            "-fill", rgba(sem["bg_dark"], 0.78), "-stroke", bright, "-strokewidth", "4",
            "-draw", "circle 239,187 239,153",
            "-fill", bright, "-stroke", "none", "-draw", "circle 239,187 239,179",
        ]
        return _layer(draw)

    if kind == "bolt":
        bolt = "polygon 257,48 155,194 222,194 202,292 329,132 254,132 294,48"
        edge = "polyline 257,48 155,194 222,194"
        return (
            _layer(["-fill", rgba(accent, 0.55), "-draw", bolt], 22)
            + _layer(["-fill", accent, "-stroke", "none", "-draw", bolt])
            + _layer([
                "-fill", "none", "-stroke", sem["cyan"], "-strokewidth", "5", "-draw", "stroke-linecap round",
                "-draw", edge,
            ])
        )

    if kind == "fold":
        page = "polygon 143,64 294,64 341,111 341,278 143,278"
        shadow = _layer(["-fill", rgba(sem["fg_white"], 0.18), "-draw", page], 14)
        paper = _layer([
            "-fill", sem["bg_lighter"], "-stroke", rgba(accent, 0.65), "-strokewidth", "3", "-draw", page,
            "-fill", rgba(soft, 0.42), "-stroke", "none", "-draw", "polygon 294,64 294,111 341,111",
            "-fill", "none", "-stroke", accent, "-strokewidth", "3", "-draw", "polyline 294,64 294,111 341,111",
            "-strokewidth", "7", "-draw", "stroke-linecap round",
            "-draw", "line 179,157 305,157",
            "-draw", "line 179,192 305,192",
            "-draw", "line 179,227 263,227",
        ])
        return shadow + paper

    if kind == "monogram":
        monogram = (
            "path 'M 124,284 L 124,58 L 172,58 L 240,181 L 308,58 "
            "L 356,58 L 356,284 L 312,284 L 312,139 L 258,236 L 222,236 "
            "L 168,139 L 168,284 Z'"
        )
        return _layer([
            "-fill", accent, "-stroke", "none", "-draw", monogram,
            "-fill", soft, "-draw", "rectangle 124,310 356,316",
        ])

    if kind == "hazard":
        stripes = [
            (accent, "polygon 46,86 78,58 290,270 258,298"),
            (soft, "polygon 118,86 150,58 362,270 330,298"),
            (accent, "polygon 190,86 222,58 434,270 402,298"),
        ]
        draw = []
        for colour, stripe in stripes:
            draw += ["-fill", colour, "-stroke", "none", "-draw", stripe]
        return _layer(draw)

    if kind == "signal":
        signal = "polyline 58,173 143,173 171,129 202,231 239,79 275,228 307,139 334,173 422,173"
        return (
            _layer([
                "-fill", "none", "-stroke", rgba(accent, 0.48), "-strokewidth", "10",
                "-draw", "stroke-linejoin round", "-draw", "stroke-linecap round", "-draw", signal,
            ], 18)
            + _layer([
                "-fill", "none", "-stroke", accent, "-strokewidth", "6",
                "-draw", "stroke-linejoin round", "-draw", "stroke-linecap round", "-draw", signal,
            ])
        )

    rings = [
        "-fill", "none", "-stroke", accent, "-strokewidth", "11",
        "-draw", "circle 220,164 220,77",
        "-stroke", rgba(soft, 0.72), "-strokewidth", "4",
        "-draw", "circle 271,192 271,125",
        "-fill", accent, "-stroke", "none", "-draw", "circle 313,102 313,91",
    ]
    return _layer(rings)


def build_cmd(
    name: str, sem: dict, display: str, font: str, wall: Path, out: Path, w: int, h: int
) -> list[str]:
    size = 34 if len(display) > 13 else 40
    kind = MOTIFS.get(name, "orbit")
    if wall.is_file():
        base = [
            str(wall), "-resize", f"{CANVAS}x{CANVAS}^", "-gravity", "center",
            "-extent", f"{CANVAS}x{CANVAS}", "-blur", "0x3", "-modulate", "78,90",
        ]
    else:
        base = ["-size", f"{CANVAS}x{CANVAS}", f"gradient:{sem['bg_normal']}-{sem['bg_dark']}"]
    cmd = ["magick", *base]
    if wall.is_file():
        cmd += [
            "(", "-size", f"{CANVAS}x{CANVAS}",
            f"gradient:{rgba(sem['bg_normal'], 0.24)}-{rgba(sem['bg_dark'], 0.42)}", ")",
            "-compose", "over", "-composite",
        ]
    cmd += _layer([
        "-fill", rgba(sem["accent"], 0.10), "-draw", "circle 240,155 240,20",
    ], 48)
    cmd += motif_layers(kind, sem)
    cmd += [
        "-fill", sem["accent"], "-stroke", "none",
        "-draw", "roundrectangle 42,350 98,355 2,2",
        "-gravity", "southwest", "-font", font, "-pointsize", str(size),
        "-fill", sem["fg_white"], "-annotate", "+42+48", display,
        "(", "-size", f"{CANVAS}x{CANVAS}", "xc:none", "-fill", "white",
        "-draw", f"roundrectangle 0,0,{CANVAS - 1},{CANVAS - 1},22,22", ")",
        "-alpha", "off", "-compose", "CopyOpacity", "-composite",
        "-compose", "over",
        "(", "-size", f"{CANVAS}x{CANVAS}", "xc:none", "-fill", "none",
        "-stroke", rgba(sem["accent"], 0.88), "-strokewidth", "4",
        "-draw", f"roundrectangle 2,2,{CANVAS - 3},{CANVAS - 3},20,20", ")",
        "-composite", "-resize", f"{w}x{h}!", "-strip", str(out),
    ]
    return cmd


def main(argv: list[str]) -> int:
    size = "480x480"
    if "--size" in argv:
        i = argv.index("--size")
        size = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]
    positional = [a for a in argv if not a.startswith("--")]
    if len(positional) < 2:
        sys.exit(__doc__)
    theme_path, out = Path(positional[0]), Path(positional[1])

    if not shutil.which("magick"):
        sys.exit("genpreview: ImageMagick (`magick`) not found — install imagemagick")

    w, h = (int(v) for v in size.lower().split("x"))
    with theme_path.open("rb") as fh:
        theme = tomllib.load(fh)
    _reject_malformed_theme(theme, theme_path)
    sem = _theme_validators().build_context(theme, lenient=False)["sem"]
    display = theme.get("name", theme_path.parent.name)
    font = resolve_font(theme.get("font", {}).get("family", "JetBrains Mono"))

    out.parent.mkdir(parents=True, exist_ok=True)
    cmd = build_cmd(theme_path.parent.name, sem, display, font, theme_path.parent / "wallpaper.png", out, w, h)
    subprocess.run(cmd, check=True)
    print(f"wrote {out} ({out.stat().st_size} bytes, {w}x{h})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
