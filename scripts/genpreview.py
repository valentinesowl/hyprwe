#!/usr/bin/env python3
"""genpreview.py — generate a theme preview *card* for an HWE theme.

A poster-style card: the theme NAME is the hero (centred, in the theme's bright
text, with an accent underline and a tagline beneath), over the theme's own
wallpaper darkened by a theme-tinted overlay + vignette so the text always
reads. Each theme gets a bit
of its own personality via light per-theme decor (glow / ice particles / sparks
/ leaf corners / scanlines). Colours all come from the [sem] contract, so it
works for every theme with no per-theme colour map.

Cards are SQUARE, and that is load-bearing rather than taste: rofi lays its
element-icon out as a square box of `size` and letterboxes the image inside, so a
16:9 card left ~45px of dead box above and below every row of `hwe theme pick`
(`squared: false` does not apply to element-icon — see templates/rofi/theme.rasi.j2).
The wallpaper is centre-cropped to fill the tile.

Depends on ImageMagick (`magick`) + fontconfig (`fc-match`), both shipped in HWE.
Previews are committed PNGs so a bare install just uses them; regeneration only
runs on a dev box (justfile `previews`).

Usage:
    genpreview.py <theme.toml> <out.png> [--size WxH]
"""
import shutil
import subprocess
import sys
import tomllib
from pathlib import Path

# Short tagline per theme (keyed by directory name). A theme may override this
# with a top-level `tagline = "..."` in its theme.toml; else this map; else "".
TAGLINES = {
    "default":  "Clean · Minimal",
    "ember":    "Warm · Fiery",
    "frost":    "Cool · Icy",
    "garden":   "Fresh · Natural",
    "void":     "Dark · Mysterious",
    "neon":     "Electric · Vibrant",
    "amethyst": "Amethyst · Monochrome",
    "mocha":    "Cozy · Catppuccin",
    "paper":    "Light · Daylight",
    "linen":    "Warm · Soft",
}

# Per-theme decorative personality (keyed by directory name); default "none".
DECOR = {
    "neon":     "glow",
    "amethyst": "glow",
    "frost":    "particles",
    "ember":    "sparks",
    "garden":   "leaves",
    "void":     "scanlines",
}


def _theme_validators():
    """render-theme.py's value validators, loaded by path (its hyphen makes it
    unimportable the normal way). Reusing them keeps ONE definition of "is this a
    safe theme to render" — so a submitted theme is held to the same line here as
    at runtime, before any of its values reach an ImageMagick argument."""
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
    # `name` and `tagline` are drawn onto the card as the text argument of
    # `magick -annotate`, where ImageMagick reads a leading `@` as "the rest is a
    # file to read in" (an arbitrary-file-read that lands in a committed PNG) and
    # expands `%` as a property escape. check_values never sees `tagline`, and
    # neither metacharacter is barred for config output — so both are held here,
    # before either value reaches an ImageMagick argument. A leading space does
    # not help: ImageMagick strips whitespace before testing for the `@`.
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
            problems.append(f"{label} must not begin with '@' (ImageMagick would read it as a file)")
        elif "%" in value:
            problems.append(f"{label} must not contain '%' (ImageMagick would expand it as an escape)")
    if problems:
        sys.exit(f"{path}: refusing a malformed theme:\n  " + "\n  ".join(problems))


def rgba(hexs: str, a: float) -> str:
    h = str(hexs).lstrip("#")
    return f"rgba({int(h[0:2],16)},{int(h[2:4],16)},{int(h[4:6],16)},{a})"


def resolve_font(family: str = "JetBrainsMono Nerd Font") -> str:
    """A concrete font file for ImageMagick (it can't resolve fc family names).

    Takes the theme's own [font].family so the card previews the real typeface —
    Space Mono on neon, Monaspice on garden — not a single hardcoded font. Falls
    back to the JetBrainsMono default (then a built-in) if the family is absent."""
    try:
        f = subprocess.run(
            ["fc-match", "-f", "%{file}", f"{family}:weight=bold"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
        if f:
            return f
    except (OSError, subprocess.CalledProcessError):
        pass
    return "DejaVu-Sans-Bold"  # ImageMagick built-in fallback


def decor_layer(kind: str, sem: dict, w: int, h: int) -> list[str]:
    """A parenthesised ImageMagick layer for a theme's personality, or []."""
    accent = sem["accent"]
    if kind == "glow":  # neon/amethyst: a soft accent halo hugging the edge
        rr = f"roundrectangle 9,9,{w - 10},{h - 10},13,13"
        return ["(", "-size", f"{w}x{h}", "xc:none",
                "-fill", "none", "-stroke", rgba(accent, 0.9), "-strokewidth", "2",
                "-draw", rr, "-blur", "0x4",
                "-stroke", rgba(accent, 0.9), "-strokewidth", "1", "-draw", rr,
                ")", "-compose", "over", "-composite"]
    if kind == "particles":  # frost: cool white specks scattered up high
        col = rgba("#ffffff", 0.45)
        pts = [(.08, .12), (.55, .10), (.88, .16), (.20, .30), (.75, .34),
               (.40, .20), (.94, .70), (.13, .78), (.33, .55), (.66, .62)]
        draws: list[str] = []
        for fx, fy in pts:
            x, y = int(fx * w), int(fy * h)
            draws += ["-draw", f"circle {x},{y} {x + 1},{y}"]
        return ["(", "-size", f"{w}x{h}", "xc:none", "-fill", col, *draws,
                "-blur", "0x1", ")", "-compose", "over", "-composite"]
    if kind == "sparks":  # ember: warm two-tone embers rising from the bottom
        hot = [(.12, .82), (.30, .72), (.62, .86), (.85, .76), (.45, .92), (.72, .66)]
        bright = [(.22, .88), (.52, .78), (.90, .90)]
        draws = ["-fill", rgba(accent, 0.75)]
        for fx, fy in hot:
            x, y = int(fx * w), int(fy * h)
            draws += ["-draw", f"circle {x},{y} {x + 3},{y}"]
        draws += ["-fill", rgba(sem.get("yellow", accent), 0.65)]
        for fx, fy in bright:
            x, y = int(fx * w), int(fy * h)
            draws += ["-draw", f"circle {x},{y} {x + 2},{y}"]
        return ["(", "-size", f"{w}x{h}", "xc:none", *draws,
                "-blur", "0x2", ")", "-compose", "over", "-composite"]
    if kind == "leaves":  # garden: soft rounded blobs in the corners
        s = int(min(w, h) * 0.24)
        blobs = [(6, 6, 6 + s, 6 + s), (w - 7 - s, 6, w - 7, 6 + s),
                 (6, h - 7 - s, 6 + s, h - 7), (w - 7 - s, h - 7 - s, w - 7, h - 7)]
        draws = []
        for x1, y1, x2, y2 in blobs:
            draws += ["-draw", f"roundrectangle {x1},{y1},{x2},{y2},{s},{s}"]
        return ["(", "-size", f"{w}x{h}", "xc:none",
                "-fill", rgba(accent, 0.22), *draws, "-blur", "0x3",
                ")", "-compose", "over", "-composite"]
    if kind == "scanlines":  # void: faint CRT horizontal lines
        return ["(", "-size", f"{w}x2", "xc:none", f"xc:{rgba('#000000', 0.10)}",
                "-append", "-write", "mpr:sl", "+delete",
                "-size", f"{w}x{h}", "tile:mpr:sl", ")",
                "-compose", "over", "-composite"]
    return []


def build_cmd(name: str, sem: dict, disp: str, tag: str, wall: Path, font: str,
              out: Path, w: int, h: int) -> list[str]:
    accent, dark, text = sem["accent"], sem["bg_dark"], sem["fg_white"]

    # base: the theme wallpaper filled to card ratio (softly blurred), or a
    # sem gradient if the wallpaper isn't there yet.
    if wall.is_file():
        base = [str(wall), "-resize", f"{w}x{h}^", "-gravity", "center",
                "-extent", f"{w}x{h}", "-blur", "0x3"]
    else:
        base = ["-size", f"{w}x{h}", f"gradient:{sem['bg_normal']}-{dark}"]

    # a theme-tinted darkening (top->bottom) + vignette so the CENTRED name reads
    overlay = ["(", "-size", f"{w}x{h}",
               f"gradient:{rgba(sem['bg_normal'], 0.55)}-{rgba(dark, 0.80)}", ")",
               "-compose", "over", "-composite",
               "(", "-size", f"{w}x{h}",
               f"radial-gradient:none-{rgba('#000000', 0.45)}", ")",
               "-compose", "over", "-composite"]

    # underline bar (centred, just under the title) as its own layer
    ul_w, ul_h = 64, 3
    underline = ["(", "-size", f"{ul_w}x{ul_h}", f"xc:{accent}", ")",
                 "-gravity", "center", "-geometry", "+0+8", "-compose", "over",
                 "-composite"]

    cmd = ["magick", *base, *overlay]
    cmd += decor_layer(DECOR.get(name, "none"), sem, w, h)
    cmd += [
        # hero name, centred, with a soft drop shadow
        "-gravity", "center", "-font", font,
        "-fill", rgba("#000000", 0.55), "-pointsize", "34", "-annotate", "+2-16", disp,
        "-fill", text, "-pointsize", "34", "-annotate", "+0-18", disp,
    ]
    cmd += underline
    if tag:
        cmd += ["-gravity", "center", "-font", font, "-fill", rgba(text, 0.72),
                "-pointsize", "13", "-annotate", "+0+30", tag]
    cmd += [
        # rounded corners
        "(", "-size", f"{w}x{h}", "xc:none", "-fill", "white",
        "-draw", f"roundrectangle 0,0,{w - 1},{h - 1},18,18", ")",
        "-alpha", "off", "-compose", "CopyOpacity", "-composite",
        # quiet accent border
        "-compose", "over",
        "(", "-size", f"{w}x{h}", "xc:none", "-fill", "none",
        "-stroke", accent, "-strokewidth", "3",
        "-draw", f"roundrectangle 1,1,{w - 2},{h - 2},18,18", ")",
        "-composite",
        str(out),
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
    tdir = theme_path.parent
    name = tdir.name
    with theme_path.open("rb") as fh:
        t = tomllib.load(fh)
    _reject_malformed_theme(t, theme_path)
    sem = t.get("sem", {})
    disp = t.get("name", name.capitalize())
    tag = t.get("tagline", TAGLINES.get(name, ""))
    font = resolve_font(t.get("font", {}).get("family", "JetBrainsMono Nerd Font"))

    out.parent.mkdir(parents=True, exist_ok=True)
    cmd = build_cmd(name, sem, disp, tag, tdir / "wallpaper.png", font, out, w, h)
    subprocess.run(cmd, check=True)
    print(f"wrote {out} ({out.stat().st_size} bytes, {w}x{h})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
