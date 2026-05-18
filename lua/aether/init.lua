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
  -- Idempotent registration: covers the `:colorscheme aether` user path
  -- where colors/aether.vim calls require('aether').load() without ever
  -- routing through M.setup. The did_setup guard inside hotreload makes
  -- the second call a no-op when M.setup already ran.
  require("aether.hotreload").setup()
  return require("aether.theme").setup(opts)
end

---Configure aether. Saves opts and registers hotreload watchers.
---Idempotent. Called automatically by plugin managers that auto-invoke
---setup from a spec with `opts = {...}`.
---@param opts? aether.Config
function M.setup(opts)
  require("aether.config").setup(opts)
  require("aether.hotreload").setup()
end

return M
