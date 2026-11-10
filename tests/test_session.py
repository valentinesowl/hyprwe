import argparse
import stat

import pytest


def client(class_name="kitty", address="0x1", stable_id="1", workspace="1", pid=100):
    return {
        "address": address,
        "stableId": stable_id,
        "mapped": True,
        "class": class_name,
        "initialClass": class_name,
        "pid": pid,
        "monitor": 0,
        "workspace": {"id": 9, "name": workspace},
        "at": [966, 35],
        "size": [945, 512],
        "fullscreen": 0,
        "title": "private title that must not be persisted",
    }


def monitor(name="eDP-1", focused=True):
    return {
        "id": 0,
        "name": name,
        "x": 0,
        "y": 0,
        "width": 1920,
        "height": 1080,
        "scale": 1,
        "focused": focused,
    }


def snapshot(session, windows=None):
    windows = windows if windows is not None else [client()]
    result = session.make_snapshot(
        windows,
        [monitor()],
        [{"id": 9, "name": "9", "monitor": "eDP-1"}],
        {"id": 9, "name": "9"},
        windows[0],
        command_resolver=lambda current: [f"/usr/bin/{current['class']}"],
    )
    result["name"] = "test"
    return result


def minimal_snapshot(name="one"):
    return {
        "version": 1,
        "name": name,
        "saved_at": "2026-11-10T00:00:00+03:00",
        "active_workspace": "1",
        "active_window": None,
        "monitors": [],
        "workspaces": [],
        "windows": [],
    }


@pytest.mark.parametrize("name", ["1", "work", "project.2", "a_b-c"])
def test_session_names_are_valid(session, name):
    assert session.valid_name(name)


@pytest.mark.parametrize("name", ["", "../escape", "a/b", "-dash", "two words", ".hidden"])
def test_session_names_cannot_escape_or_become_options(session, name):
    assert not session.valid_name(name)


def test_store_round_trip_list_and_clear(session, tmp_path):
    store = session.Store(tmp_path / "sessions")
    path = store.save("one", minimal_snapshot())
    assert store.load("one")["name"] == "one"
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert [item["name"] for item in store.list()] == ["one"]
    assert store.clear("one")
    assert store.list() == []
    assert not store.clear("one")


def test_store_rejects_malformed_names_before_creating_paths(session, tmp_path):
    store = session.Store(tmp_path / "sessions")
    with pytest.raises(session.SessionError):
        store.save("../escape", minimal_snapshot())
    assert not (tmp_path / "sessions").exists()


def test_snapshot_covers_every_workspace_without_private_window_metadata(session):
    second = client("firefox", "0x2", "2", "2", 200)
    hidden = client("hidden", "0x3", "3", "3", 300)
    hidden["mapped"] = False
    result = snapshot(session, [client(), second, hidden])
    assert len(result["windows"]) == 2
    assert result["active_window"] == 0
    assert result["active_workspace"] == "9"
    assert result["workspaces"] == [{"name": "9", "monitor": "eDP-1"}]
    assert all("title" not in window and "pid" not in window for window in result["windows"])
    assert result["windows"][1]["workspace"] == "2"


def test_matching_reuses_each_current_window_only_once(session):
    saved = [client(), client(address="0x2", stable_id="2"), client("firefox", "0x3", "3")]
    current = [client(address="0xa", stable_id="a")]
    matches = session.match_windows(saved, current)
    assert matches == {0: current[0]}


def test_transform_box_scales_to_the_available_monitor(session):
    window = {"at": [966, 35], "size": [945, 512]}
    target = monitor("DP-1")
    target.update(width=3840, height=2160, x=1920)
    box = session.transform_box(window, monitor(), target)
    assert box == {"x": 3852, "y": 70, "w": 1890, "h": 1024}


def test_runtime_lua_carries_stable_ids_and_workspace_monitors(session):
    payload = {
        "boxes": {"42": {"x": 1, "y": 2, "w": 3, "h": 4}},
        "workspaces": [{"name": "9", "monitor": "eDP-1"}],
    }
    text = session.runtime_lua(payload)
    assert '["42"] = { x = 1, y = 2, w = 3, h = 4 }' in text
    assert '{ name = "9", monitor = "eDP-1" }' in text


class FakeHypr:
    def __init__(self, monitors, clients):
        self.monitors = monitors
        self.clients = clients
        self.dispatches = []
        self.evaluations = []

    def query(self, topic):
        if topic == "monitors":
            return self.monitors
        if topic == "clients":
            return self.clients
        raise AssertionError(topic)

    def dispatch(self, expression):
        self.dispatches.append(expression)

    def evaluate(self, expression):
        self.evaluations.append(expression)


def test_restore_launches_missing_applications_and_applies_layout(session, tmp_path):
    first = client(workspace="9")
    second = client("org.pulseaudio.pavucontrol", "0x2", "2", "9", 200)
    saved = snapshot(session, [first, second])
    existing = client(address="0xa", stable_id="a", workspace="1")
    hypr = FakeHypr([monitor()], [existing])

    def spawn(command):
        assert command == ["/usr/bin/org.pulseaudio.pavucontrol"]
        hypr.clients.append(client("org.pulseaudio.pavucontrol", "0xb", "b", "1", 300))

    result = session.restore_session(
        saved,
        hypr,
        tmp_path / "restore-layout.lua",
        spawn=spawn,
        sleep=lambda _: None,
        timeout=1,
    )
    assert result["restored"] == 2
    assert result["missing"] == []
    assert (tmp_path / "restore-layout.lua").is_file()
    assert len(hypr.evaluations) == 1
    assert "HWE_SESSION_RESTORE(dofile(" in hypr.evaluations[0]
    assert sum('action = "disable"' in expression for expression in hypr.dispatches) == 2
    assert sum('workspace = "9"' in expression for expression in hypr.dispatches) >= 2
    assert any('window = "address:0xa"' in expression for expression in hypr.dispatches)


def test_restore_requires_an_available_monitor(session, tmp_path):
    saved = snapshot(session)
    hypr = FakeHypr([], [])
    with pytest.raises(session.SessionError, match="no monitor"):
        session.restore_session(saved, hypr, tmp_path / "restore.lua", timeout=0)


def test_lua_provider_is_registered_without_automatic_floating(session, repo):
    text = (repo / "config/hypr/session-layout.lua").read_text()
    assert 'hl.layout.register("hwe-session"' in text
    assert "HWE_SESSION_RESTORE" in text
    assert "float = true" not in text


def test_clear_requires_name_or_all(session, tmp_path):
    store = session.Store(tmp_path / "sessions")
    store.save("one", minimal_snapshot())
    args = argparse.Namespace(action="clear", name="", all=True)
    session.run(args, store, session.Hyprctl())
    assert store.list() == []


def test_list_prints_snapshot_counts(session, capsys):
    session.print_list([minimal_snapshot()])
    output = capsys.readouterr().out
    assert "NAME" in output
    assert "WORKSPACES" in output
    assert "one" in output


def test_session_submap_only_saves_and_restores_slots(repo):
    binds = (repo / "config/hypr/keybindings.lua").read_text()
    assert 'hl.define_submap("session"' in binds
    assert "for slot = 1, 9 do" in binds
    assert 'session_command("save", slot)' in binds
    assert 'session_command("restore", slot)' in binds
    assert 'session_command("list"' not in binds
    assert 'session_command("clear"' not in binds
    assert 'bind("SUPER + X", hl.dsp.workspace.toggle_special("magic")' in binds
    assert 'bind("SUPER + S", hl.dsp.workspace.toggle_special("magic")' not in binds
