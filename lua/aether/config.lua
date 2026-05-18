---@class aether.Config
---@field name? string Colorscheme name
---@field transparent? boolean Disable background color
---@field terminal_colors? boolean Configure terminal colors
---@field styles? aether.Styles Syntax styling options
---@field dim_inactive? boolean Dim inactive windows
---@field lualine_bold? boolean Bold lualine section headers
---@field colors? table<string, string> Color overrides
---@field on_colors? fun(colors: ColorScheme) Callback to modify colors
---@field on_highlights? fun(highlights: aether.Highlights, colors: ColorScheme) Callback to modify highlights
---@field plugins? aether.Plugins Plugin configuration

---@class aether.Styles
---@field comments? vim.api.keyset.highlight Comment style
---@field keywords? vim.api.keyset.highlight Keyword style
---@field functions? vim.api.keyset.highlight Function style
---@field variables? vim.api.keyset.highlight Variable style
---@field sidebars? "dark"|"transparent"|"normal" Sidebar style
---@field floats? "dark"|"transparent"|"normal" Float style

---@class aether.Plugins
---@field all? boolean Enable all plugins
---@field auto? boolean Auto-detect plugins

---@alias aether.Highlight vim.api.keyset.highlight|string
---@alias aether.Highlights table<string, aether.Highlight>
---@alias aether.HighlightsFn fun(colors: ColorScheme, opts: aether.Config): aether.Highlights

local M = {}

---@type aether.Config
M.defaults = {
  name = "aether",
  transparent = false,
  terminal_colors = true,
  styles = {
    comments = { italic = true },
    keywords = { italic = true },
    functions = {},
    variables = {},
    sidebars = "dark",
    floats = "dark",
  },
  dim_inactive = false,
  lualine_bold = false,
  colors = {},
  on_colors = function() end,
  on_highlights = function() end,
  plugins = {
    all = package.loaded.lazy == nil,
    auto = true,
  },
}

---@type aether.Config
M.options = nil

---Configure aether
---@param options? aether.Config
function M.setup(options)
  M.options = vim.tbl_deep_extend("force", {}, M.defaults, options or {})
end

---Extend current options with overrides. Falls back to defaults when
---`setup` has not been called yet.
---@param opts? aether.Config
---@return aether.Config
function M.extend(opts)
  local base = M.options or M.defaults
  if not opts then
    return base
  end
  return vim.tbl_deep_extend("force", {}, base, opts)
end

return M
