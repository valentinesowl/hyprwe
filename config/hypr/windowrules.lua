-- Inspect windows with `hyprctl clients`. Effects are applied in order.
hl.window_rule({ match = { class = ".*" }, tile = true })
hl.window_rule({ match = { class = "^(kitty)$" }, suppress_event = "maximize" })
hl.window_rule({ match = { class = "^(xdg-desktop-portal-gtk)$" }, no_initial_focus = true })
hl.window_rule({
    match = { class = "^(firefox|librewolf|zen|chromium|google-chrome|brave-browser|vivaldi-stable|mpv|vlc|Celluloid|io.github.celluloid)$" },
    idle_inhibit = "fullscreen",
})

hl.layer_rule({ match = { namespace = "rofi" }, blur = true, ignore_alpha = 0 })
-- Notifications own their opaque, rounded mako surface. A compositor backdrop
-- would show as a translucent square outside that surface.
hl.layer_rule({ match = { namespace = "^(mako|notifications)$" }, no_anim = true })
hl.layer_rule({ match = { namespace = "waybar" }, blur = true, ignore_alpha = 0 })
