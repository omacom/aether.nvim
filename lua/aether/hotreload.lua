-- Hot reload configuration for aether.nvim
-- Provides automatic reloading when the plugin or config changes
-- @module aether.hotreload

local M = {}

-- Configuration constants
local LAZY_RELOAD_DELAY_MS = 100
-- The aether CLI commonly rewrites neovim.lua several times per theme
-- generation (palette write, blueprint pass, post-process). A 1500 ms
-- trailing-edge window comfortably absorbs that burst while still feeling
-- responsive to the user.
local EXTERNAL_RELOAD_DELAY_MS = 1500
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

-- Prefer vim.uv (Neovim 0.10+), fall back to vim.loop on older builds.
local uv = vim.uv or vim.loop

-- Keep libuv fs_event handles alive; if collected the watcher stops firing.
-- Keyed by path so we can introspect and avoid duplicate watchers.
local fs_event_handles = {}

-- Per-path debounce timers. An atomic file write produces several inotify
-- events (IN_MOVE_SELF, IN_ATTRIB, IN_MODIFY, etc.); we collapse a burst into
-- a single reload by cancel-and-rescheduling the timer on each event.
local pending_reload_timers = {}

--- Check if aether is the currently active colorscheme
--- @return boolean
local function is_aether_active()
  return vim.g.colors_name == "aether"
end

-- Modules that must survive a hotreload cycle. Clearing aether.hotreload
-- would drop the did_setup guard and re-register every autocmd / fs_event
-- watcher on the next aether.setup() call, snowballing reloads.
local PRESERVED_MODULES = {
  ["aether.hotreload"] = true,
}

--- Clear all aether-related modules from package cache
--- @param include_config boolean Whether to also clear the config module
local function clear_aether_modules(include_config)
  for module_name in pairs(package.loaded) do
    local is_aether_module = module_name:match(AETHER_MODULE_PATTERN)
    local is_lualine_theme = module_name:match(LUALINE_THEME_PATTERN)
    local is_config_module = module_name == "aether.config"

    local should_clear = (is_aether_module or is_lualine_theme)
      and not PRESERVED_MODULES[module_name]
      and (include_config or not is_config_module)

    if should_clear then
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

--- Stop and close the existing watcher for a path, if any.
--- @param path string
local function stop_fs_watch(path)
  local existing = fs_event_handles[path]
  if not existing then
    return
  end
  pcall(function()
    if not existing:is_closing() then
      existing:stop()
      existing:close()
    end
  end)
  fs_event_handles[path] = nil
end

--- Schedule a reload for `path`, cancelling any in-flight reload for the
--- same path. Collapses bursts of inotify events into a single reload.
--- @param path string
local function schedule_reload(path)
  local existing = pending_reload_timers[path]
  if existing then
    pcall(function()
      if not existing:is_closing() then
        existing:stop()
        existing:close()
      end
    end)
  end

  pending_reload_timers[path] = vim.defer_fn(function()
    pending_reload_timers[path] = nil
    if not is_aether_active() then
      return
    end
    reload_with_fresh_opts(path)
  end, EXTERNAL_RELOAD_DELAY_MS)
end

--- Start a libuv fs_event watcher on a single path.
--- Re-arms itself on every event because atomic writes (write-temp + rename)
--- swap the inode and would otherwise leave the original watcher stranded.
--- Also watches the parent directory so a deleted-then-recreated file is
--- still picked up (inotify on the inode alone would miss this).
--- @param path string Absolute path to watch
local function start_fs_watch(path)
  if not uv or not uv.new_fs_event then
    return
  end

  stop_fs_watch(path)

  if vim.fn.filereadable(path) ~= 1 then
    return
  end

  local handle = uv.new_fs_event()
  if not handle then
    return
  end

  local function on_change()
    -- Always tear down and re-arm; the file we were watching may no longer
    -- exist at the same inode after an atomic rename.
    stop_fs_watch(path)

    vim.defer_fn(function()
      start_fs_watch(path)
    end, FS_EVENT_REARM_DELAY_MS)

    schedule_reload(path)
  end

  local ok, err = handle:start(path, {}, vim.schedule_wrap(on_change))
  if ok == 0 then
    fs_event_handles[path] = handle
  else
    vim.schedule(function()
      vim.notify(
        ("aether.nvim: failed to watch %s (%s)"):format(path, err or "unknown"),
        vim.log.levels.WARN
      )
    end)
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

--- Setup user command for inspecting hotreload state.
--- Prints which external paths are being watched and whether their handles
--- are alive, plus a manual "reload from this path" probe.
local function setup_status_command()
  vim.api.nvim_create_user_command("AetherReloadStatus", function()
    local lines = { "aether.nvim hotreload status:" }
    table.insert(lines, ("  colors_name = %s"):format(tostring(vim.g.colors_name)))
    table.insert(lines, ("  uv backend  = %s"):format(uv == vim.uv and "vim.uv" or "vim.loop"))
    for _, path in ipairs(EXTERNAL_THEME_PATHS) do
      local readable = vim.fn.filereadable(path) == 1
      local handle = fs_event_handles[path]
      local active = handle and not handle:is_closing() or false
      table.insert(
        lines,
        ("  %s  readable=%s  watching=%s"):format(path, tostring(readable), tostring(active))
      )
    end
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
  end, { desc = "Show aether hotreload watcher status" })
end

local did_setup = false

--- Initialize hot reload functionality
--- Sets up autocmds and user commands for automatic theme reloading.
--- Idempotent: safe to call multiple times (e.g. from both the plugin entry
--- and a user's own require("aether.hotreload").setup() line).
function M.setup()
  if did_setup then
    return
  end
  did_setup = true

  setup_lazy_reload_autocmd()
  setup_dev_file_watcher()
  setup_external_config_watcher()
  setup_reload_command()
  setup_status_command()
end

return M
