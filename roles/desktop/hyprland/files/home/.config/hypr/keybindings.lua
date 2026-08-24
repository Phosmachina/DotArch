-- Hyprland keybindings configuration

local terminal = "kitty"
local menu = "vicinae toggle"
local mainMod = "SUPER"

-- BASIC KEYBINDS

-- Terminal
hl.bind(mainMod .. " + return", hl.dsp.exec_cmd(terminal))

-- Close window
hl.bind(mainMod .. " + z", hl.dsp.window.close())

-- Exit Hyprland
hl.bind("SUPER + SHIFT + Q", hl.dsp.exit())

-- Reload configuration
hl.bind(mainMod .. " + escape", hl.dsp.exec_cmd("hyprctl reload"))

-- Toggle floating
hl.bind("SUPER + SHIFT + F", hl.dsp.window.float({ action = "toggle" }))

-- Application launcher
hl.bind(mainMod .. " + space", hl.dsp.exec_cmd(menu))

-- Window management
hl.bind("SUPER + CTRL + space", hl.dsp.exec_cmd("vicinae vicinae://launch/wm/switch-windows"))

-- Emoji picker
hl.bind(mainMod .. " + period", hl.dsp.exec_cmd("vicinae vicinae://launch/core/search-emojis"))

-- WINDOW FUNCTIONS

-- Toggle fullscreen
hl.bind(mainMod .. " + f", hl.dsp.window.fullscreen())

-- Window grouping
hl.bind(mainMod .. " + k", hl.dsp.group.toggle()) -- Toggle group (tab mode)

-- Focus management (group/tab switching)
hl.bind(mainMod .. " + bracketleft", hl.dsp.group.prev())
hl.bind(mainMod .. " + bracketright", hl.dsp.group.next())

-- Move window within group
hl.bind("SUPER + SHIFT + bracketleft", hl.dsp.group.move_window({ forward = false }))
hl.bind("SUPER + SHIFT + bracketright", hl.dsp.group.move_window({ forward = true }))

-- Group interaction: try every direction, whichever has a group takes the window
hl.bind(mainMod .. " + g", hl.dsp.window.move({ into_group = "l" }))
hl.bind(mainMod .. " + g", hl.dsp.window.move({ into_group = "r" }))
hl.bind(mainMod .. " + g", hl.dsp.window.move({ into_group = "u" }))
hl.bind(mainMod .. " + g", hl.dsp.window.move({ into_group = "d" }))
hl.bind("SUPER + SHIFT + g", hl.dsp.window.move({ out_of_group = true }))

-- Preselect split direction
hl.bind(mainMod .. " + s", hl.dsp.submap("preselect"))
hl.define_submap("preselect", function()
    local function preselect(direction)
        return function()
            hl.dispatch(hl.dsp.layout("preselect " .. direction))
            hl.dispatch(hl.dsp.submap("reset"))
        end
    end

    hl.bind("left", preselect("l"))
    hl.bind("right", preselect("r"))
    hl.bind("up", preselect("u"))
    hl.bind("down", preselect("d"))
    hl.bind("h", preselect("l"))
    hl.bind("l", preselect("r"))
    hl.bind("k", preselect("u"))
    hl.bind("j", preselect("d"))
    hl.bind("escape", hl.dsp.submap("reset"))
end)

-- Mouse bindings
hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(), { mouse = true })
hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

-- FOCUS MOVEMENT

-- Basic focus movement
hl.bind(mainMod .. " + left", hl.dsp.focus({ direction = "l" }))
hl.bind(mainMod .. " + down", hl.dsp.focus({ direction = "d" }))
hl.bind(mainMod .. " + up", hl.dsp.focus({ direction = "u" }))
hl.bind(mainMod .. " + right", hl.dsp.focus({ direction = "r" }))

-- Resize focused window (percent deltas via hyprctl; hl.dsp.window.resize only takes pixels)
hl.bind("SUPER + CTRL + down", hl.dsp.exec_cmd('hyprctl dispatch resizeactive "0 -5%"'))
hl.bind("SUPER + CTRL + up", hl.dsp.exec_cmd('hyprctl dispatch resizeactive "0 5%"'))
hl.bind("SUPER + CTRL + left", hl.dsp.exec_cmd('hyprctl dispatch resizeactive "5% 0"'))
hl.bind("SUPER + CTRL + right", hl.dsp.exec_cmd('hyprctl dispatch resizeactive "-5% 0"'))

-- Move windows
hl.bind("SUPER + SHIFT + left", hl.dsp.window.move({ direction = "l" }))
hl.bind("SUPER + SHIFT + down", hl.dsp.window.move({ direction = "d" }))
hl.bind("SUPER + SHIFT + up", hl.dsp.window.move({ direction = "u" }))
hl.bind("SUPER + SHIFT + right", hl.dsp.window.move({ direction = "r" }))

-- WORKSPACES

-- Switch to / move to workspace (zero-padded names, as in the old config)
for i = 1, 9 do
    local workspace = string.format("%02d", i)
    hl.bind(mainMod .. " + " .. i, hl.dsp.focus({ workspace = workspace }))
    hl.bind("SUPER + SHIFT + " .. i, hl.dsp.window.move({ workspace = workspace }))
end

-- Swap workspaces
hl.bind("SUPER + SHIFT + s", hl.dsp.exec_cmd("~/.config/hypr/scripts/swap-workspaces.sh"))

-- Navigate between workspaces
hl.bind("SUPER + ALT + right", hl.dsp.exec_cmd("~/.config/hypr/scripts/workspace-cycler.sh next"))
hl.bind("SUPER + ALT + left", hl.dsp.exec_cmd("~/.config/hypr/scripts/workspace-cycler.sh prev"))

-- Scroll through workspaces
hl.bind(mainMod .. " + mouse_down", hl.dsp.exec_cmd("~/.config/hypr/scripts/workspace-cycler.sh next"))
hl.bind(mainMod .. " + mouse_up", hl.dsp.exec_cmd("~/.config/hypr/scripts/workspace-cycler.sh prev"))

-- SPECIAL WORKSPACES

-- Toggle special workspace (scratchpad)
hl.bind(mainMod .. " + grave", hl.dsp.workspace.toggle_special("magic"))
hl.bind("SUPER + SHIFT + grave", hl.dsp.window.move({ workspace = "special:magic" }))

-- MEDIA & VOLUME

-- Volume controls
hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("sound up 1"))
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("sound down 1"))
hl.bind("XF86AudioMute", hl.dsp.exec_cmd("amixer set Master toggle"))

-- Brightness controls
hl.bind("XF86MonBrightnessUp", hl.dsp.exec_cmd("sudo brightnessctl set +5%"))
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("sudo brightnessctl set 5%-"))

-- Media controls (using play-pause script like herbstluftwm)
hl.bind("XF86AudioPlay", hl.dsp.exec_cmd("play-pause"))
hl.bind("XF86AudioNext", hl.dsp.exec_cmd("playerctl -a next"))
hl.bind("XF86AudioPrev", hl.dsp.exec_cmd("playerctl -a previous"))

-- POWER CONTROLS

-- Power menu
hl.bind(mainMod .. " + x", hl.dsp.submap("power"))
hl.define_submap("power", function()
    hl.bind("p", hl.dsp.exec_cmd("poweroff"), { repeating = true })
    hl.bind("r", hl.dsp.exec_cmd("reboot"), { repeating = true })
    hl.bind("s", function()
        hl.dispatch(hl.dsp.exec_cmd("systemctl suspend"))
        hl.dispatch(hl.dsp.submap("reset"))
    end, { repeating = true })
    hl.bind("l", function()
        hl.dispatch(hl.dsp.exec_cmd("hyprlock"))
        hl.dispatch(hl.dsp.submap("reset"))
    end, { repeating = true })
    hl.bind("b", function()
        hl.dispatch(hl.dsp.dpms({ action = "toggle" }))
        hl.dispatch(hl.dsp.submap("reset"))
    end, { repeating = true })
    hl.bind("catchall", hl.dsp.submap("reset"))
end)

-- SCREENSHOT/CLIP

-- Screenshot with hyprshot
hl.bind("SUPER + PRINT", hl.dsp.exec_cmd("hyprshot -m window --raw | satty --filename -"))
hl.bind("PRINT", hl.dsp.exec_cmd("hyprshot -m output --raw | satty --filename -"))
hl.bind("SUPER + SHIFT + PRINT", hl.dsp.exec_cmd("hyprshot -m region --raw | satty --filename -"))

-- Screen recording
hl.bind("SUPER + ALT + PRINT", hl.dsp.exec_cmd('wl-screenrec -g "$(slurp)"'))
hl.bind("SUPER + ALT + SHIFT + PRINT", hl.dsp.exec_cmd("killall -INT wl-screenrec"))

-- Toggle waybar
hl.bind("SUPER + ALT + p", hl.dsp.exec_cmd("killall -SIGUSR1 waybar"))

-- Color picker
hl.bind(mainMod .. " + c", hl.dsp.exec_cmd("hyprpicker -a"))

-- Clipboard history
hl.bind(mainMod .. " + v", hl.dsp.exec_cmd("vicinae 'vicinae://launch/clipboard/history?toggle=true'"))

-- NOTIFICATIONS

-- Notification center
hl.bind(mainMod .. " + n", hl.dsp.exec_cmd("swaync-client -t"))

-- Transcript (audio recording and transcription)
hl.bind(mainMod .. " + a", hl.dsp.exec_cmd("transcript"))

-- Video playback controls
hl.bind(mainMod .. " + d", hl.dsp.submap("video-note"))
hl.define_submap("video-note", function()
    hl.bind("p", hl.dsp.exec_cmd("play-pause_video_note"), { repeating = true })
    hl.bind("r", hl.dsp.exec_cmd("play-pause_video_from_clip"), { repeating = true })
    hl.bind("escape", hl.dsp.submap("reset"))
end)
