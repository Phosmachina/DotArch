I want to build a new window manager environment based on hyprland.
We need to disable current x11 based environment:
- rename wm folder to wm_x11 and the remove corresponding entry in common/main role.
- because current wm role is unproperly designed, we need to move unrelated part (like bitwarden, fonts that are not directly correlated to the window manager)
- Remove packages installation in system tasks related to x11

There are my specs for hyprland:
- plugins:
    - hyprfocus
    - Hyprspace
    - Hyprpaper
    - hy3
- tools:
    - Hyprpicker
    - Hyprsunset
    - hypridle
    - hyprlock
- SwayNotificationCenter
- Satty for screenshot
- wl-screenrec for video recording
- cliphist with cliphist-rofi-img
- ashell as status bar
- greetd/tuigreet
- replace rofi by rofi-wayland
- replace lf by yazi
- ~~replace kitty by WezTerm~~

For each programs, try to port current configuration like keybindings, fonts, themes...
