-- WezTerm keybindings configuration
local wezterm = require 'wezterm'
local act = wezterm.action
local colors = require 'colors'

local M = {}

-- Key tables for modal keybindings
M.key_tables = {
  -- Resize pane mode
  resize_pane = {
    { key = 'h', action = act.AdjustPaneSize { 'Left', 5 } },
    { key = 'j', action = act.AdjustPaneSize { 'Down', 5 } },
    { key = 'k', action = act.AdjustPaneSize { 'Up', 5 } },
    { key = 'l', action = act.AdjustPaneSize { 'Right', 5 } },
    { key = 'Escape', action = act.PopKeyTable },
    { key = 'Enter', action = act.PopKeyTable },
  },

  -- Copy mode for vi-like navigation
--   copy_mode = {
--     { key = 'h', action = act.CopyMode 'MoveLeft' },
--     { key = 'j', action = act.CopyMode 'MoveDown' },
--     { key = 'k', action = act.CopyMode 'MoveUp' },
--     { key = 'l', action = act.CopyMode 'MoveRight' },
--     { key = 'w', action = act.CopyMode 'MoveForwardWord' },
--     { key = 'b', action = act.CopyMode 'MoveBackwardWord' },
--     { key = '0', action = act.CopyMode 'MoveToStartOfLine' },
--     { key = '$', action = act.CopyMode 'MoveToEndOfLine' },
--     { key = 'v', action = act.CopyMode { SetSelectionMode = 'Cell' } },
--     { key = 'V', action = act.CopyMode { SetSelectionMode = 'Line' } },
--     { key = 'y', action = act.Multiple { { CopyTo = 'ClipboardAndPrimarySelection' }, { CopyMode = 'Close' } } },
--     { key = 'Escape', action = act.CopyMode 'Close' },
--     { key = 'Enter', action = act.CopyMode 'Close' },
--   },
}

-- Main keybinding configuration
M.config = function(config)
  config.key_tables = M.key_tables

  config.keys = {
    -- Pane splitting
    { key = '-', mods = 'ALT', action = act.SplitVertical { domain = 'CurrentPaneDomain' } },
    { key = '\\', mods = 'ALT', action = act.SplitHorizontal { domain = 'CurrentPaneDomain' } },

    -- Pane navigation
    { key = 'h', mods = 'ALT', action = act.ActivatePaneDirection 'Left' },
    { key = 'j', mods = 'ALT', action = act.ActivatePaneDirection 'Down' },
    { key = 'k', mods = 'ALT', action = act.ActivatePaneDirection 'Up' },
    { key = 'l', mods = 'ALT', action = act.ActivatePaneDirection 'Right' },

    -- Close pane
    { key = 'w', mods = 'ALT', action = act.CloseCurrentPane { confirm = true } },

    -- Tabs
    { key = 't', mods = 'CTRL', action = act.SpawnTab 'CurrentPaneDomain' },
    { key = 'w', mods = 'CTRL', action = act.CloseCurrentTab { confirm = false } },
    { key = 'Tab', mods = 'CTRL', action = act.ActivateTabRelative(1) },
    { key = 'Tab', mods = 'CTRL|SHIFT', action = act.ActivateTabRelative(-1) },

    -- Font size
    { key = '+', mods = 'CTRL', action = act.IncreaseFontSize },
    { key = '-', mods = 'CTRL', action = act.DecreaseFontSize },
    { key = '0', mods = 'CTRL', action = act.ResetFontSize },

    -- Copy/Paste
    { key = 'c', mods = 'CTRL|SHIFT', action = act.CopyTo 'Clipboard' },
    { key = 'v', mods = 'CTRL|SHIFT', action = act.PasteFrom 'Clipboard' },

    -- Toggle fullscreen
    { key = 'F11', mods = '', action = act.ToggleFullScreen },

    -- Enter resize mode
    { key = 'r', mods = 'ALT', action = act.ActivateKeyTable { name = 'resize_pane', one_shot = false } },

    -- Enter copy mode
    { key = 'c', mods = 'ALT', action = act.ActivateCopyMode },

    -- Cycle color schemes
    { key = 'p', mods = 'CTRL|SHIFT', action = wezterm.action_callback(colors.cycle_scheme) },

    -- Launch programs
--     { key = 'e', mods = 'ALT', action = act.SpawnCommandInNewTab { args = { 'nvim' } } },
--     { key = 'o', mods = 'CTRL', action = act.SpawnCommandInNewTab { args = { 'yazi' } } },

    -- Search
--     { key = 'f', mods = 'CTRL', action = act.Search },

    -- Scrollback
    { key = 'k', mods = 'CTRL|SHIFT', action = act.ScrollByPage(-0.5) },
    { key = 'j', mods = 'CTRL|SHIFT', action = act.ScrollByPage(0.5) },
  }

  return config
end

return M
