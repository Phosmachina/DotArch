-- WezTerm colors configuration
local wezterm = require 'wezterm'

local M = {}

-- Color schemes
M.schemes = {
  default = 'Dark Pastel',

  -- Alternate schemes for easy switching
  alternates = {
    'Catppuccin Mocha',
    'Dracula',
    'Nord',
    'Tokyo Night',
    'Solarized Dark',
    'Solarized Light',
    'One Dark',
    'Material Darker',
    'Kanagawa (Gogh)',
  },

  -- Custom color scheme
  custom = {
    background = '#282828',
    foreground = '#ebdbb2',
    cursor_bg = '#d5c4a1',
    cursor_fg = '#282828',
    cursor_border = '#d5c4a1',
    selection_bg = '#665c54',
    selection_fg = '#ebdbb2',
    ansi = {
      '#282828', -- black
      '#cc241d', -- red
      '#98971a', -- green
      '#d79921', -- yellow
      '#458588', -- blue
      '#b16286', -- magenta
      '#689d6a', -- cyan
      '#a89984', -- white
    },
    brights = {
      '#928374', -- bright black
      '#fb4934', -- bright red
      '#b8bb26', -- bright green
      '#fabd2f', -- bright yellow
      '#83a598', -- bright blue
      '#d3869b', -- bright magenta
      '#8ec07c', -- bright cyan
      '#ebdbb2', -- bright white
    },
  },
}

-- Color-related configuration
M.config = function(config)
  -- Set the color scheme
  config.color_scheme = M.schemes.default

  -- Window background opacity
  config.window_background_opacity = 0.7

  -- Tab bar colors
  config.colors = {
    tab_bar = {
      background = '#282828',
      active_tab = {
        bg_color = '#504945',
        fg_color = '#ebdbb2',
        intensity = 'Normal',
        underline = 'None',
        italic = false,
        strikethrough = false,
      },
      inactive_tab = {
        bg_color = '#3c3836',
        fg_color = '#a89984',
        intensity = 'Normal',
        underline = 'None',
        italic = false,
        strikethrough = false,
      },
      inactive_tab_hover = {
        bg_color = '#504945',
        fg_color = '#d5c4a1',
        intensity = 'Normal',
        underline = 'None',
        italic = true,
        strikethrough = false,
      },
      new_tab = {
        bg_color = '#3c3836',
        fg_color = '#a89984',
        intensity = 'Normal',
        underline = 'None',
        italic = false,
        strikethrough = false,
      },
      new_tab_hover = {
        bg_color = '#504945',
        fg_color = '#d5c4a1',
        intensity = 'Normal',
        underline = 'None',
        italic = true,
        strikethrough = false,
      },
    },
  }

  return config
end

-- Function to cycle through color schemes
M.cycle_scheme = function(window, pane)
  local overrides = window:get_config_overrides() or {}
  local current_scheme = overrides.color_scheme or M.schemes.default

  local all_schemes = {M.schemes.default}
  for _, scheme in ipairs(M.schemes.alternates) do
    table.insert(all_schemes, scheme)
  end

  local next_idx = 1
  for i, scheme in ipairs(all_schemes) do
    if scheme == current_scheme then
      next_idx = i % #all_schemes + 1
      break
    end
  end

  overrides.color_scheme = all_schemes[next_idx]
  window:set_config_overrides(overrides)

  -- Show a notification with the current scheme name
  window:toast_notification('wezterm', 'Color scheme: ' .. overrides.color_scheme, nil, 4000)
end

return M
