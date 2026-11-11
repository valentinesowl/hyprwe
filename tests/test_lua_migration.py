"""Static guards for the Hyprland 0.57 Lua migration."""
import pytest


def test_entry_point_requires_each_module_and_personal_layer_last(repo):
    entry = (repo / "config/hypr/hyprland.lua").read_text()
    modules = ["environment", "monitors", "appearance", "theme", "input",
               "keybindings", "windowrules", "session-layout", "autostart"]
    positions = [entry.index(f'require("{module}")') for module in modules]
    assert positions == sorted(positions)
    assert entry.index('require(config_home .. "/hwe/hypr")') > positions[-1]


@pytest.mark.parametrize("module", ["environment", "monitors", "appearance", "input",
                                    "keybindings", "windowrules", "session-layout", "autostart"])
def test_system_modules_have_no_legacy_hyprlang(repo, module):
    text = (repo / f"config/hypr/{module}.lua").read_text()
    for directive in ("source =", "exec-once", "$mainMod", "windowrule =", "layerrule ="):
        assert directive not in text


def test_windows_open_tiled_and_kitty_does_not_maximize(repo):
    rules = (repo / "config/hypr/windowrules.lua").read_text()
    assert 'hl.window_rule({ match = { class = ".*" }, tile = true })' in rules
    assert 'hl.window_rule({ match = { class = "^(kitty)$" }, suppress_event = "maximize" })' in rules
    assert "float = true" not in rules


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


def test_personal_layer_supports_persistent_reduced_motion(repo):
    text = (repo / "provision/userlayer/hypr.lua").read_text()
    assert "local reduced_motion = true" in text
    assert "animations = { enabled = false }" in text
    assert 'hl.animation({ leaf = "borderangle", enabled = false })' in text
    assert "preserved by theme apply and hwe update" in text


def test_waybar_motion_is_generated_from_the_personal_preference(repo):
    style = (repo / "config/waybar/style.css").read_text()
    template = (repo / "templates/waybar/theme.css.j2").read_text()
    assert "transition: color" not in style
    assert "{% if not params.reduced_motion %}" in template
    assert "transition: all {{ params.bar_ws_speed }}ms ease" in template


def test_notification_layer_has_no_compositor_backdrop(repo):
    text = (repo / "config/hypr/windowrules.lua").read_text()
    mako_rules = [line for line in text.splitlines() if "mako|notifications" in line]
    assert len(mako_rules) == 1
    assert "no_anim = true" in mako_rules[0]
    assert "blur = true" not in mako_rules[0]
