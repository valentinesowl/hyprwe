"""Caps Lock state parsing for the hyprlock dynamic label."""
import json
import subprocess

import pytest


def test_caps_lock_is_read_from_any_keyboard(lockstate):
    assert lockstate.caps_lock_active({"keyboards": [{"capsLock": False}, {"capsLock": True}]})


def test_caps_lock_defaults_to_off(lockstate):
    assert not lockstate.caps_lock_active({"keyboards": [{}]})
    assert not lockstate.caps_lock_active({})


def test_main_prints_a_text_indicator_only_when_active(lockstate, monkeypatch, capsys):
    result = subprocess.CompletedProcess(["hyprctl"], 0, stdout=json.dumps({"keyboards": [{"capsLock": True}]}))
    monkeypatch.setattr(lockstate.subprocess, "run", lambda *args, **kwargs: result)
    assert lockstate.main() == 0
    assert capsys.readouterr().out == "CAPS LOCK\n"


def test_main_is_quiet_when_hyprctl_is_unavailable(lockstate, monkeypatch, capsys):
    def unavailable(*args, **kwargs):
        raise OSError("not in a compositor")

    monkeypatch.setattr(lockstate.subprocess, "run", unavailable)
    assert lockstate.main() == 0
    assert capsys.readouterr().out == ""


@pytest.mark.parametrize("payload", ["not json", "{}"])
def test_main_handles_invalid_or_empty_payloads(lockstate, monkeypatch, capsys, payload):
    result = subprocess.CompletedProcess(["hyprctl"], 0, stdout=payload)
    monkeypatch.setattr(lockstate.subprocess, "run", lambda *args, **kwargs: result)
    assert lockstate.main() == 0
    assert capsys.readouterr().out == ""
