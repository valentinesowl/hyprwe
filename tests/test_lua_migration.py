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


def test_autostart_runs_only_from_the_start_event(repo):
    text = (repo / "config/hypr/autostart.lua").read_text()
    assert text.count('hl.on("hyprland.start"') == 1
    assert "config.reloaded" not in text
    assert "hl.exec_cmd" in text


def test_live_ipc_has_0_57_dispatchers_and_legacy_transition_fallback(repo):
    callers = (repo / "lib/theme.sh").read_text() + (repo / "lib/power.sh").read_text()
    callers += (repo / "config/hypr/hypridle.conf").read_text()
    for old in ("dispatch exec ", "dispatch exit", "dispatch dpms "):
        assert old not in callers
    assert "_hypr_exec_cmd waybar" in callers
    assert "_hypr_exit" in callers
    assert callers.count("hwe hypr dpms") == 3

    compat = (repo / "lib/hyprland.sh").read_text()
    assert "hl.dsp.exec_cmd" in compat
    assert "hl.dsp.dpms" in compat
    assert "hl.dsp.exit()" in compat
    assert "hyprctl dispatch exec" in compat
    assert "hyprctl dispatch dpms" in compat
    assert "hyprctl dispatch exit" in compat


def test_animations_use_the_0_57_bezier_key(repo):
    static = (repo / "config/hypr/appearance.lua").read_text()
    template = (repo / "templates/hypr/theme.lua.j2").read_text()
    for text in (static, template):
        assert ", curve =" not in text
        assert 'bezier = "wind"' in text
        assert 'bezier = "default"' in text


def test_legacy_files_remain_available_during_verification(repo):
    """Live 0.56 machines and rollback need these until the Lua migration is released."""
    for name in ("hyprland.conf", "keybindings.conf", "autostart.conf"):
        assert (repo / f"config/hypr/{name}").is_file()
    assert (repo / "provision/userlayer/hypr.conf").is_file()
