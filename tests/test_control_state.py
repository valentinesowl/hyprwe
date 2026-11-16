import json


def test_snapshot_detail_describes_size_and_local_save_time(control_state):
    detail = control_state.snapshot_detail({
        "saved_at": "2026-11-16T12:34:56",
        "windows": [{}, {}],
        "workspaces": [{}],
    })
    assert detail == "2 windows · 1 workspace · 16.11 · 12:34"
    assert control_state.snapshot_parts({
        "saved_at": "2026-11-16T12:34:56", "windows": [{}, {}], "workspaces": [{}],
    }) == ("2 windows · 1 workspace", "16.11 · 12:34")


def test_snapshot_detail_survives_missing_or_malformed_metadata(control_state):
    assert control_state.snapshot_detail({}) == "0 windows · 0 workspaces · time unknown"
    assert "0 windows · 0 workspaces" in control_state.snapshot_detail({
        "windows": None, "workspaces": "invalid",
    })


def test_motion_duration_honours_the_persistent_personal_setting(control_state, tmp_path):
    config = tmp_path / "hypr.lua"
    config.write_text("  local reduced_motion = true\n")
    assert control_state.motion_duration(config) == 0


def test_motion_duration_ignores_comments_and_missing_config(control_state, tmp_path):
    config = tmp_path / "hypr.lua"
    config.write_text("-- local reduced_motion = true\n")
    assert control_state.motion_duration(config) == 220
    assert control_state.motion_duration(tmp_path / "missing.lua") == 220


def test_session_model_maps_the_active_monitor_and_windows(control_state):
    clients = json.dumps([
        {"mapped": True, "class": "kitty", "workspace": {"id": 1},
         "at": [100, 100], "size": [960, 540]},
        {"mapped": True, "class": "firefox", "workspace": {"id": 2},
         "at": [0, 0], "size": [960, 540]},
        {"mapped": False, "workspace": {"id": 1}, "at": [0, 0], "size": [10, 10]},
    ])
    workspaces = json.dumps([
        {"id": 1, "name": "1", "windows": 1},
        {"id": 2, "name": "2", "windows": 1},
        {"id": -1, "name": "special:scratch", "windows": 1},
    ])
    monitors = json.dumps([{
        "focused": True, "name": "eDP-1", "x": 0, "y": 0,
        "width": 1920, "height": 1080, "scale": 1,
        "activeWorkspace": {"id": 1, "name": "1"},
    }])
    model = control_state.session_model(clients, workspaces, monitors)
    assert model["window_count"] == 2 and model["workspace_count"] == 2
    assert model["active_name"] == "1" and model["monitor"] == "eDP-1"
    assert model["windows"] == [{
        "class": "kitty", "x": 100 / 1920, "y": 100 / 1080,
        "width": 0.5, "height": 0.5, "active": False,
    }]


def test_session_model_uses_logical_monitor_geometry(control_state):
    clients = json.dumps([{
        "mapped": True, "class": "kitty", "workspace": {"id": 1}, "address": "abc",
        "at": [96, 54], "size": [480, 270],
    }])
    workspaces = json.dumps([{"id": 1, "name": "1", "windows": 1}])
    monitors = json.dumps([{
        "focused": True, "name": "HiDPI", "x": 0, "y": 0,
        "width": 1920, "height": 1080, "scale": 2,
        "activeWorkspace": {"id": 1, "name": "1"},
    }])
    window = control_state.session_model(
        clients, workspaces, monitors, '{"address": "abc"}'
    )["windows"][0]
    assert window["x"] == 0.1 and window["y"] == 0.1
    assert window["width"] == 0.5 and window["height"] == 0.5
    assert window["active"] is True


def test_session_model_handles_unavailable_ipc(control_state):
    model = control_state.session_model("invalid", "null", "{}")
    assert model["window_count"] == 0 and model["workspace_count"] == 0
    assert model["active_name"] == "—" and model["monitor"] == "No active monitor"
    assert model["windows"] == [] and model["workspaces"] == []


def test_editor_command_honours_editor_without_mime_dispatch(control_state):
    command = control_state.editor_command("/tmp/hypr.lua", "nvim --nofork")
    assert command == [
        "kitty", "--class", "hwe-config-editor", "nvim", "--nofork", "/tmp/hypr.lua",
    ]


def test_editor_command_falls_back_to_an_available_terminal_editor(control_state):
    preferred = control_state.editor_command(
        "/tmp/hypr.lua", which=lambda name: f"/usr/bin/{name}"
    )
    assert preferred[-2:] == ["nano", "/tmp/hypr.lua"]
    command = control_state.editor_command(
        "/tmp/packages.lst", which=lambda name: "/usr/bin/vim" if name == "vim" else None
    )
    assert command[-2:] == ["vim", "/tmp/packages.lst"]


def test_editor_command_launches_vscode_without_a_terminal_window(control_state):
    assert control_state.editor_command("/tmp/hypr.lua", "code --wait") == [
        "code", "--wait", "/tmp/hypr.lua",
    ]
