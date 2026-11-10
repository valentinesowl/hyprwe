#!/usr/bin/env python3
"""Named Hyprland session snapshots for `hwe session`."""

import argparse
import contextlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from collections.abc import Callable
from datetime import datetime
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
APP_COMMANDS = {
    "org.telegram.desktop": "telegram-desktop",
}


class SessionError(Exception):
    pass


def valid_name(name: str) -> bool:
    return bool(NAME_RE.fullmatch(name))


def default_store() -> Path:
    override = os.environ.get("HWE_SESSION_DIR")
    if override:
        return Path(override)
    state = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state"))
    return state / "hwe" / "sessions"


def atomic_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent, text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def atomic_json(path: Path, data: dict[str, Any]) -> None:
    atomic_text(path, json.dumps(data, ensure_ascii=False, indent=2) + "\n")


class Store:
    def __init__(self, root: Path):
        self.root = root

    def path(self, name: str) -> Path:
        if not valid_name(name):
            raise SessionError(f"invalid session name: {name!r}")
        return self.root / f"{name}.json"

    def save(self, name: str, snapshot: dict[str, Any]) -> Path:
        path = self.path(name)
        atomic_json(path, snapshot)
        return path

    def load(self, name: str) -> dict[str, Any]:
        path = self.path(name)
        if not path.is_file():
            raise SessionError(f"session not found: {name}")
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise SessionError(f"cannot read session {name!r}: {error}") from error
        if data.get("version") != SCHEMA_VERSION or not isinstance(data.get("windows"), list):
            raise SessionError(f"session {name!r} has an unsupported or invalid format")
        if not isinstance(data.get("workspaces"), list) or not isinstance(data.get("monitors"), list):
            raise SessionError(f"session {name!r} is incomplete")
        return data

    def list(self) -> list[dict[str, Any]]:
        if not self.root.is_dir():
            return []
        result = []
        for path in sorted(self.root.glob("*.json")):
            if valid_name(path.stem):
                result.append(self.load(path.stem))
        return result

    def clear(self, name: str) -> bool:
        path = self.path(name)
        if not path.is_file():
            return False
        path.unlink()
        return True

    def clear_all(self) -> int:
        snapshots = self.list()
        for snapshot in snapshots:
            self.clear(snapshot["name"])
        return len(snapshots)


def command_for(client: dict[str, Any], proc: Path = Path("/proc")) -> list[str]:
    pid = client.get("pid")
    if isinstance(pid, int) and pid > 0:
        try:
            executable = os.readlink(proc / str(pid) / "exe")
            if executable.endswith(" (deleted)"):
                executable = executable[: -len(" (deleted)")]
            if executable and Path(executable).is_file():
                return [executable]
        except OSError:
            pass

    class_name = client.get("class") or client.get("initialClass") or ""
    candidates = [APP_COMMANDS.get(class_name, class_name)]
    if class_name == "kitty":
        candidates.append("kitty")
    for candidate in candidates:
        if candidate and (executable := shutil.which(candidate)):
            return [executable]
    return []


def identity(client: dict[str, Any]) -> str:
    return (client.get("class") or client.get("initialClass") or "").casefold()


def client_sort_key(client: dict[str, Any]) -> tuple[str, str]:
    return (str(client.get("stableId", "")), str(client.get("address", "")))


def make_snapshot(
    clients: list[dict[str, Any]],
    monitors: list[dict[str, Any]],
    workspaces: list[dict[str, Any]],
    active_workspace: dict[str, Any],
    active_window: dict[str, Any],
    command_resolver: Callable[[dict[str, Any]], list[str]] = command_for,
) -> dict[str, Any]:
    monitor_by_id = {monitor.get("id"): monitor for monitor in monitors}
    saved_clients = sorted(
        (client for client in clients if client.get("mapped", True)),
        key=client_sort_key,
    )
    windows = []
    active_index = None
    for client in saved_clients:
        monitor = monitor_by_id.get(client.get("monitor"), {})
        window = {
            "class": client.get("class") or client.get("initialClass") or "",
            "command": command_resolver(client),
            "workspace": client.get("workspace", {}).get("name")
            or str(client.get("workspace", {}).get("id", "")),
            "monitor": monitor.get("name", ""),
            "at": list(client.get("at", [0, 0])),
            "size": list(client.get("size", [1, 1])),
            "fullscreen": int(client.get("fullscreen", 0)),
        }
        if client.get("address") == active_window.get("address"):
            active_index = len(windows)
        windows.append(window)

    saved_workspaces = [
        {
            "name": workspace.get("name") or str(workspace.get("id", "")),
            "monitor": workspace.get("monitor", ""),
        }
        for workspace in workspaces
        if workspace.get("name") or workspace.get("id") is not None
    ]
    return {
        "version": SCHEMA_VERSION,
        "name": "",
        "saved_at": datetime.now().astimezone().isoformat(timespec="seconds"),
        "active_workspace": active_workspace.get("name") or str(active_workspace.get("id", "")),
        "active_window": active_index,
        "monitors": [
            {
                "id": monitor.get("id"),
                "name": monitor.get("name", ""),
                "x": monitor.get("x", 0),
                "y": monitor.get("y", 0),
                "width": monitor.get("width", 1),
                "height": monitor.get("height", 1),
                "scale": monitor.get("scale", 1),
            }
            for monitor in monitors
        ],
        "workspaces": saved_workspaces,
        "windows": windows,
    }


def match_windows(
    saved: list[dict[str, Any]], current: list[dict[str, Any]]
) -> dict[int, dict[str, Any]]:
    available = sorted(
        (client for client in current if client.get("mapped", True)),
        key=client_sort_key,
    )
    used: set[str] = set()
    matches = {}
    for index, window in enumerate(saved):
        wanted = identity(window)
        for client in available:
            address = str(client.get("address", ""))
            if address in used or identity(client) != wanted:
                continue
            matches[index] = client
            used.add(address)
            break
    return matches


def transform_box(
    window: dict[str, Any],
    source_monitor: dict[str, Any],
    target_monitor: dict[str, Any],
) -> dict[str, int]:
    source = source_monitor or target_monitor
    sx, sy = source.get("x", 0), source.get("y", 0)
    sw = max(1, source.get("width", target_monitor.get("width", 1)))
    sh = max(1, source.get("height", target_monitor.get("height", 1)))
    tx, ty = target_monitor.get("x", 0), target_monitor.get("y", 0)
    tw = max(1, target_monitor.get("width", sw))
    th = max(1, target_monitor.get("height", sh))
    at = window.get("at", [sx, sy])
    size = window.get("size", [sw, sh])
    return {
        "x": round(tx + (at[0] - sx) * tw / sw),
        "y": round(ty + (at[1] - sy) * th / sh),
        "w": max(1, round(size[0] * tw / sw)),
        "h": max(1, round(size[1] * th / sh)),
    }


def restore_payload(
    snapshot: dict[str, Any],
    matches: dict[int, dict[str, Any]],
    current_monitors: list[dict[str, Any]],
) -> dict[str, Any]:
    if not current_monitors:
        raise SessionError("no monitor is available for the restore")
    by_name = {monitor.get("name"): monitor for monitor in current_monitors}
    fallback = next((m for m in current_monitors if m.get("focused")), current_monitors[0])
    source_by_name = {monitor.get("name"): monitor for monitor in snapshot["monitors"]}

    def target_monitor(name: str) -> dict[str, Any]:
        return by_name.get(name, fallback)

    boxes = {}
    for index, client in matches.items():
        window = snapshot["windows"][index]
        name = window.get("monitor", "")
        boxes[str(client["stableId"])] = transform_box(
            window, source_by_name.get(name, {}), target_monitor(name)
        )

    workspaces = []
    for workspace in snapshot["workspaces"]:
        name = workspace.get("monitor", "")
        workspaces.append({"name": workspace["name"], "monitor": target_monitor(name)["name"]})
    return {"boxes": boxes, "workspaces": workspaces}


def lua_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def runtime_lua(payload: dict[str, Any]) -> str:
    lines = ["return {", "  boxes = {"]
    for stable_id, box in sorted(payload["boxes"].items()):
        lines.append(
            f"    [{lua_string(stable_id)}] = "
            f"{{ x = {box['x']}, y = {box['y']}, w = {box['w']}, h = {box['h']} }},"
        )
    lines.extend(["  },", "  workspaces = {"])
    for workspace in payload["workspaces"]:
        lines.append(
            f"    {{ name = {lua_string(workspace['name'])}, "
            f"monitor = {lua_string(workspace['monitor'])} }},"
        )
    lines.extend(["  },", "}", ""])
    return "\n".join(lines)


class Hyprctl:
    def _run(self, *args: str) -> str:
        result = subprocess.run(
            ["hyprctl", *args], capture_output=True, text=True, check=False
        )
        if result.returncode != 0:
            detail = result.stderr.strip() or result.stdout.strip() or "unknown hyprctl error"
            raise SessionError(detail)
        return result.stdout

    def query(self, topic: str) -> Any:
        try:
            return json.loads(self._run(topic, "-j"))
        except json.JSONDecodeError as error:
            raise SessionError(f"hyprctl {topic} returned invalid JSON") from error

    def dispatch(self, expression: str) -> None:
        self._run("dispatch", expression)

    def evaluate(self, expression: str) -> None:
        self._run("eval", expression)


def selector(client: dict[str, Any]) -> str:
    return f"address:{client['address']}"


def default_spawn(command: list[str]) -> None:
    subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def restore_session(
    snapshot: dict[str, Any],
    hypr: Hyprctl,
    runtime_path: Path,
    spawn: Callable[[list[str]], None] = default_spawn,
    sleep: Callable[[float], None] = time.sleep,
    timeout: float = 15.0,
) -> dict[str, Any]:
    saved = snapshot["windows"]
    current_monitors = hypr.query("monitors")
    matches = match_windows(saved, hypr.query("clients"))
    missing_commands = []
    for index, window in enumerate(saved):
        if index not in matches and window.get("command"):
            missing_commands.append(window["command"])

    for command in missing_commands:
        with contextlib.suppress(OSError):
            spawn(command)

    deadline = time.monotonic() + max(0, timeout)
    while len(matches) < len(saved) and missing_commands and time.monotonic() < deadline:
        sleep(0.2)
        matches = match_windows(saved, hypr.query("clients"))

    for index, client in matches.items():
        window = saved[index]
        target = selector(client)
        hypr.dispatch(f'hl.dsp.window.float({{ action = "disable", window = "{target}" }})')
        hypr.dispatch(
            "hl.dsp.window.move({ workspace = "
            f"{lua_string(window['workspace'])}, window = \"{target}\" }})"
        )

    payload = restore_payload(snapshot, matches, current_monitors)
    atomic_text(runtime_path, runtime_lua(payload))
    hypr.evaluate(f"HWE_SESSION_RESTORE(dofile({lua_string(str(runtime_path))}))")

    for index, client in matches.items():
        fullscreen = int(saved[index].get("fullscreen", 0))
        if fullscreen:
            mode = "maximized" if fullscreen == 1 else "fullscreen"
            hypr.dispatch(
                f'hl.dsp.window.fullscreen({{ mode = "{mode}", action = "set", '
                f'window = "{selector(client)}" }})'
            )

    if snapshot.get("active_workspace"):
        hypr.dispatch(
            "hl.dsp.focus({ workspace = "
            f"{lua_string(snapshot['active_workspace'])} }})"
        )
    active_index = snapshot.get("active_window")
    if isinstance(active_index, int) and active_index in matches:
        hypr.dispatch(f'hl.dsp.focus({{ window = "{selector(matches[active_index])}" }})')

    missing = [window for index, window in enumerate(saved) if index not in matches]
    return {"restored": len(matches), "missing": missing, "payload": payload}


def print_list(snapshots: list[dict[str, Any]]) -> None:
    if not snapshots:
        print("no saved sessions")
        return
    rows = []
    for snapshot in snapshots:
        rows.append(
            (
                snapshot["name"],
                snapshot.get("saved_at", "unknown"),
                str(len(snapshot["windows"])),
                str(len(snapshot["workspaces"])),
                str(len(snapshot["monitors"])),
            )
        )
    headers = ("NAME", "SAVED", "WINDOWS", "WORKSPACES", "MONITORS")
    widths = [max(len(headers[i]), *(len(row[i]) for row in rows)) for i in range(len(headers))]
    for row in [headers, *rows]:
        print("  ".join(value.ljust(widths[i]) for i, value in enumerate(row)).rstrip())


def run(args: argparse.Namespace, store: Store, hypr: Hyprctl) -> None:
    if args.action == "save":
        store.path(args.name)
        snapshot = make_snapshot(
            hypr.query("clients"),
            hypr.query("monitors"),
            hypr.query("workspaces"),
            hypr.query("activeworkspace"),
            hypr.query("activewindow"),
        )
        if not snapshot["windows"]:
            raise SessionError("there are no mapped windows to save")
        snapshot["name"] = args.name
        path = store.save(args.name, snapshot)
        print(
            f"saved session {args.name!r}: {len(snapshot['windows'])} windows, "
            f"{len(snapshot['workspaces'])} workspaces, {len(snapshot['monitors'])} monitors"
        )
        print(f"state: {path}")
        return

    if args.action == "list":
        print_list(store.list())
        return

    if args.action == "clear":
        if args.all:
            count = store.clear_all()
            print(f"deleted {count} saved session(s)")
        elif store.clear(args.name):
            print(f"deleted session {args.name!r}")
        else:
            raise SessionError(f"session not found: {args.name}")
        return

    snapshot = store.load(args.name)
    result = restore_session(
        snapshot,
        hypr,
        store.root.parent / "restore-layout.lua",
        timeout=float(os.environ.get("HWE_SESSION_RESTORE_TIMEOUT", "15")),
    )
    for window in result["missing"]:
        print(f"warning: could not restore {window['class']!r}", file=sys.stderr)
    print(f"restored session {args.name!r}: {result['restored']} window(s)")
    if result["missing"]:
        print(f"missing: {len(result['missing'])} window(s)", file=sys.stderr)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="hwe session")
    subparsers = parser.add_subparsers(dest="action", required=True)
    for action in ("save", "restore"):
        sub = subparsers.add_parser(action)
        sub.add_argument("name")
    subparsers.add_parser("list")
    clear = subparsers.add_parser("clear")
    clear.add_argument("name", nargs="?", default="")
    clear.add_argument("--all", action="store_true")
    args = parser.parse_args(argv)
    if args.action == "clear" and bool(args.name) == bool(args.all):
        parser.error("clear requires exactly one name or --all")

    try:
        run(args, Store(default_store()), Hyprctl())
    except (SessionError, OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
