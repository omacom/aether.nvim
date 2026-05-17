-- Hot reload configuration for aether.nvim
-- Provides automatic reloading when the plugin or config changes
-- @module aether.hotreload

local M = {}

-- Configuration constants
local LAZY_RELOAD_DELAY_MS = 100
local EXTERNAL_RELOAD_DELAY_MS = 150
local FS_EVENT_REARM_DELAY_MS = 50

-- External theme spec files written by theme generators (aether CLI, omarchy).
-- Each is a full lazy.nvim plugin spec returning `{ { "...aether.nvim", opts = {...} } }`.
local EXTERNAL_THEME_PATHS = {
  vim.fn.expand("~/.config/aether/theme/neovim.lua"),
  vim.fn.expand("~/.config/omarchy/current/theme/neovim.lua"),
}

-- Patterns for module matching
local AETHER_MODULE_PATTERN = "^aether"
local LUALINE_THEME_PATTERN = "^lualine%.themes%.aether"

-- Keep libuv fs_event handles alive; if collected the watcher stops firing.
local fs_event_handles = {}

--- Check if aether is the currently active colorscheme
--- @return boolean
local function is_aether_active()
  return vim.g.colors_name == "aether"
end

--- Clear all aether-related modules from package cache
--- @param include_config boolean Whether to also clear the config module
local function clear_aether_modules(include_config)
  for module_name in pairs(package.loaded) do
    local is_aether_module = module_name:match(AETHER_MODULE_PATTERN)
    local is_lualine_theme = module_name:match(LUALINE_THEME_PATTERN)
    local is_config_module = module_name == "aether.config"

    if (is_aether_module or is_lualine_theme) and (include_config or not is_config_module) then
      package.loaded[module_name] = nil
    end
  end
end

--- Clear all highlight groups and reset syntax
local function clear_highlights()
  vim.cmd("highlight clear")

  if vim.fn.exists("syntax_on") == 1 then
    vim.cmd("syntax reset")
  end

  vim.g.colors_name = nil
end

--- Trigger post-reload updates
local function trigger_post_reload_events()
  vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "aether", modeline = false })
  vim.cmd("redraw!")
end

--- Load aether theme with given options
--- @param opts table|nil Theme options
--- @return boolean success
local function load_theme(opts)
  local ok, aether = pcall(require, "aether")
  if not ok then
    vim.notify("Failed to load aether.nvim", vim.log.levels.ERROR)
    return false
  end

  if opts then
    aether.setup(opts)
  end

  aether.load()
  return true
end

--- Check if the theme spec is for aether
--- @param theme_spec table Theme specification
--- @return boolean
local function is_aether_theme(theme_spec)
  if not theme_spec or not theme_spec[1] then
    return false
  end

  local plugin_name = theme_spec[1][1] or theme_spec[1].name
  return plugin_name and plugin_name:match("aether")
end

--- Get fresh theme options from lazy.nvim config
--- @return table|nil opts Theme options or nil if not found
local function get_theme_opts()
  package.loaded["plugins.theme"] = nil

  local ok, theme_spec = pcall(require, "plugins.theme")
  if not ok or not is_aether_theme(theme_spec) then
    return nil
  end

  return theme_spec[1].opts
end

--- Get fresh theme options by executing an external lazy spec file directly.
--- Used when the aether/omarchy CLI rewrites the spec on disk.
--- @param path string Absolute path to a lazy.nvim plugin spec file
--- @return table|nil opts Theme options or nil if file is missing/invalid
local function get_theme_opts_from_file(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end

  local ok, theme_spec = pcall(dofile, path)
  if not ok or type(theme_spec) ~= "table" or not is_aether_theme(theme_spec) then
    return nil
  end

  return theme_spec[1].opts
end

--- Reload the aether colorscheme with current configuration
--- This preserves the existing config module to maintain user options
local function reload_colorscheme()
  clear_aether_modules(false) -- Don't clear config

  vim.schedule(function()
    clear_highlights()

    if not load_theme() then
      return
    end

    trigger_post_reload_events()
    vim.notify("aether.nvim reloaded", vim.log.levels.INFO)
  end)
end

--- Reload the aether colorscheme with fresh options from config
--- This clears ALL modules including config and reloads with new options
--- This works both when aether is active (reload) and when switching to aether (load)
--- @param source_path string|nil Optional path to read opts from directly; falls back to plugins.theme
local function reload_with_fresh_opts(source_path)
  local opts = source_path and get_theme_opts_from_file(source_path) or get_theme_opts()
  if not opts then
    -- Theme is not aether or failed to load, skip reload
    return
  end

  local was_active = is_aether_active()

  clear_aether_modules(true) -- Clear everything including config
  clear_highlights()

  if not load_theme(opts) then
    return
  end

  trigger_post_reload_events()

  if was_active then
    vim.notify("aether.nvim reloaded with new colors", vim.log.levels.INFO)
  else
    vim.notify("aether.nvim loaded", vim.log.levels.INFO)
  end
end

--- Setup autocmd for lazy.nvim reload events
local function setup_lazy_reload_autocmd()
  vim.api.nvim_create_autocmd("User", {
    pattern = "LazyReload",
    callback = function(event)
      -- Only handle aether plugin reloads
      if event.data and event.data ~= "aether.nvim" and event.data ~= "aether" then
        return
      end

      -- Defer to ensure lazy.nvim completes its reload process
      -- Note: We check if the config has aether inside reload_with_fresh_opts()
      -- instead of checking is_aether_active() here, because we want to reload
      -- when switching TO aether, not just when aether is already active
      vim.defer_fn(reload_with_fresh_opts, LAZY_RELOAD_DELAY_MS)
    end,
    desc = "Reload aether theme when lazy.nvim detects changes",
  })
end

--- Setup autocmd for plugin development file changes
local function setup_dev_file_watcher()
  local plugin_path = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")

  vim.api.nvim_create_autocmd("BufWritePost", {
    pattern = plugin_path .. "/lua/**/*.lua",
    callback = function()
      if is_aether_active() then
        reload_colorscheme()
      end
    end,
    desc = "Reload aether theme on plugin file changes during development",
  })
end

--- Start a libuv fs_event watcher on a single path.
--- Re-arms itself on every event because atomic writes (write-temp + rename)
--- swap the inode and would otherwise leave the original watcher stranded.
--- @param path string Absolute path to watch
local function start_fs_watch(path)
  if vim.fn.filereadable(path) ~= 1 then
    return
  end

  local handle = vim.uv.new_fs_event()
  if not handle then
    return
  end

  local function on_change(err)
    -- Always tear down and re-arm; the file we were watching may no longer
    -- exist at the same inode after an atomic rename.
    handle:stop()
    handle:close()

    vim.defer_fn(function()
      start_fs_watch(path)
    end, FS_EVENT_REARM_DELAY_MS)

    if err then
      return
    end

    if not is_aether_active() then
      return
    end

    vim.defer_fn(function()
      reload_with_fresh_opts(path)
    end, EXTERNAL_RELOAD_DELAY_MS)
  end

  local ok = handle:start(path, {}, vim.schedule_wrap(on_change))
  if ok == 0 or ok == nil then
    table.insert(fs_event_handles, handle)
  else
    handle:close()
  end
end

--- Setup filesystem watchers for external theme spec files written by CLI
--- tools (aether, omarchy). BufWritePost only fires for in-editor writes, so
--- we use libuv fs_event to catch out-of-process rewrites too.
local function setup_external_config_watcher()
  for _, path in ipairs(EXTERNAL_THEME_PATHS) do
    start_fs_watch(path)
  end
end

--- Setup user command for manual reloading
local function setup_reload_command()
  vim.api.nvim_create_user_command("AetherReload", function()
    if is_aether_active() then
      reload_colorscheme()
    else
      vim.notify("aether is not the active colorscheme", vim.log.levels.WARN)
    end
  end, { desc = "Manually reload aether colorscheme" })
end

--- Initialize hot reload functionality
--- Sets up autocmds and user commands for automatic theme reloading
function M.setup()
  setup_lazy_reload_autocmd()
  setup_dev_file_watcher()
  setup_external_config_watcher()
  setup_reload_command()
end

return M
