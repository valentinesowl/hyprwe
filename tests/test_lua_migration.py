"""Static guards for the Hyprland 0.57 Lua migration."""
import pytest


def test_entry_point_requires_each_module_and_personal_layer_last(repo):
    entry = (repo / "config/hypr/hyprland.lua").read_text()
    modules = ["environment", "monitors", "appearance", "theme", "input",
               "keybindings", "windowrules", "autostart"]
    positions = [entry.index(f'require("{module}")') for module in modules]
    assert positions == sorted(positions)
    assert entry.index('require(config_home .. "/hwe/hypr")') > positions[-1]


@pytest.mark.parametrize("module", ["environment", "monitors", "appearance", "input",
                                    "keybindings", "windowrules", "autostart"])
def test_system_modules_have_no_legacy_hyprlang(repo, module):
    text = (repo / f"config/hypr/{module}.lua").read_text()
    for directive in ("source =", "exec-once", "$mainMod", "windowrule =", "layerrule ="):
        assert directive not in text


def test_new_kitty_windows_float_above_the_tiling_layout(repo):
    rules = (repo / "config/hypr/windowrules.lua").read_text()
    assert 'hl.window_rule({ match = { class = "^(kitty)$" }, float = true })' in rules


def test_autostart_runs_only_from_the_start_event(repo):
    text = (repo / "config/hypr/autostart.lua").read_text()
    assert text.count('hl.on("hyprland.start"') == 1
    assert "config.reloaded" not in text
    assert "hl.exec_cmd" in text


def test_live_ipc_uses_only_lua_dispatchers(repo):
    text = (repo / "lib/theme.sh").read_text() + (repo / "lib/power.sh").read_text()
    text += (repo / "config/hypr/hypridle.conf").read_text()
    for old in ("dispatch exec ", "dispatch exit", "dispatch dpms "):
        assert old not in text
    assert 'hl.dsp.exec_cmd("waybar")' in text
    assert "hl.dsp.exit()" in text
    assert text.count("hl.dsp.dpms") == 3


def test_animations_use_the_0_57_bezier_key(repo):
    static = (repo / "config/hypr/appearance.lua").read_text()
    template = (repo / "templates/hypr/theme.lua.j2").read_text()
    for text in (static, template):
        assert ", curve =" not in text
        assert 'bezier = "wind"' in text
        assert 'bezier = "default"' in text


def test_legacy_compositor_configs_are_not_shipped(repo):
    for name in ("appearance", "autostart", "environment", "hyprland", "input",
                 "keybindings", "monitors", "windowrules"):
        assert not (repo / f"config/hypr/{name}.conf").exists()
    for name in ("colors.conf", "theme.conf"):
        assert not (repo / f"templates/hypr/{name}.j2").exists()
    assert not (repo / "provision/userlayer/hypr.conf").exists()
