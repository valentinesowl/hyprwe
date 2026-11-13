#!/usr/bin/env python3
"""Emit pending package updates as one line of Waybar custom-module JSON."""
import contextlib
import html
import json
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ICON = "󰮯"
ICON_MARKUP = f"<span size='11px'>{ICON}</span>"
TOOLTIP_LIMIT = 20
CHECK_INTERVAL = 3600
WATCH_INTERVAL = 10
PACKAGE_DATABASES = (Path("/var/lib/pacman/local"), Path("/var/lib/dpkg/status"))


def parse_checkupdates(text: str) -> list[tuple[str, str, str]]:
    updates = []
    for line in text.splitlines():
        parts = line.split()
        if len(parts) == 4 and parts[2] == "->":
            updates.append((parts[0], parts[1], parts[3]))
    return updates


def parse_apt(text: str) -> list[tuple[str, str, str]]:
    pattern = re.compile(r"^Inst\s+(\S+)\s+\[([^\]]+)\]\s+\((\S+)", re.MULTILINE)
    return pattern.findall(text)


def collect(run=subprocess.run, which=shutil.which) -> list[tuple[str, str, str]]:
    if which("checkupdates"):
        result = run(
            ["checkupdates", "--nocolor"],
            capture_output=True, text=True, timeout=60, check=False,
        )
        if result.returncode not in (0, 2):
            raise RuntimeError(result.stderr.strip() or "checkupdates failed")
        return parse_checkupdates(result.stdout)
    if which("apt-get"):
        result = run(
            ["apt-get", "-s", "upgrade"],
            capture_output=True, text=True, timeout=60, check=False,
        )
        if result.returncode:
            raise RuntimeError(result.stderr.strip() or "apt-get simulation failed")
        return parse_apt(result.stdout)
    raise RuntimeError("neither checkupdates nor apt-get is installed")


def payload(updates: list[tuple[str, str, str]]) -> dict:
    if not updates:
        return {"text": "", "tooltip": "System is up to date", "class": "empty"}
    lines = [f"{name}: {old} → {new}" for name, old, new in updates[:TOOLTIP_LIMIT]]
    remaining = len(updates) - len(lines)
    if remaining:
        lines.append(f"… and {remaining} more")
    tooltip = f"Package updates available: {len(updates)}\n" + "\n".join(lines)
    return {
        "text": f"{ICON_MARKUP} {len(updates)}",
        "tooltip": html.escape(tooltip),
        "class": "available",
    }


def package_database_stamp(paths=PACKAGE_DATABASES) -> tuple[tuple[str, int], ...]:
    stamps = []
    for path in paths:
        with contextlib.suppress(OSError):
            stamps.append((str(path), path.stat().st_mtime_ns))
    return tuple(stamps)


def emit() -> None:
    try:
        result = payload(collect())
    except Exception as exc:
        result = {
            "text": f"{ICON_MARKUP} !",
            "tooltip": html.escape(f"Update check failed: {exc}"),
            "class": "error",
        }
    print(json.dumps(result, ensure_ascii=False), flush=True)


def main(argv=None) -> int:
    argv = [] if argv is None else argv
    if any(arg != "--watch" for arg in argv):
        sys.exit("usage: wbupdates.py [--watch]")
    emit()
    if "--watch" not in argv:
        return 0

    checked = time.monotonic()
    previous_stamp = package_database_stamp()
    while True:
        time.sleep(WATCH_INTERVAL)
        stamp = package_database_stamp()
        now = time.monotonic()
        if stamp != previous_stamp or now - checked >= CHECK_INTERVAL:
            emit()
            previous_stamp = stamp
            checked = now


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
