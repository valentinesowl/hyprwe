hl.on("hyprland.start", function()
    local commands = {
        "systemctl --user import-environment PATH WAYLAND_DISPLAY XDG_CURRENT_DESKTOP",
        "dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP",
        "hwe wall restore",
        "mako",
        "waybar",
        "hypridle",
        "hyprsunset",
        "kanshi",
        "swayosd-server",
        "systemctl --user start hyprpolkitagent",
        "nm-applet --indicator",
        "blueman-applet",
        "udiskie --tray",
        "wl-paste --type text --watch cliphist store",
        "wl-paste --type image --watch cliphist store",
        "xdg-user-dirs-update",
        "hwe checkconfig --notify",
        "hwe welcome",
    }
    for _, command in ipairs(commands) do
        hl.exec_cmd(command)
    end
end)
