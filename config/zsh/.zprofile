# ~/.config/zsh/.zprofile — HWE login shell (ZDOTDIR).
# Read once for login shells, before .zshrc. Mirrors the bash autostart: launch
# Hyprland on the first virtual terminal. The tty guard means opening kitty
# (which runs a login shell on /dev/pts/*) never re-triggers this.

if [ -z "${WAYLAND_DISPLAY:-}" ] && [ "$(tty)" = "/dev/tty1" ]; then
    if command -v uwsm >/dev/null 2>&1 && uwsm check may-start; then
        exec uwsm start hyprland.desktop
    else
        exec Hyprland
    fi
fi
