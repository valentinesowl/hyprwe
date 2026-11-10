-- Hyprland Workstation Environment (HWE), Hyprland 0.57+.
-- Each required module has its own protected execution scope.

require("environment")
require("monitors")
require("appearance")
require("theme")
require("input")
require("keybindings")
require("windowrules")
require("session-layout")
require("autostart")

local config_home = os.getenv("XDG_CONFIG_HOME")
if config_home == nil or config_home == "" then
    config_home = assert(os.getenv("HOME"), "HOME is not set") .. "/.config"
end
require(config_home .. "/hwe/hypr")
