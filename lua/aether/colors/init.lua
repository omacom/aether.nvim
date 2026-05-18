local Util = require("aether.utils")

local M = {}

---@class aether.Palette
---@field accent string Primary accent
---@field cursor string Cursor color
---@field foreground string Foreground alias
---@field background string Background alias
---@field selection_foreground string Selection foreground
---@field selection_background string Selection background
---@field bg string Main background
---@field lighter_bg string Highlighted lines, cursorline
---@field selection string Visual selection
---@field muted string Comments, line numbers, muted text
---@field dark_fg string Secondary text, dark foreground
---@field fg string Main foreground
---@field light_fg string Light foreground
---@field bright_fg string Brightest foreground
---@field red string Red
---@field yellow string Yellow
---@field orange string Orange
---@field green string Green
---@field cyan string Cyan
---@field blue string Blue
---@field purple string Purple
---@field brown string Brown, escape sequences
---@field dark_bg string Darker background, sidebars
---@field darker_bg string Darkest background
---@field bright_red string Bright red
---@field bright_yellow string Bright yellow
---@field bright_green string Bright green
---@field bright_cyan string Bright cyan
---@field bright_blue string Bright blue
---@field bright_purple string Bright purple
local palette = {
  accent = "#ad523c",
  cursor = "#a2aebb",
  foreground = "#a2aebb",
  background = "#1a1d24",
  selection_foreground = "#dfe6eb",
  selection_background = "#4a5366",

  bg = "#1a1d24",
  lighter_bg = "#242830",
  selection = "#2c3040",
  muted = "#4a5366",
  dark_fg = "#6b7688",
  fg = "#a2aebb",
  light_fg = "#c0ccd5",
  bright_fg = "#dfe6eb",

  red = "#ad523c",
  yellow = "#d4a05a",
  orange = "#c47a4e",
  green = "#5e9a7e",
  cyan = "#5b9ea0",
  blue = "#5a8faa",
  purple = "#8b6e9e",
  brown = "#7d5440",
  dark_bg = "#13161c",
  darker_bg = "#0e1015",
  bright_red = "#c46e5a",
  bright_yellow = "#e0b87a",
  bright_green = "#7eb89a",
  bright_cyan = "#7ebcbe",
  bright_blue = "#7aaac2",
  bright_purple = "#a68eba",
}

---Setup the color palette. Caller is expected to pass an already-
---resolved `aether.Config` (e.g. via `aether.config.extend`); this
---function does not re-extend.
---@param opts aether.Config
---@return ColorScheme
function M.setup(opts)
  ---@class ColorScheme: aether.Palette
  local colors = vim.deepcopy(palette)

  -- Apply user color overrides
  if opts.colors and next(opts.colors) then
    colors = vim.tbl_deep_extend("force", colors, opts.colors)
  end

  -- Update Util defaults for blending
  Util.bg = colors.bg
  Util.fg = colors.fg

  colors.none = "NONE"

  -- Git colors
  colors.git = {
    add = colors.green,
    delete = colors.red,
    change = colors.orange,
    ignore = colors.muted,
  }

  -- Diff colors (blended backgrounds)
  colors.diff = {
    add = Util.blend_bg(colors.green, 0.25),
    delete = Util.blend_bg(colors.red, 0.25),
    change = Util.blend_bg(colors.selection, 0.15),
    text = colors.selection,
  }

  -- Derived colors
  colors.black = Util.blend_bg(colors.bg, 0.8, colors.bg)
  colors.border_highlight = Util.blend_bg(colors.blue, 0.8)
  colors.border = colors.muted

  -- UI backgrounds
  colors.bg_popup = colors.dark_bg
  colors.bg_statusline = colors.dark_bg

  colors.bg_sidebar = opts.styles.sidebars == "transparent" and colors.none
    or opts.styles.sidebars == "dark" and colors.dark_bg
    or colors.bg

  colors.bg_float = opts.styles.floats == "transparent" and colors.none
    or opts.styles.floats == "dark" and colors.dark_bg
    or colors.bg

  -- Selection and search
  colors.bg_visual = colors.selection
  colors.bg_search = Util.blend_bg(colors.blue, 0.4)
  colors.fg_sidebar = colors.fg
  colors.fg_float = colors.fg

  -- Diagnostics
  colors.error = colors.red
  colors.warning = colors.yellow
  colors.info = colors.blue
  colors.hint = colors.cyan
  colors.todo = colors.bright_blue

  -- Subtle highlights
  colors.subtle_bg = Util.blend_bg(colors.fg, 0.10)
  colors.cursorline_bg = Util.blend_bg(colors.fg, 0.20)

  -- Rainbow colors (for indent guides, etc.)
  colors.rainbow = {
    colors.blue,
    colors.yellow,
    colors.green,
    colors.cyan,
    colors.purple,
    colors.orange,
    colors.red,
    colors.brown,
  }

  -- Terminal colors
  colors.terminal = {
    black = colors.black,
    black_bright = colors.lighter_bg,
    red = colors.red,
    red_bright = colors.bright_red,
    green = colors.green,
    green_bright = colors.bright_green,
    yellow = colors.yellow,
    yellow_bright = colors.bright_yellow,
    blue = colors.blue,
    blue_bright = colors.bright_blue,
    magenta = colors.purple,
    magenta_bright = colors.bright_purple,
    cyan = colors.cyan,
    cyan_bright = colors.bright_cyan,
    white = colors.dark_fg,
    white_bright = colors.fg,
  }

  -- User callback
  if opts.on_colors then
    opts.on_colors(colors)
  end

  return colors
end

return M
