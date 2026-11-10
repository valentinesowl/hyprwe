local terminal = "kitty"
local file_manager = "dolphin"
local browser = "firefox"
local launcher = "rofi -show drun"

local function bind(keys, action, description, flags)
    local options = flags or {}
    options.description = description
    hl.bind(keys, action, options)
end

-- Core apps and window actions.
bind("SUPER + T", hl.dsp.exec_cmd(terminal), "Terminal (kitty)")
bind("SUPER + N", hl.dsp.exec_cmd(file_manager), "File manager (Dolphin)")
bind("SUPER + B", hl.dsp.exec_cmd(browser), "Web browser")
bind("SUPER + R", hl.dsp.exec_cmd(launcher), "Application launcher")
bind("SUPER + Q", hl.dsp.window.close(), "Close window")
bind("SUPER + V", hl.dsp.window.float(), "Toggle floating")
bind("SUPER + F", hl.dsp.window.fullscreen(), "Fullscreen")
bind("SUPER + SHIFT + P", hl.dsp.window.pseudo(), "Pseudo-tile")
bind("SUPER + J", hl.dsp.layout("togglesplit"), "Toggle dwindle split")
bind("SUPER + L", hl.dsp.exec_cmd("hyprlock"), "Lock session")
bind("SUPER + Escape", hl.dsp.exec_cmd("hyprlock"), "Lock session")
bind("SUPER + SHIFT + R", hl.dsp.exec_cmd("hyprctl reload"), "Reload Hyprland config")
bind("SUPER + SHIFT + T", hl.dsp.exec_cmd("hwe theme pick"), "Pick theme")
bind("SUPER + SHIFT + W", hl.dsp.exec_cmd("hwe wall pick"), "Pick wallpaper")
bind("SUPER + SHIFT + E", hl.dsp.exec_cmd("hwe power"), "Session menu")
bind("SUPER + slash", hl.dsp.exec_cmd("hwe keys"), "Keybind cheatsheet")
bind("SUPER + C", hl.dsp.exec_cmd("hwe clip"), "Clipboard history")
bind("SUPER + SHIFT + C", hl.dsp.exec_cmd("hyprpicker -a -f hex"), "Pick a screen colour")
bind("SUPER + ALT + R", hl.dsp.exec_cmd("hwe record"), "Record the whole screen")
bind("SUPER + ALT + S", hl.dsp.exec_cmd("hwe record region"), "Record a selected region")
bind("SUPER + SHIFT + Q", hl.dsp.exit(), "Exit Hyprland session")
bind("SUPER + SPACE", hl.dsp.exec_cmd("hyprctl switchxkblayout current next"), "Cycle keyboard layout", { locked = true })

-- Screenshots.
bind("Print", hl.dsp.exec_cmd("grim - | wl-copy"), "Whole screen to clipboard")
bind("SHIFT + Print", hl.dsp.exec_cmd('g=$(slurp) && grim -g "$g" - | wl-copy'), "Region to clipboard")
bind("SUPER + Print", hl.dsp.exec_cmd('g=$(slurp) && mkdir -p ~/Pictures && grim -g "$g" ~/Pictures/$(date +%F_%H-%M-%S).png'), "Region to file")
local annotate = 'g=$(slurp) && mkdir -p ~/Pictures && grim -g "$g" - | satty --filename - --copy-command wl-copy --output-filename ~/Pictures/$(date +%F_%H-%M-%S).png'
bind("SUPER + SHIFT + Print", hl.dsp.exec_cmd(annotate), "Annotate region")
bind("SUPER + P", hl.dsp.exec_cmd(annotate), "Annotate region")

-- Volume and brightness; repeating and locked match the former bindel/bindl flags.
bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("swayosd-client --output-volume raise"), "Raise volume", { repeating = true, locked = true })
bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("swayosd-client --output-volume lower"), "Lower volume", { repeating = true, locked = true })
bind("XF86AudioMute", hl.dsp.exec_cmd("swayosd-client --output-volume mute-toggle"), "Mute audio", { locked = true })
bind("XF86AudioMicMute", hl.dsp.exec_cmd("swayosd-client --input-volume mute-toggle"), "Mute microphone", { locked = true })
bind("XF86MonBrightnessUp", hl.dsp.exec_cmd("swayosd-client --brightness raise"), "Raise brightness", { repeating = true, locked = true })
bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("swayosd-client --brightness lower"), "Lower brightness", { repeating = true, locked = true })

bind("XF86AudioPlay", hl.dsp.exec_cmd("playerctl play-pause"), "Play or pause media", { locked = true })
bind("XF86AudioPause", hl.dsp.exec_cmd("playerctl play-pause"), "Pause media", { locked = true })
bind("XF86AudioNext", hl.dsp.exec_cmd("playerctl next"), "Next media track", { locked = true })
bind("XF86AudioPrev", hl.dsp.exec_cmd("playerctl previous"), "Previous media track", { locked = true })

local directions = { left = "left", right = "right", up = "up", down = "down" }
for key, direction in pairs(directions) do
    bind("SUPER + " .. key, hl.dsp.focus({ direction = direction }), "Move focus " .. direction)
    bind("SUPER + SHIFT + " .. key, hl.dsp.window.move({ direction = direction }), "Move window " .. direction)
end

for workspace = 1, 10 do
    local key = tostring(workspace % 10)
    local target = tostring(workspace)
    bind("SUPER + " .. key, hl.dsp.focus({ workspace = target }), "Switch to workspace " .. target)
    bind("SUPER + SHIFT + " .. key, hl.dsp.window.move({ workspace = target }), "Move window to workspace " .. target)
end

bind("SUPER + mouse_down", hl.dsp.focus({ workspace = "e+1" }), "Next workspace")
bind("SUPER + mouse_up", hl.dsp.focus({ workspace = "e-1" }), "Previous workspace")
bind("SUPER + X", hl.dsp.workspace.toggle_special("magic"), "Toggle scratchpad")
bind("SUPER + SHIFT + X", hl.dsp.window.move({ workspace = "special:magic" }), "Move window to scratchpad")

local function session_command(action, slot)
    return string.format(
        'hwe session %s %d && hyprctl notify 0 2500 "rgb(88c0d0)" "HWE: %s slot %d" || hyprctl notify 0 4000 "rgb(ff5555)" "HWE: %s failed for slot %d"',
        action, slot, action, slot, action, slot
    )
end

bind("SUPER + S", hl.dsp.submap("session"), "Session save/restore mode")
hl.define_submap("session", function()
    for slot = 1, 9 do
        bind(tostring(slot), hl.dsp.exec_cmd(session_command("save", slot)), "Save session slot " .. slot)
        bind("SHIFT + " .. slot, hl.dsp.exec_cmd(session_command("restore", slot)), "Restore session slot " .. slot)
    end
    bind("Escape", hl.dsp.submap("reset"), "Cancel session mode")
end, "reset")

bind("SUPER + mouse:272", hl.dsp.window.drag(), "Drag window", { mouse = true })
bind("SUPER + mouse:273", hl.dsp.window.resize(), "Resize window", { mouse = true })
