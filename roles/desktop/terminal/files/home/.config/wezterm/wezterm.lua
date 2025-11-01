-- WezTerm configuration
-- Main configuration file that loads modular components

local wezterm = require 'wezterm'

-- Import modular configurations
local colors = require 'colors'
local keybindings = require 'keybindings'

-- Create a config builder
local config = wezterm.config_builder()

-- General settings
config.font = wezterm.font_with_fallback {
  'JetBrains Mono Nerd Font',
  'Fira Code',
  'Noto Sans Mono',
}
config.font_size = 12.0
config.line_height = 1.1
config.window_padding = {
  left = 5,
  right = 5,
  top = 5,
  bottom = 5,
}

-- Tab bar settings
config.use_fancy_tab_bar = true
config.tab_bar_at_bottom = false
config.hide_tab_bar_if_only_one_tab = true

-- Cursor settings
config.cursor_blink_rate = 800
config.default_cursor_style = 'SteadyBar'

-- Misc settings
config.audible_bell = 'Disabled'
config.window_close_confirmation = 'NeverPrompt'
config.enable_scroll_bar = true
config.automatically_reload_config = false

-- Scrollback
config.scrollback_lines = 10000

-- Apply modular configurations
config = colors.config(config)
config = keybindings.config(config)

return config
