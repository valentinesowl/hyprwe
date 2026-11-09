local variables = {
    XDG_CURRENT_DESKTOP = "Hyprland",
    XDG_SESSION_DESKTOP = "Hyprland",
    XDG_SESSION_TYPE = "wayland",
    QT_QPA_PLATFORM = "wayland;xcb",
    QT_QPA_PLATFORMTHEME = "qt6ct",
    QT_WAYLAND_DISABLE_WINDOWDECORATION = "1",
    QT_AUTO_SCREEN_SCALE_FACTOR = "1",
    GDK_BACKEND = "wayland,x11",
    MOZ_ENABLE_WAYLAND = "1",
    SDL_VIDEODRIVER = "wayland",
    CLUTTER_BACKEND = "wayland",
    _JAVA_AWT_WM_NONREPARENTING = "1",
    XCURSOR_SIZE = "24",
    HYPRCURSOR_SIZE = "24",
}

for name, value in pairs(variables) do
    hl.env(name, value)
end
