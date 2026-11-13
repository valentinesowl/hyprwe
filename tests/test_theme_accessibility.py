"""Accessibility constraints for shipped theme geometry and rendered UI states."""
import re
import tomllib

import pytest

from conftest import theme_ids, theme_paths

MINIMUM_FONT_SIZES = {
    "terminal": 9.5,
    "bar": 12,
    "launcher": 12,
    "notify": 11,
    "gtk": 11,
}


def _theme(path):
    with open(path, "rb") as fh:
        return tomllib.load(fh)


@pytest.mark.parametrize("theme_path", theme_paths(), ids=theme_ids())
def test_shipped_theme_has_readable_minimum_font_sizes(theme_path):
    theme = _theme(theme_path)
    for role, minimum in MINIMUM_FONT_SIZES.items():
        actual = theme.get("font", {}).get(role, 12 if role == "launcher" else minimum)
        assert actual >= minimum, f"[font].{role} is {actual}, below the {minimum} minimum"


@pytest.mark.parametrize("theme_path", theme_paths(), ids=theme_ids())
def test_shipped_theme_has_a_full_height_bar(theme_path):
    theme = _theme(theme_path)
    assert theme.get("params", {}).get("bar_height", 28) >= 28


@pytest.mark.parametrize("theme_path", theme_paths(), ids=theme_ids())
def test_active_workspace_has_a_non_colour_marker(theme_path):
    theme = _theme(theme_path)
    indicator = theme.get("params", {}).get("bar_ws_indicator", "underline")
    assert indicator in {"underline", "pill", "dot"}


def test_rofi_selected_rows_use_semantic_ink(repo):
    files = [
        repo / "config/rofi/config.rasi",
        repo / "templates/rofi/powermenu.rasi.j2",
        repo / "templates/rofi/wallpaper.rasi.j2",
    ]
    for path in files:
        selected = "\n".join(
            line for line in path.read_text().splitlines()
            if line.strip().startswith("element selected") or "text-color:" in line
        )
        assert "text-color: @bg-dark" not in selected
        assert "@on-accent" in selected


def test_interactive_bar_targets_are_not_smaller_than_the_bar(repo):
    style = (repo / "config/waybar/style.css").read_text()
    template = (repo / "templates/waybar/config.jsonc.j2").read_text()
    assert "min-height: 28px" in style
    assert '"icon-size": 16' in template


def test_custom_theme_accessibility_warnings_do_not_break_loading(render_theme, minimal_theme):
    minimal_theme["font"]["bar"] = 9
    minimal_theme["params"]["bar_height"] = 20
    minimal_theme["sem"]["fg_dim"] = minimal_theme["sem"]["bg_normal"]
    assert render_theme.check_values(minimal_theme) == []
    warnings = render_theme.accessibility_warnings(minimal_theme)
    assert any("[font].bar" in warning for warning in warnings)
    assert any("bar_height" in warning for warning in warnings)
    assert any("fg_dim" in warning for warning in warnings)
    assert render_theme.build_context(minimal_theme, lenient=False)["font"]["bar"] == 9


def test_waybar_exposes_layout_values_and_mouse_actions(repo):
    template = (repo / "templates/waybar/config.jsonc.j2").read_text()
    right = [
        "tray", "custom/updates", "custom/cpu", "custom/memory", "custom/temp", "custom/record",
        "pulseaudio", "backlight", "battery", "hyprland/language", "custom/sunset",
    ]
    expected = ", ".join(f'"{module}"' for module in right)
    assert f'"modules-right": [{expected}]' in template
    assert '"custom/updates"' in template
    assert 'wbupdates.py --watch' in template
    assert '"hyprland/language"' in template
    assert '"format-en": "US"' in template
    assert '"format-ru": "RU"' in template
    assert '"format": "{icon} {percentage}%"' not in template
    assert '"format": "{icon} {volume}%"' not in template
    assert '"format": "{icon} {capacity}%"' not in template
    assert '"format-muted": "󰝟"' in template
    assert "Scroll: volume" in template
    assert "Left click: mixer" in template
    assert "Right click: mute" in template


def _rasi_px(template: str, block: str, prop: str) -> int:
    body = template.split(f"{block} {{", 1)[1].split("}", 1)[0]
    return int(re.search(rf"{prop}:\s*(\d+)px", body).group(1))


def test_theme_picker_identity_grid_fits_twelve_cards(repo):
    template = (repo / "templates/rofi/theme.rasi.j2").read_text()
    picker = (repo / "lib/theme.sh").read_text()
    assert "_HWE_PICK_PREVIEW" not in picker
    assert "-kb-custom" not in picker
    assert "-kb-accept-alt" not in picker
    assert "columns:          4" in template
    assert "lines:            3" in template
    assert "width:            876px" in template
    assert 'children:         [ "element-icon" ]' in template
    assert "background-color: @bg-light" not in template
    assert 'children: [ "element-icon", "element-text" ]' in picker
    assert "text-color:       @fg-bright" in template

    columns = 4
    window = _rasi_px(template, "window", "width")
    main_padding = _rasi_px(template, "mainbox", "padding")
    list_spacing = _rasi_px(template, "listview", "spacing")
    element_padding = _rasi_px(template, "element", "padding")
    element_border = _rasi_px(template, "element", "border")
    icon = _rasi_px(template, "element-icon", "size")
    icon_space = (window - 2 * main_padding - (columns - 1) * list_spacing) / columns
    icon_space -= 2 * (element_padding + element_border)
    assert icon_space >= icon


@pytest.mark.parametrize("theme_path", theme_paths(), ids=theme_ids())
def test_shipped_workspace_motion_has_a_calm_default(theme_path):
    theme = _theme(theme_path)
    assert theme.get("params", {}).get("bar_ws_speed", 220) == 220


def test_builtin_menus_and_notifications_use_english_and_theme_colours(repo):
    keys = (repo / "templates/rofi/keys.rasi.j2").read_text()
    checkconfig = (repo / "lib/checkconfig.sh").read_text()
    welcome = (repo / "lib/welcome.sh").read_text()
    record = (repo / "lib/record.sh").read_text()
    assert "фильтр" not in keys
    assert "Filter shortcuts…" in keys
    for text in (checkconfig, welcome, record):
        assert "hyprctl notify" not in text
        assert "notify " in text
