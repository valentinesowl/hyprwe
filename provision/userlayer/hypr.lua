-- ~/.config/hwe/hypr.lua — your Hyprland settings (Hyprland 0.57+).
-- This file is yours. It loads after every HWE module, so your values win.
-- Apply changes with `hyprctl reload` (SUPER+SHIFT+R).

-- Displays: list outputs with `hyprctl monitors`.
-- hl.monitor({ output = "eDP-1", mode = "2560x1600@165", position = "0x0", scale = 1.6 })
-- hl.monitor({ output = "DP-1", mode = "preferred", position = "auto-right", scale = 1.5 })

-- Input and other options: only the keys you name are changed.
-- hl.config({
--     input = {
--         kb_layout = "us,de",
--         repeat_rate = 40,
--         touchpad = { natural_scroll = true },
--     },
-- })

-- Reduced motion: set true to disable window animations and the infinite border
-- loop. Reload Hyprland, then run `hwe theme apply` to disable Waybar transitions too.
-- This personal file is preserved by theme apply and hwe update.
-- local reduced_motion = true
-- if reduced_motion then
--     hl.config({ animations = { enabled = false }, decoration = { blur = { enabled = false } } })
--     hl.animation({ leaf = "borderangle", enabled = false })
-- end

-- Keybindings: unbind the exact key string before replacing an HWE binding.
-- hl.unbind("SUPER + T")
-- hl.bind("SUPER + RETURN", hl.dsp.exec_cmd("kitty"), { description = "Terminal" })

-- Autostart runs once at login, not on every config reload.
-- hl.on("hyprland.start", function()
--     hl.exec_cmd("nm-applet --indicator")
-- end)
