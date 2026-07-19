#!/usr/bin/env python3
"""fontlock.py — gather the evidence for pinning a font HWE fetches itself.

HWE installs fonts from the distribution's signed packages wherever it can. One
font cannot come that way: the Nerd Fonts icon glyphs are not in Ubuntu's archive
at all, so on that side HWE downloads them. That download is the only artifact in
the project that arrives without a distribution's signature behind it, and the
upstream release publishes no checksums and no signatures of its own.

Pinning a SHA-256 fixes that only halfway. It guarantees that what a user gets is
what the maintainer saw — it says nothing about whether what the maintainer saw
was safe. A font is not executed, but every application parses it: crafted tables
and hinting bytecode are the attack surface, and a malicious one need not reveal
itself immediately. So a hash alone is a signature under "I downloaded this",
which is not a claim worth making.

This tool collects what CAN be checked, so the claim becomes worth making:

  1. CORROBORATION — compare the downloaded font byte for byte against the same
     font as installed from a signed distribution package. Arch ships
     ttf-nerd-fonts-symbols-mono, built by its maintainers from this same
     upstream release and delivered over a signature chain pacman verified. If
     the bytes are identical, the pin says "these are the bytes Arch reviewed
     and signed", which is a second party, not just us.
  2. STRUCTURE — parse every table with fontTools and report anything a
     well-formed font would not contain. This is what catches a file shaped to
     hit a parser bug rather than to render.
  3. IDENTITY — what the font declares itself to be, so a swapped asset with a
     matching name is visible.

What it cannot do, stated plainly: none of this proves the font is benign. A
well-formed font can still carry a payload aimed at a specific parser bug. The
defensible claim is "the same bytes a distribution signed, structurally sound,
and watched for silent replacement" — not "safe".

    scripts/fontlock.py --check        # report only, write nothing
    scripts/fontlock.py --write        # ...and update pkg/fonts.lock

Maintainer tooling: it runs from `just fonts-lock`, never at install time, so it
may use any library it likes (fontTools comes from python-fonttools).
"""
from __future__ import annotations

import argparse
import hashlib
import io
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LOCK = REPO / "pkg" / "fonts.lock"

# What we fetch, and what a distribution calls the same thing. `reference` is the
# path the signed package installs to — the corroboration in step 1 above.
FONTS = [
    {
        "id": "symbols-mono",
        "url": "https://github.com/ryanoasis/nerd-fonts/releases/download/v3.4.0/NerdFontsSymbolsOnly.tar.xz",
        "member": "SymbolsNerdFontMono-Regular.ttf",
        "arch_package": "ttf-nerd-fonts-symbols-mono",
        "reference": "/usr/share/fonts/TTF/SymbolsNerdFontMono-Regular.ttf",
    },
]


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def fetch(url: str) -> bytes:
    print(f"  fetching {url}")
    with urllib.request.urlopen(url, timeout=120) as r:
        return r.read()


def extract(archive: bytes, member: str) -> bytes:
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:xz") as tf:
        for name in tf.getnames():
            if Path(name).name == member:
                f = tf.extractfile(name)
                if f:
                    return f.read()
    raise SystemExit(f"'{member}' is not in the archive — upstream changed its layout")


def corroborate(font: bytes, spec: dict) -> tuple[bool, str]:
    """Compare against the same font from a signed distribution package."""
    ref = Path(spec["reference"])
    if not ref.is_file():
        return False, (
            f"no local reference — install {spec['arch_package']} to compare against "
            f"a signed package (this is the strongest check available)"
        )
    local = ref.read_bytes()
    if local == font:
        return True, f"identical to {ref} from {spec['arch_package']}"
    return False, (
        f"DIFFERS from {ref} ({len(local)} bytes local vs {len(font)} downloaded) — "
        "do not pin this until you know why"
    )


def verify_package_file(spec: dict) -> str:
    """Ask the package manager whether the reference file is still what it shipped.
    The corroboration is only worth as much as the reference it compares to."""
    if not shutil.which("pacman"):
        return "pacman not available — reference integrity unverified"
    # LC_ALL=C so the branches below match pacman's own words rather than a
    # translation of them.
    r = subprocess.run(
        ["pacman", "-Qkk", spec["arch_package"]],
        capture_output=True, text=True, env={"LC_ALL": "C", "PATH": "/usr/bin:/bin"},
    )
    out = (r.stdout + r.stderr).strip()
    # A non-zero exit is "not installed" as readily as "files are altered", and
    # reporting the former as a passed check would be a false reassurance about
    # a reference that does not exist.
    if r.returncode != 0 or not out:
        if "was not found" in out or "not found" in out.lower():
            return f"{spec['arch_package']} is NOT INSTALLED — nothing to compare against"
        return f"pacman could not verify {spec['arch_package']}: {out.splitlines()[0] if out else 'no output'}"
    # pacman's summary line is "N total files, M altered files" — so the word
    # "altered" is present whether or not anything was. Read the COUNT. Matching
    # on the word alone cried wolf on a clean package, and a check that cries
    # wolf is one you learn to scroll past, which is worse than not having it.
    altered = re.search(r"(\d+)\s+altered files", out)
    if altered and int(altered.group(1)) > 0:
        return f"reference file was MODIFIED since install: {altered.group(0)}"
    warnings = [ln for ln in out.splitlines() if "warning:" in ln.lower()]
    if warnings:
        return "pacman warned about the reference: " + "; ".join(warnings[:2])
    total = re.search(r"(\d+)\s+total files", out)
    counted = f", {total.group(0)} checked" if total else ""
    return f"reference verified against the package DB ({spec['arch_package']}{counted})"


def structure(font: bytes) -> tuple[bool, list[str]]:
    """Parse every table. Anything that fails to parse, or a table we have no
    business seeing in a glyph font, is worth a human look."""
    try:
        from fontTools.ttLib import TTFont
    except ImportError:
        return False, ["python-fonttools is not installed — structural check skipped"]

    notes: list[str] = []
    try:
        tt = TTFont(io.BytesIO(font), fontNumber=0, lazy=False)
        tables = sorted(tt.keys())
        for tag in tables:
            _ = tt[tag]  # force decompile; a malformed table raises here
        notes.append(f"{len(tables)} tables parsed: {' '.join(tables)}")

        # Tables that carry executable hinting bytecode. Their presence is normal
        # in a TrueType font; their SIZE is what is worth a glance, because the
        # interpreter that runs them has been a CVE source.
        for tag in ("fpgm", "prep", "cvt "):
            if tag in tt.reader.tables:
                notes.append(f"  hinting table {tag.strip()}: {tt.reader.tables[tag].length} bytes")

        name = tt["name"].getDebugName(4) or "?"
        version = tt["name"].getDebugName(5) or "?"
        glyphs = len(tt.getGlyphOrder())
        notes.append(f"  identifies as: {name!r} / {version!r} / {glyphs} glyphs")
        return True, notes
    except Exception as exc:
        return False, [f"FAILED to parse: {type(exc).__name__}: {exc}"]


def read_lock() -> dict[str, dict[str, str]]:
    out: dict[str, dict[str, str]] = {}
    if not LOCK.is_file():
        return out
    for raw in LOCK.read_text().splitlines():
        # Only the comment and the leading indent may be stripped: an UNPINNED
        # row ends in an empty hash field, and .strip() would eat the tab that
        # holds its place — turning "no maintainer vouched for this" into
        # "malformed line", which reads as the same thing for the wrong reason.
        line = raw.split("#", 1)[0].rstrip("\r\n").lstrip()
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) >= 4:
            parts += ["-"] * (5 - len(parts))
            # `-` is the unpinned marker (see pkg/fonts.lock for why it is not an
            # empty field); normalise it to "" so callers test truthiness.
            parts = [("" if p == "-" else p) for p in parts]
            out[parts[0]] = {
                "url": parts[1], "archive_sha256": parts[2],
                "member": parts[3], "file_sha256": parts[4],
            }
    return out


def write_lock(rows: list[tuple[str, str, str, str, str]]) -> None:
    header = (
        "# pkg/fonts.lock — the fonts HWE fetches itself, pinned.\n"
        "#\n"
        "# HWE takes fonts from the distribution's signed packages wherever it can.\n"
        "# What is listed here is what no distribution packages, so it is downloaded\n"
        "# — and it is the only artifact in the project that arrives without a\n"
        "# distribution signature behind it. The install refuses to use a file whose\n"
        "# hash is not here, and refuses an entry whose hash is blank.\n"
        "#\n"
        "# Regenerate the evidence, and read it, before changing a line:\n"
        "#     just fonts-lock\n"
        "# It compares the download byte for byte against the same font from a signed\n"
        "# Arch package, parses every table, and reports what the font claims to be.\n"
        "# A hash here is the maintainer's word that they read that report — not a\n"
        "# claim that the font is safe. See scripts/fontlock.py for what that is worth.\n"
        "#\n"
        "# id\turl\tarchive_sha256\tmember\tfile_sha256\n"
    )
    body = "".join("\t".join(r) + "\n" for r in rows)
    LOCK.write_text(header + body)
    print(f"\nwrote {LOCK.relative_to(REPO)}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--write", action="store_true", help="update pkg/fonts.lock")
    args = ap.parse_args()

    existing = read_lock()
    rows: list[tuple[str, str, str, str, str]] = []
    verdict_ok = True

    for spec in FONTS:
        print(f"\n=== {spec['id']} ===")
        archive = fetch(spec["url"])
        a_hash = sha256(archive)
        font = extract(archive, spec["member"])
        f_hash = sha256(font)
        print(f"  archive sha256: {a_hash}")
        print(f"  {spec['member']}: {len(font)} bytes, sha256 {f_hash}")

        print("\n  [1] corroboration against a signed distribution package")
        print(f"      {verify_package_file(spec)}")
        same, why = corroborate(font, spec)
        print(f"      {'MATCH' if same else 'NO MATCH'}: {why}")
        verdict_ok &= same

        print("\n  [2] structure")
        parsed, notes = structure(font)
        for n in notes:
            print(f"      {n}")
        verdict_ok &= parsed

        print("\n  [3] change since the current lock")
        prev = existing.get(spec["id"])
        if not prev or not prev["file_sha256"]:
            print("      not pinned yet — this would be the first pin")
        elif prev["file_sha256"] == f_hash:
            print("      unchanged from the pinned hash")
        else:
            print(f"      CHANGED: pinned {prev['file_sha256'][:16]}… now {f_hash[:16]}…")
            print("      upstream replaced a published asset — find out why before pinning")
            verdict_ok = False

        rows.append((spec["id"], spec["url"], a_hash, spec["member"], f_hash))

    print("\n" + "=" * 70)
    if verdict_ok:
        print("every check passed. Pinning is YOUR call: the checks above say the bytes")
        print("match what a distribution signed and the file parses cleanly. They do not")
        print("say it is safe — nothing here can.")
    else:
        print("SOMETHING DID NOT CHECK OUT — read the report above before pinning.")

    if args.write:
        if not verdict_ok:
            print("\nrefusing --write while a check is failing")
            return 1
        write_lock(rows)
    else:
        print("\n(report only; pass --write to update pkg/fonts.lock)")
    return 0 if verdict_ok else 1


if __name__ == "__main__":
    sys.exit(main())
