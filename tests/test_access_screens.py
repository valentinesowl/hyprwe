"""Static and contrast checks for SDDM and hyprlock access screens."""
import tomllib

import pytest
from test_theme_contrast import TEXT_MIN, composite, contrast_ratio

from conftest import theme_ids, theme_paths


def test_sddm_uses_semantic_scrim_and_on_accent(repo):
    template = (repo / "templates/sddm/theme.conf.j2").read_text()
    qml = (repo / "provision/sddm/hwe/Main.qml").read_text()
    assert 'ScrimColor="{{ sem.bg_dark }}"' in template
    assert 'ScrimOpacity="0.94"' in template
    assert 'OnAccent="{{ sem.on_accent }}"' in template
    assert "color: cScrim" in qml
    assert "color: cOnAccent" in qml
    assert 'color: "#000000"; opacity:' not in qml


def test_sddm_exposes_keyboard_state_and_focus(repo):
    qml = (repo / "provision/sddm/hwe/Main.qml").read_text()
    assert "keyboard.capsLock" in qml
    assert "keyboard.currentLayout" in qml
    assert "activeFocusOnTab: true" in qml
    assert "KeyNavigation.down: loginButton" in qml
    assert "Keys.onReturnPressed: root.doLogin()" in qml
    assert "root.showPassword ? TextInput.Normal : TextInput.Password" in qml


def test_hyprlock_has_a_fullscreen_scrim_and_caps_lock_feedback(repo):
    template = (repo / "templates/hypr/hyprlock.conf.j2").read_text()
    assert "size = 100%, 100%" in template
    assert "color = {{ sem.bg_dark|rgba('f0') }}" in template
    assert "capslock_color = {{ sem.orange|rgb }}" in template
    assert "lockstate.py" in template
    assert "grace" not in template


@pytest.mark.parametrize("theme_path", theme_paths(), ids=theme_ids())
@pytest.mark.parametrize("wallpaper", ["#000000", "#ffffff", "#808080"])
@pytest.mark.parametrize("role", ["fg_dim", "fg_normal", "fg_bright", "urgent"])
def test_access_screen_text_survives_scrim_compositing(theme_path, wallpaper, role):
    with open(theme_path, "rb") as handle:
        sem = tomllib.load(handle)["sem"]
    background = composite(sem["bg_dark"], wallpaper, 240 / 255)
    ratio = contrast_ratio(sem[role], background)
    assert ratio >= TEXT_MIN, f"{role} on the access-screen scrim is {ratio:.2f}:1 over {wallpaper}"
