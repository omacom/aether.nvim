---@class aether
---@field config aether.Config
---@field colors ColorScheme
local M = {}

---Load the colorscheme
---@param opts? aether.Config
---@return ColorScheme colors
---@return table<string, vim.api.keyset.highlight> groups
---@return aether.Config opts
function M.load(opts)
  opts = require("aether.config").extend(opts)
  local hotreload = require("aether.hotreload")
  hotreload.setup()
  local colors, groups, final_opts = require("aether.theme").setup(opts)
  hotreload.notify_engine_loaded()
  return colors, groups, final_opts
end

---Configure aether
---@param opts? aether.Config
function M.setup(opts)
  require("aether.config").setup(opts)
  require("aether.hotreload").setup()
end

return M
