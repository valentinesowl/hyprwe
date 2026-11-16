#!/usr/bin/env python3
import json
import os
import signal
import subprocess
import tempfile
import threading
import tomllib
from datetime import datetime
from pathlib import Path

import gi
from control_state import (
    count_detail,
    editor_command,
    motion_duration,
    session_model,
    snapshot_parts,
)

gi.require_version("Gtk", "4.0")
gi.require_version("Gtk4LayerShell", "1.0")
from gi.repository import GLib, GLibUnix, Gtk, Gtk4LayerShell, Pango  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
HWE = ROOT / "bin" / "hwe"
HEIGHT = 620
DURATION = 220
PAGE_X = 26
ZONE_X = 20
SECTION_GAP = 10
CONTENT_GAP = 12
CONTROL_GAP = 8


def spawn_environment():
    env = os.environ.copy()
    preloads = [
        entry for entry in env.get("LD_PRELOAD", "").split(":")
        if entry and Path(entry).name != "libgtk4-layer-shell.so"
    ]
    if preloads:
        env["LD_PRELOAD"] = ":".join(preloads)
    else:
        env.pop("LD_PRELOAD", None)
    return env


def command(*args, capture=True):
    return subprocess.run(
        args, capture_output=capture, text=True, check=False, env=spawn_environment()
    )


def update_command():
    env = spawn_environment()
    env["HWE_ASSUME_YES"] = "1"
    return [HWE, "update"], env


def health_state_path():
    state = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state"))
    return state / "hwe" / "control-shelf.json"


def read_health(path):
    try:
        data = json.loads(path.read_text())
        if not isinstance(data, dict):
            return {}
        if not isinstance(data.get("status"), str) or not isinstance(data.get("report"), str):
            return {}
        datetime.fromisoformat(data["checked_at"])
        return data
    except (OSError, ValueError, KeyError, TypeError):
        return {}


def write_health(path, state):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent, text=True)
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(state, handle, ensure_ascii=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def text(value, *classes, x=0.0):
    label = Gtk.Label(label=value, xalign=x)
    for name in classes:
        label.add_css_class(name)
    return label


def box(orientation=Gtk.Orientation.VERTICAL, spacing=0, *classes):
    widget = Gtk.Box(orientation=orientation, spacing=spacing)
    for name in classes:
        widget.add_css_class(name)
    return widget


def action(label, callback, *classes):
    widget = Gtk.Button(label=label)
    widget.add_css_class("action")
    for name in classes:
        widget.add_css_class(name)
    widget.connect("clicked", callback)
    return widget


def section(number, title):
    return text(f"{number}  /  {title}", "section", "mono")


def luminance(colour):
    values = [int(colour[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    return sum(v * w for v, w in zip(values, (0.2126, 0.7152, 0.0722), strict=True))


class Shelf(Gtk.Application):
    def __init__(self):
        super().__init__(application_id="dev.hyprwe.ControlShelfPrototype")
        self.window = None
        self.overlay = None
        self.shelf = None
        self.offset = HEIGHT
        self.animation_start = None
        self.animation_from = HEIGHT
        self.animation_to = 0
        self.animation_finish = None
        self.animation_tick_id = 0
        self.closing = False
        self.theme = self.load_theme()
        self.sem = self.theme["sem"]
        self.health_state = read_health(health_state_path())
        self.report = self.health_state.get("report", "")
        self.sessions_box = None
        self.save_entry = None
        self.delete_confirm = None
        self.delete_label = None
        self.delete_name = None
        self.health = None
        self.health_detail = None
        self.log = None
        self.copy_button = None
        self.doctor_button = None
        self.update_button = None
        self.update_confirm = None
        self.auth_entry = None
        self.update_process = None
        config = Path(os.environ.get("HWE_USER_CONFIG", Path.home() / ".config/hwe")) / "hypr.lua"
        self.duration = motion_duration(config, DURATION)

    def load_theme(self):
        marker = Path.home() / ".config/hwe/themes/.current"
        name = marker.read_text().strip() if marker.exists() else "void"
        path = ROOT / "themes" / name / "theme.toml"
        with path.open("rb") as handle:
            theme = tomllib.load(handle)
        theme["slug"] = name
        return theme

    def do_activate(self):
        if self.window:
            self.close_shelf()
            return
        self.window = Gtk.ApplicationWindow(application=self)
        monitors = self.window.get_display().get_monitors()
        width = monitors.get_item(0).get_geometry().width if monitors.get_n_items() else 1920
        self.window.set_default_size(width, HEIGHT)
        self.window.set_resizable(False)
        self.window.add_css_class("shelf-window")
        Gtk4LayerShell.init_for_window(self.window)
        Gtk4LayerShell.set_layer(self.window, Gtk4LayerShell.Layer.OVERLAY)
        Gtk4LayerShell.set_namespace(self.window, "hwe-control")
        for edge in (Gtk4LayerShell.Edge.LEFT, Gtk4LayerShell.Edge.RIGHT, Gtk4LayerShell.Edge.BOTTOM):
            Gtk4LayerShell.set_anchor(self.window, edge, True)
        Gtk4LayerShell.set_exclusive_zone(self.window, 0)
        Gtk4LayerShell.set_keyboard_mode(
            self.window, Gtk4LayerShell.KeyboardMode.ON_DEMAND
        )
        Gtk4LayerShell.set_margin(self.window, Gtk4LayerShell.Edge.BOTTOM, 0)

        css = Gtk.CssProvider()
        css.load_from_string(self.styles())
        Gtk.StyleContext.add_provider_for_display(
            self.window.get_display(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )
        self.overlay = Gtk.Overlay()
        base = box()
        base.set_size_request(width, HEIGHT)
        self.overlay.set_child(base)
        self.shelf = self.build()
        self.shelf.set_size_request(width, HEIGHT)
        self.shelf.set_valign(Gtk.Align.START)
        self.shelf.set_margin_top(HEIGHT)
        self.overlay.add_overlay(self.shelf)
        self.overlay.set_clip_overlay(self.shelf, True)
        self.window.set_child(self.overlay)
        controller = Gtk.EventControllerKey()
        controller.connect("key-pressed", self.on_key)
        self.window.add_controller(controller)
        focus = Gtk.EventControllerFocus()
        focus.connect("leave", self.on_focus_leave)
        self.window.add_controller(focus)
        self.window.present()
        GLibUnix.signal_add(GLib.PRIORITY_DEFAULT, signal.SIGUSR1, self.on_signal)
        GLib.idle_add(self.reveal)

    def reveal(self):
        self.animate_to(0)
        return False

    def styles(self):
        sem = self.sem
        font = self.theme.get("font", {})
        mono = font.get("family", "JetBrains Mono")
        ui = font.get("ui_family", "Sans")
        ink = "#101112" if luminance(sem["accent"]) > 0.55 else sem["fg_white"]
        return f"""
        .shelf-window {{ background: transparent; }}
        .shelf {{
            background: alpha({sem['bg_dark']}, 0.985);
            color: {sem['fg_bright']};
            border-top: 1px solid {sem['accent_soft']};
            border-radius: 22px 22px 0 0;
            font-family: "{ui}";
        }}
        .header {{ padding: 10px {PAGE_X}px; }}
        .brand {{ font-family: "{mono}"; font-size: 18px; font-weight: 700; color: {sem['accent']}; }}
        .product {{ font-family: "{mono}"; font-size: 10px; color: {sem['fg_dim']}; }}
        .live {{ font-family: "{mono}"; font-size: 10px; color: {sem['fg_dim']}; }}
        .keycap {{
            font-family: "{mono}"; font-size: 10px; color: {sem['fg_dim']};
            border: 1px solid {sem['bg_light']}; border-radius: 5px; padding: 3px 6px;
        }}
        .close {{ color: {sem['fg_dim']}; background: transparent; border: 0; padding: 5px 0 5px 8px; }}
        .close:hover {{ color: {sem['fg_bright']}; }}
        .rule {{ background: {sem['bg_light']}; }}
        .content {{ padding: {CONTENT_GAP}px {PAGE_X}px; }}
        .zone {{ padding: 0 {ZONE_X}px; }}
        .zone:first-child {{ padding-left: 0; }}
        .zone:last-child {{ padding-right: 0; }}
        .section {{ font-size: 11px; font-weight: 600; color: {sem['fg_dim']}; }}
        .mono {{ font-family: "{mono}"; }}
        .theme-name {{ font-size: 22px; font-weight: 650; color: {sem['fg_white']}; }}
        .value {{ font-size: 14px; color: {sem['fg_bright']}; }}
        .muted {{ font-size: 12px; color: {sem['fg_dim']}; }}
        .small {{ font-size: 11px; color: {sem['fg_dim']}; }}
        .wallpaper-preview {{
            background: {sem['bg_normal']}; border: 1px solid {sem['bg_light']};
            border-radius: 8px;
        }}
        .action {{
            background: transparent; color: {sem['fg_bright']};
            border: 1px solid transparent; border-radius: 6px;
            padding: 6px 9px; font-size: 13px; font-weight: 500;
        }}
        .action:hover {{ background: {sem['bg_light']}; color: {sem['fg_white']}; }}
        .action:focus-visible {{ border-color: {sem['accent']}; color: {sem['fg_white']}; }}
        .primary {{ background: {sem['accent']}; color: {ink}; border-color: {sem['accent']}; }}
        .primary:hover {{ background: {sem['accent_soft']}; color: {ink}; }}
        .primary:focus-visible {{ color: {ink}; border-color: {sem['fg_white']}; }}
        .soft-primary {{
            background: alpha({sem['accent']}, 0.12); color: {sem['accent']};
            border-color: alpha({sem['accent']}, 0.38);
        }}
        .soft-primary:hover {{ background: alpha({sem['accent']}, 0.20); color: {sem['accent']}; }}
        .soft-primary:focus-visible {{ color: {sem['accent']}; border-color: {sem['accent']}; }}
        .quiet {{ color: {sem['fg_dim']}; }}
        .swatch {{ border-radius: 3px; }}
        .coverage {{ font-family: "{mono}"; font-size: 11px; color: {sem['fg_dim']}; }}
        .session-map {{ background: transparent; }}
        .workspace {{
            font-family: "{mono}"; font-size: 11px; color: {sem['fg_dim']};
            background: transparent; padding: 3px 6px 3px 0;
        }}
        .timeline-rule {{ background: {sem['bg_light']}; }}
        .snapshot {{
            background: transparent; border: 0; border-left: 1px solid {sem['bg_light']};
            border-radius: 0; padding: 4px 16px;
        }}
        .snapshot:first-child {{ border-left: 0; padding-left: 0; }}
        .snapshot-name {{ font-size: 14px; font-weight: 600; color: {sem['fg_bright']}; }}
        .snapshot-time {{ font-family: "{mono}"; font-size: 11px; color: {sem['accent']}; }}
        .status {{
            font-family: "{mono}"; font-size: 11px; color: {sem['fg_dim']};
            background: {sem['bg_normal']}; border-radius: 5px; padding: 4px 7px;
        }}
        .entry {{
            background: {sem['bg_normal']}; color: {sem['fg_bright']};
            border: 1px solid {sem['accent_soft']}; border-radius: 6px;
            padding: 6px 9px; font-family: "{mono}"; font-size: 11px;
        }}
        .entry:focus {{ border-color: {sem['accent']}; }}
        .log {{ font-family: "{mono}"; font-size: 11px; color: {sem['fg_dim']}; }}
        .layer-track {{ border-bottom: 1px solid {sem['bg_light']}; padding-bottom: {CONTROL_GAP}px; }}
        .layer-node {{ background: transparent; border: 0; border-radius: 0; padding: 2px 0; }}
        .layer-title {{ font-family: "{mono}"; font-size: 12px; color: {sem['fg_bright']}; }}
        .layer-path {{ font-family: "{mono}"; font-size: 11px; color: {sem['fg_dim']}; }}
        .layer-arrow {{ font-family: "{mono}"; font-size: 18px; color: {sem['accent']}; }}
        """

    def build(self):
        shelf = box(Gtk.Orientation.VERTICAL, 0, "shelf")
        shelf.append(self.header())
        shelf.append(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL))
        content = box(Gtk.Orientation.VERTICAL, CONTENT_GAP, "content")
        primary = box(Gtk.Orientation.HORIZONTAL, 0, "primary-grid")
        primary.append(self.appearance())
        primary.append(Gtk.Separator(orientation=Gtk.Orientation.VERTICAL))
        primary.append(self.sessions())
        primary.append(Gtk.Separator(orientation=Gtk.Orientation.VERTICAL))
        primary.append(self.system())
        primary.set_vexpand(True)
        content.append(primary)
        content.append(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL))
        content.append(self.snapshot_strip())
        content.append(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL))
        content.append(self.configuration())
        shelf.append(content)
        return shelf

    def header(self):
        header = box(Gtk.Orientation.HORIZONTAL, 16, "header")
        identity = box(spacing=2)
        identity.set_hexpand(True)
        identity.append(text("hyprwe", "brand"))
        identity.append(text("WORKSTATION CONTROL", "product"))
        header.append(identity)
        header.append(text("LIVE SYSTEM STATE", "live", "mono"))
        header.append(text("ESC", "keycap"))
        close = action("Close", lambda *_: self.close_shelf(), "close")
        header.append(close)
        return header

    def appearance(self):
        zone = box(Gtk.Orientation.VERTICAL, SECTION_GAP, "zone")
        zone.set_size_request(350, -1)
        zone.append(section("01", "Appearance"))

        wallpaper = self.current_wallpaper()
        identity = box(Gtk.Orientation.HORIZONTAL, CONTENT_GAP)
        preview = Gtk.Picture()
        preview.add_css_class("wallpaper-preview")
        preview.set_size_request(112, 66)
        preview.set_content_fit(Gtk.ContentFit.COVER)
        preview.set_can_shrink(True)
        if wallpaper:
            preview.set_filename(str(wallpaper))
            preview.set_tooltip_text(str(wallpaper))
        else:
            preview.set_tooltip_text("No active wallpaper")
        identity.append(preview)

        details = box(spacing=4)
        details.set_hexpand(True)
        details.append(text(self.theme.get("name", self.theme["slug"]), "theme-name"))
        palette = box(Gtk.Orientation.HORIZONTAL, 4)
        for role in ("accent", "accent_soft", "blue", "green", "bg_light"):
            swatch = box(Gtk.Orientation.VERTICAL, 0, "swatch", f"swatch-{role}")
            swatch.set_size_request(25, 5)
            provider = Gtk.CssProvider()
            provider.load_from_string(
                f".swatch-{role} {{ background: {self.sem.get(role, self.sem['accent'])}; }}"
            )
            Gtk.StyleContext.add_provider_for_display(
                self.window.get_display(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
            )
            palette.append(swatch)
        details.append(palette)
        wallpaper_label = text(wallpaper.name if wallpaper else "No active wallpaper", "muted")
        wallpaper_label.set_ellipsize(Pango.EllipsizeMode.END)
        wallpaper_label.set_max_width_chars(24)
        details.append(wallpaper_label)
        identity.append(details)
        zone.append(identity)

        actions = box(Gtk.Orientation.HORIZONTAL, CONTROL_GAP)
        actions.append(action("Change theme  ↗", lambda *_: self.launch("theme", "pick"), "soft-primary"))
        actions.append(action("Wallpaper  ↗", lambda *_: self.launch("wall", "pick")))
        zone.append(actions)
        zone.append(text("Theme compiler coverage", "section", "mono"))
        zone.append(text(
            "Hyprland · Waybar · Rofi · Kitty\nGTK 3/4 · Qt · Mako · Lock / Login",
            "coverage",
        ))
        return zone

    def sessions(self):
        zone = box(Gtk.Orientation.VERTICAL, SECTION_GAP, "zone")
        zone.set_hexpand(True)
        zone.append(section("02", "Current session"))
        self.session_data = session_model(
            command("hyprctl", "clients", "-j").stdout,
            command("hyprctl", "workspaces", "-j").stdout,
            command("hyprctl", "monitors", "-j").stdout,
            command("hyprctl", "activewindow", "-j").stdout,
        )
        current = box(Gtk.Orientation.HORIZONTAL, CONTENT_GAP)
        labels = box(spacing=2)
        labels.append(text(count_detail(
            self.session_data["window_count"], self.session_data["workspace_count"]
        ), "value"))
        labels.append(text(
            f"Workspace {self.session_data['active_name']} · {self.session_data['monitor']}",
            "muted",
        ))
        current.append(labels)
        save = action("Save current  +", self.show_save, "soft-primary")
        save.set_halign(Gtk.Align.END)
        current.append(save)
        labels.set_hexpand(True)
        zone.append(current)

        self.save_entry = Gtk.Entry(placeholder_text="Unique snapshot name — Enter to save")
        self.save_entry.add_css_class("entry")
        self.save_entry.connect("activate", self.save_session)
        self.save_entry.set_visible(False)
        zone.append(self.save_entry)

        body = box(Gtk.Orientation.HORIZONTAL, CONTENT_GAP)
        session_map = Gtk.DrawingArea()
        session_map.add_css_class("session-map")
        session_map.set_hexpand(True)
        session_map.set_vexpand(True)
        session_map.set_size_request(280, 96)
        session_map.set_draw_func(self.draw_session_map, self.session_data)
        body.append(session_map)
        applications = box(spacing=4)
        applications.set_size_request(160, -1)
        applications.append(text("Visible windows", "section", "mono"))
        if self.session_data["windows"]:
            for window in self.session_data["windows"]:
                label = text(window["class"] or "unknown", "muted", "mono")
                label.set_ellipsize(Pango.EllipsizeMode.END)
                applications.append(label)
        else:
            applications.append(text("No windows on this workspace", "muted"))
        body.append(applications)
        zone.append(body)

        workspace_scroll = Gtk.ScrolledWindow()
        workspace_scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.NEVER)
        workspace_scroll.set_min_content_height(25)
        workspace_list = box(Gtk.Orientation.HORIZONTAL, CONTROL_GAP)
        for workspace in self.session_data["workspaces"]:
            workspace_list.append(text(
                f"{workspace['name']} · {workspace['windows']}", "workspace"
            ))
        workspace_scroll.set_child(workspace_list)
        zone.append(workspace_scroll)
        return zone

    def draw_session_map(self, _, context, width, height, data):
        surface = self.colour(self.sem["bg_normal"])
        context.set_source_rgba(surface.red, surface.green, surface.blue, 0.35)
        context.paint()
        grid = self.colour(self.sem["bg_light"])
        context.set_source_rgba(grid.red, grid.green, grid.blue, 0.65)
        context.set_line_width(1)
        context.set_dash([2, 5])
        for step in range(1, 4):
            x = round(width * step / 4) + 0.5
            context.move_to(x, 6)
            context.line_to(x, height - 6)
            context.stroke()
        for step in range(1, 3):
            y = round(height * step / 3) + 0.5
            context.move_to(6, y)
            context.line_to(width - 6, y)
            context.stroke()
        context.set_dash([])
        border = self.colour(self.sem["border"])
        context.set_source_rgb(border.red, border.green, border.blue)
        context.rectangle(5.5, 5.5, width - 11, height - 11)
        context.stroke()

        accent = self.colour(self.sem["accent"])
        inactive = self.colour(self.sem["fg_dim"])
        context.select_font_face("monospace")
        context.set_font_size(10)
        for index, window in enumerate(data["windows"], start=1):
            x = 10 + window["x"] * (width - 20)
            y = 10 + window["y"] * (height - 20)
            w = max(3, window["width"] * (width - 20))
            h = max(3, window["height"] * (height - 20))
            colour = accent if window["active"] else inactive
            context.set_line_width(1.8 if window["active"] else 1)
            context.rectangle(x, y, w, h)
            if window["active"]:
                context.set_source_rgba(accent.red, accent.green, accent.blue, 0.12)
                context.fill_preserve()
            context.set_source_rgb(colour.red, colour.green, colour.blue)
            context.stroke()
            context.move_to(min(x + 6, width - 30), min(y + 16, height - 8))
            context.show_text(f"{index:02d}")

    def snapshot_strip(self):
        zone = box(Gtk.Orientation.VERTICAL, CONTROL_GAP)
        heading = box(Gtk.Orientation.HORIZONTAL, CONTENT_GAP)
        heading.append(section("04", "Session snapshots"))
        self.delete_confirm = box(Gtk.Orientation.HORIZONTAL, CONTROL_GAP)
        self.delete_label = text("", "muted")
        self.delete_label.set_hexpand(True)
        self.delete_confirm.append(self.delete_label)
        self.delete_confirm.append(action("Cancel", self.cancel_delete, "quiet"))
        self.delete_confirm.append(action("Delete", self.delete_session, "primary"))
        self.delete_confirm.set_visible(False)
        heading.append(self.delete_confirm)
        zone.append(heading)
        timeline = Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL)
        timeline.add_css_class("timeline-rule")
        zone.append(timeline)
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.NEVER)
        scroll.set_min_content_height(100)
        self.sessions_box = box(Gtk.Orientation.HORIZONTAL, 0)
        scroll.set_child(self.sessions_box)
        zone.append(scroll)
        self.refresh_sessions()
        return zone

    def configuration(self):
        zone = box(Gtk.Orientation.VERTICAL, CONTROL_GAP)
        personal = Path(os.environ.get("HWE_USER_CONFIG", Path.home() / ".config/hwe"))
        zone.append(section("05", "Configuration layers"))
        nodes = box(Gtk.Orientation.HORIZONTAL, CONTROL_GAP, "layer-track")
        nodes.set_hexpand(True)
        live = Path.home() / ".config"
        layers = (
            ("BASE", str(ROOT), (("Repository", ROOT),)),
            ("THEME", self.theme["slug"], (
                ("theme.toml", ROOT / "themes" / self.theme["slug"] / "theme.toml"),
            )),
            ("PERSONAL", str(personal), (
                ("hypr.lua", personal / "hypr.lua"),
                ("Packages", personal / "packages.lst"),
                ("Waybar", personal / "waybar.jsonc"),
            )),
            ("LIVE", str(live), (("Config", live),)),
        )
        for index, (title, path, sources) in enumerate(layers):
            if index:
                nodes.append(text("→", "layer-arrow"))
            node = box(Gtk.Orientation.VERTICAL, 2, "layer-node")
            node.set_hexpand(True)
            node.append(text(title, "layer-title"))
            label = text(path, "layer-path")
            label.set_ellipsize(Pango.EllipsizeMode.MIDDLE)
            label.set_max_width_chars(28)
            label.set_tooltip_text(path)
            node.append(label)
            source_row = box(Gtk.Orientation.HORIZONTAL, CONTROL_GAP)
            source_row.set_margin_top(4)
            for source_label, source_path in sources:
                button = action(
                    source_label, lambda _, target=source_path: self.open_path(target), "quiet"
                )
                button.set_sensitive(source_path.exists())
                if not source_path.exists():
                    button.set_tooltip_text(f"Not present: {source_path}")
                source_row.append(button)
            node.append(source_row)
            nodes.append(node)
        zone.append(nodes)
        return zone

    def system(self):
        zone = box(Gtk.Orientation.VERTICAL, SECTION_GAP, "zone")
        zone.set_size_request(390, -1)
        zone.append(section("03", "Health & update"))
        labels = box(spacing=4)
        self.health = text(self.health_summary(), "status")
        self.health.set_halign(Gtk.Align.START)
        labels.append(self.health)
        actions = box(Gtk.Orientation.HORIZONTAL, CONTROL_GAP)
        self.doctor_button = action("Run doctor", self.run_doctor)
        self.update_button = action("Update", self.show_update_confirm)
        actions.append(self.doctor_button)
        actions.append(self.update_button)
        labels.set_hexpand(True)
        zone.append(labels)
        zone.append(actions)

        self.update_confirm = box(Gtk.Orientation.HORIZONTAL, CONTROL_GAP)
        question = text("Pull and reconcile this machine?", "muted")
        question.set_hexpand(True)
        self.update_confirm.append(question)
        self.update_confirm.append(action("Cancel", self.cancel_update, "quiet"))
        self.update_confirm.append(action("Update now", self.begin_update, "primary"))
        self.update_confirm.set_visible(False)
        zone.append(self.update_confirm)

        self.auth_entry = Gtk.Entry(placeholder_text="sudo password — Enter to authenticate")
        self.auth_entry.add_css_class("entry")
        self.auth_entry.set_visibility(False)
        self.auth_entry.set_input_purpose(Gtk.InputPurpose.PASSWORD)
        self.auth_entry.connect("activate", self.authenticate_update)
        self.auth_entry.set_visible(False)
        zone.append(self.auth_entry)

        self.log = Gtk.ScrolledWindow()
        self.log.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        self.log.set_min_content_height(76)
        self.log.set_max_content_height(96)
        self.health_detail = text(self.report or "No report yet. Run doctor for a read-only inspection.", "log")
        self.health_detail.set_selectable(True)
        self.health_detail.set_valign(Gtk.Align.START)
        self.log.set_child(self.health_detail)
        zone.append(self.log)
        self.copy_button = action("Copy report", self.copy_report, "quiet")
        self.copy_button.set_halign(Gtk.Align.START)
        self.copy_button.set_sensitive(bool(self.report))
        zone.append(self.copy_button)
        return zone

    def open_path(self, path):
        self.close_shelf()
        if path.is_dir():
            command = ["dolphin", str(path)]
        else:
            command = editor_command(path, os.environ.get("EDITOR"))
        subprocess.Popen(command, env=spawn_environment())

    def current_wallpaper(self):
        result = command(HWE, "wall", "current")
        if result.returncode != 0 or not result.stdout.strip():
            return None
        path = Path(result.stdout.strip()).expanduser()
        return path if path.is_file() else None

    def colour(self, value):
        from gi.repository import Gdk
        rgba = Gdk.RGBA()
        rgba.parse(value)
        return rgba

    def refresh_sessions(self):
        child = self.sessions_box.get_first_child()
        while child:
            self.sessions_box.remove(child)
            child = self.sessions_box.get_first_child()
        root = Path(os.environ.get("HWE_SESSION_DIR", Path.home() / ".local/state/hwe/sessions"))
        snapshots = sorted(root.glob("*.json"), key=lambda path: path.stat().st_mtime, reverse=True)
        if not snapshots:
            empty = box(Gtk.Orientation.HORIZONTAL, 8)
            empty.append(text("No saved sessions yet", "value"))
            empty.append(text("Use Save current to create the first workstation layout.", "muted"))
            self.sessions_box.append(empty)
            return
        for path in snapshots:
            try:
                data = json.loads(path.read_text())
                counts, saved = snapshot_parts(data)
            except (OSError, json.JSONDecodeError):
                counts, saved = "", "Snapshot metadata unavailable"
            card = box(Gtk.Orientation.VERTICAL, 6, "snapshot")
            card.set_size_request(250, -1)
            card.append(text(f"●  {saved}", "snapshot-time"))
            name = text(path.stem, "snapshot-name")
            name.set_ellipsize(Pango.EllipsizeMode.END)
            card.append(name)
            metadata = text(counts, "small", "mono")
            metadata.set_ellipsize(Pango.EllipsizeMode.END)
            metadata.set_max_width_chars(38)
            card.append(metadata)
            actions = box(Gtk.Orientation.HORIZONTAL, CONTROL_GAP)
            actions.append(action(
                "Restore", lambda _, name=path.stem: self.launch("session", "restore", name)
            ))
            actions.append(action(
                "Delete", lambda _, name=path.stem: self.confirm_delete(name), "quiet"
            ))
            card.append(actions)
            self.sessions_box.append(card)

    def confirm_delete(self, name):
        self.delete_name = name
        self.delete_label.set_text(f"Delete snapshot '{name}'?")
        self.delete_confirm.set_visible(True)

    def cancel_delete(self, *_):
        self.delete_name = None
        self.delete_confirm.set_visible(False)

    def delete_session(self, *_):
        if not self.delete_name:
            return
        result = command(HWE, "session", "clear", self.delete_name)
        if result.returncode == 0:
            self.cancel_delete()
            self.refresh_sessions()
        else:
            self.delete_label.set_text((result.stderr or result.stdout).strip())

    def show_save(self, *_):
        self.save_entry.set_visible(True)
        self.save_entry.grab_focus()

    def save_session(self, entry):
        name = entry.get_text().strip()
        if not name:
            return
        result = command(HWE, "session", "save", name)
        if result.returncode == 0:
            entry.set_text("")
            entry.set_visible(False)
            self.refresh_sessions()
        else:
            entry.set_secondary_icon_name("dialog-error-symbolic")
            entry.set_tooltip_text((result.stderr or result.stdout).strip())

    def health_summary(self):
        if not self.health_state:
            return "UNKNOWN  /  not checked yet"
        status = self.health_state["status"]
        checked = datetime.fromisoformat(self.health_state["checked_at"])
        return f"{status}  /  {checked.strftime('%d.%m %H:%M')}"

    def save_health(self, status):
        self.health_state = {
            "status": status,
            "checked_at": datetime.now().astimezone().isoformat(timespec="seconds"),
            "report": self.report,
        }
        write_health(health_state_path(), self.health_state)

    def run_doctor(self, button):
        button.set_sensitive(False)
        self.update_button.set_sensitive(False)
        self.copy_button.set_sensitive(False)
        self.report = ""
        self.health.set_text("RUNNING  /  read-only inspection")
        self.health_detail.set_text("Checking packages, links, personal layer and session services…")

        def worker():
            result = command(HWE, "doctor", "--report")
            GLib.idle_add(self.doctor_done, result, button)

        threading.Thread(target=worker, daemon=True).start()

    def doctor_done(self, result, button):
        self.report = (result.stdout or "") + (result.stderr or "")
        status = "HEALTHY" if result.returncode == 0 else "DRIFT"
        self.report = self.report.strip() or "Doctor returned no output."
        self.save_health(status)
        self.health.set_text(self.health_summary())
        self.health_detail.set_text(self.report)
        button.set_sensitive(True)
        self.update_button.set_sensitive(True)
        self.copy_button.set_sensitive(bool(self.report))
        return False

    def copy_report(self, *_):
        if self.report:
            subprocess.run(["wl-copy"], input=self.report, text=True, check=False)

    def show_update_confirm(self, *_):
        self.update_confirm.set_visible(True)

    def cancel_update(self, *_):
        self.update_confirm.set_visible(False)

    def begin_update(self, *_):
        if self.update_process is not None:
            return
        self.update_confirm.set_visible(False)
        self.doctor_button.set_sensitive(False)
        self.update_button.set_sensitive(False)
        self.copy_button.set_sensitive(False)
        self.health.set_text("PREPARING  /  checking privileges")
        self.report = ""
        self.health_detail.set_text("Preparing the update…")

        def worker():
            result = command("sudo", "-n", "true")
            GLib.idle_add(self.update_auth_result, result)

        threading.Thread(target=worker, daemon=True).start()

    def update_auth_result(self, result):
        if result.returncode == 0:
            self.start_update()
        else:
            self.health.set_text("AUTHENTICATION REQUIRED")
            self.health_detail.set_text("Enter your sudo password. It is used only to authenticate this update.")
            self.auth_entry.set_visible(True)
            self.auth_entry.grab_focus()
        return False

    def authenticate_update(self, entry):
        password = entry.get_text()
        entry.set_text("")
        entry.set_visible(False)
        if not password:
            self.auth_entry.set_visible(True)
            return
        self.health.set_text("AUTHENTICATING")

        def worker():
            result = subprocess.run(
                ["sudo", "-S", "-v"], input=password + "\n", capture_output=True,
                text=True, check=False, env=spawn_environment(),
            )
            GLib.idle_add(self.update_auth_result, result)

        threading.Thread(target=worker, daemon=True).start()

    def start_update(self):
        self.auth_entry.set_visible(False)
        self.health.set_text("UPDATING  /  live log")
        self.report = ""
        self.health_detail.set_text("")
        args, env = update_command()
        try:
            self.update_process = subprocess.Popen(
                args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, bufsize=1, env=env,
            )
        except OSError as error:
            self.update_done(error)
            return

        def worker():
            for line in self.update_process.stdout:
                GLib.idle_add(self.append_update_log, line)
            result = self.update_process.wait()
            GLib.idle_add(self.update_done, result)

        threading.Thread(target=worker, daemon=True).start()

    def append_update_log(self, line):
        self.report += line
        self.health_detail.set_text(self.report)
        GLib.idle_add(self.scroll_log)
        return False

    def scroll_log(self):
        adjustment = self.log.get_vadjustment()
        adjustment.set_value(adjustment.get_upper())
        return False

    def update_done(self, result):
        if isinstance(result, OSError):
            self.report += f"Could not start hwe update: {result}\n"
            result = 1
        self.save_health("UPDATED" if result == 0 else "UPDATE FAILED")
        self.health.set_text(self.health_summary())
        self.health_detail.set_text(self.report)
        self.update_process = None
        self.doctor_button.set_sensitive(True)
        self.update_button.set_sensitive(True)
        self.copy_button.set_sensitive(bool(self.report))
        self.scroll_log()
        return False

    def launch(self, *args):
        self.close_shelf()
        subprocess.Popen([HWE, *args], env=spawn_environment())

    def on_signal(self):
        self.close_shelf()
        return False

    def on_key(self, _, keyval, *__):
        from gi.repository import Gdk
        if keyval == Gdk.KEY_Escape:
            self.close_shelf()
            return True
        return False

    def on_focus_leave(self, *_):
        GLib.idle_add(self.close_if_inactive)

    def close_if_inactive(self):
        if self.window and not self.window.is_active():
            self.close_shelf()
        return False

    def close_shelf(self):
        if self.closing:
            return
        self.closing = True
        self.animate_to(HEIGHT, finish=self.quit)

    def animate_to(self, target, finish=None):
        if self.animation_tick_id:
            self.window.remove_tick_callback(self.animation_tick_id)
            self.animation_tick_id = 0
        if self.duration == 0:
            self.offset = target
            self.shelf.set_margin_top(self.offset)
            self.overlay.queue_draw()
            if finish:
                finish()
            return
        self.animation_from = self.offset
        self.animation_to = target
        self.animation_start = None
        self.animation_finish = finish
        self.animation_tick_id = self.window.add_tick_callback(self.animation_tick)

    def animation_tick(self, _, frame_clock):
        now = frame_clock.get_frame_time()
        if self.animation_start is None:
            self.animation_start = now
        progress = min(1.0, (now - self.animation_start) / 1000 / self.duration)
        eased = 1 - (1 - progress) ** 3
        self.offset = round(self.animation_from + (self.animation_to - self.animation_from) * eased)
        self.shelf.set_margin_top(self.offset)
        self.overlay.queue_draw()
        if progress < 1:
            return True
        self.animation_tick_id = 0
        if self.animation_finish:
            self.animation_finish()
        return False


if __name__ == "__main__":
    Shelf().run()
