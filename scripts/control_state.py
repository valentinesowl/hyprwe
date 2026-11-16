import json
import shlex
import shutil
from datetime import datetime


def editor_command(path, editor=None, which=shutil.which):
    command = shlex.split(editor) if editor else []
    gui_editors = {
        "atom", "code", "code-insiders", "codium", "vscodium", "vscode",
        "gedit", "geany", "kate", "mousepad", "subl", "sublime_text", "zed",
    }
    if command and command[0].rsplit("/", 1)[-1] in gui_editors:
        return [*command, str(path)]
    if not command:
        command = [next(
            (candidate for candidate in ("nano", "nvim", "vim", "vi") if which(candidate)),
            "vi",
        )]
    return ["kitty", "--class", "hwe-config-editor", *command, str(path)]


def session_model(clients_output, workspaces_output, monitors_output, active_window_output=None):
    def parsed_list(output):
        try:
            value = json.loads(output)
            return value if isinstance(value, list) else []
        except (TypeError, json.JSONDecodeError):
            return []

    clients = [item for item in parsed_list(clients_output) if isinstance(item, dict)]
    workspaces = [item for item in parsed_list(workspaces_output) if isinstance(item, dict)]
    monitors = [item for item in parsed_list(monitors_output) if isinstance(item, dict)]
    try:
        active_window = json.loads(active_window_output) if active_window_output else {}
    except (TypeError, json.JSONDecodeError):
        active_window = {}
    active_address = active_window.get("address") if isinstance(active_window, dict) else None
    mapped = [item for item in clients if item.get("mapped", True)]
    regular = [
        item for item in workspaces if not str(item.get("name", "")).startswith("special:")
    ]
    monitor = next((item for item in monitors if item.get("focused")), None)
    if monitor is None and monitors:
        monitor = monitors[0]
    monitor = monitor or {}
    active = monitor.get("activeWorkspace", {})
    active_id = active.get("id") if isinstance(active, dict) else None
    scale = monitor.get("scale", 1) or 1
    monitor_width = max(1, monitor.get("width", 1) / scale)
    monitor_height = max(1, monitor.get("height", 1) / scale)
    windows = []
    for client in mapped:
        workspace = client.get("workspace", {})
        if not isinstance(workspace, dict) or workspace.get("id") != active_id:
            continue
        at = client.get("at", [0, 0])
        size = client.get("size", [0, 0])
        if not isinstance(at, list) or not isinstance(size, list) or len(at) != 2 or len(size) != 2:
            continue
        x = min(1.0, max(0.0, (at[0] - monitor.get("x", 0)) / monitor_width))
        y = min(1.0, max(0.0, (at[1] - monitor.get("y", 0)) / monitor_height))
        width = min(1.0 - x, max(0.0, size[0] / monitor_width))
        height = min(1.0 - y, max(0.0, size[1] / monitor_height))
        windows.append({
            "class": client.get("class", "unknown"), "x": x, "y": y,
            "width": width, "height": height,
            "active": active_address is not None and client.get("address") == active_address,
        })
    return {
        "window_count": len(mapped),
        "workspace_count": len(regular),
        "active_name": active.get("name", "—") if isinstance(active, dict) else "—",
        "monitor": monitor.get("name", "No active monitor"),
        "windows": windows,
        "workspaces": [
            {"name": item.get("name", "?"), "windows": item.get("windows", 0)}
            for item in sorted(regular, key=lambda item: item.get("id", 0))
        ],
    }


def count_detail(windows, workspaces):
    window_label = "window" if windows == 1 else "windows"
    workspace_label = "workspace" if workspaces == 1 else "workspaces"
    return f"{windows} {window_label} · {workspaces} {workspace_label}"


def snapshot_parts(data):
    windows = data.get("windows", []) if isinstance(data, dict) else []
    workspaces = data.get("workspaces", []) if isinstance(data, dict) else []
    window_count = len(windows) if isinstance(windows, list) else 0
    workspace_count = len(workspaces) if isinstance(workspaces, list) else 0
    saved_at = data.get("saved_at") if isinstance(data, dict) else None
    try:
        saved = datetime.fromisoformat(saved_at).astimezone().strftime("%d.%m · %H:%M")
    except (TypeError, ValueError):
        saved = "time unknown"
    return count_detail(window_count, workspace_count), saved


def snapshot_detail(data):
    counts, saved = snapshot_parts(data)
    return f"{counts} · {saved}"


def motion_duration(config, default=220):
    try:
        disabled = any(
            line.strip() == "local reduced_motion = true"
            for line in config.read_text().splitlines()
        )
    except OSError:
        disabled = False
    return 0 if disabled else default
