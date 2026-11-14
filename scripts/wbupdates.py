#!/usr/bin/env python3
"""Emit pending package updates as one line of Waybar custom-module JSON."""
import contextlib
import html
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ICON = "󰮯"
ICON_MARKUP = f"<span size='8448'>{ICON}</span>"
TOOLTIP_LIMIT = 20
CHECK_INTERVAL = 3600
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


def state_path() -> Path:
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    base = Path(runtime) if runtime else Path.home() / ".cache"
    return base / "hwe" / "updates.json"


def cached_payload(path: Path, stamp: list[list], now: float):
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
        age = now - state["checked_at"]
        if (
            state["database_stamp"] == stamp
            and 0 <= age < CHECK_INTERVAL
            and isinstance(state["payload"], dict)
        ):
            return state["payload"]
    except (OSError, ValueError, TypeError, KeyError):
        pass
    return None


def save_payload(path: Path, stamp: list[list], now: float, result: dict) -> None:
    temporary = path.with_name(f"{path.name}.{os.getpid()}.tmp")
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        state = {"checked_at": now, "database_stamp": stamp, "payload": result}
        temporary.write_text(json.dumps(state, ensure_ascii=False), encoding="utf-8")
        temporary.replace(path)
    except OSError:
        pass
    finally:
        with contextlib.suppress(OSError):
            temporary.unlink()


def emit() -> None:
    now = time.time()
    stamp = [list(item) for item in package_database_stamp()]
    path = state_path()
    result = cached_payload(path, stamp, now)
    if result is None:
        try:
            result = payload(collect())
        except Exception as exc:
            result = {
                "text": f"{ICON_MARKUP} !",
                "tooltip": html.escape(f"Update check failed: {exc}"),
                "class": "error",
            }
        save_payload(path, stamp, now, result)
    print(json.dumps(result, ensure_ascii=False), flush=True)


def main(argv=None) -> int:
    argv = [] if argv is None else argv
    if argv:
        sys.exit("usage: wbupdates.py")
    emit()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
