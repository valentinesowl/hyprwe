-- Inspect windows with `hyprctl clients`. Effects are applied in order.
hl.window_rule({
    match = { class = "^(org.pulseaudio.pavucontrol|pavucontrol|nm-connection-editor|blueman-manager)$" },
    float = true,
})
hl.window_rule({ match = { title = "^(Open File|Save File|Choose Files)$" }, float = true })
hl.window_rule({ match = { class = "^(xdg-desktop-portal-gtk)$" }, float = true })
hl.window_rule({
    match = { title = "^(Picture-in-Picture)$" },
    float = true,
    pin = true,
    keep_aspect_ratio = true,
})
hl.window_rule({ match = { class = "^(xdg-desktop-portal-gtk)$" }, no_initial_focus = true })
hl.window_rule({
    match = { class = "^(firefox|librewolf|zen|chromium|google-chrome|brave-browser|vivaldi-stable|mpv|vlc|Celluloid|io.github.celluloid)$" },
    idle_inhibit = "fullscreen",
})

hl.layer_rule({ match = { namespace = "rofi" }, blur = true, ignore_alpha = 0 })
hl.layer_rule({ match = { namespace = "^(mako|notifications)$" }, blur = true })
hl.layer_rule({ match = { namespace = "waybar" }, blur = true, ignore_alpha = 0 })
