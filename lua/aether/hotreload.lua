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

-- All persistent state lives on _G so it survives module reloads. Lazy.nvim's
-- change_detection (or any other reloader) can clear
-- package.loaded["aether.hotreload"] independently of our PRESERVED_MODULES
-- guard. If our state died with the module, the next setup() would create
-- fresh fs_event handles and autocmd entries on top of the still-live old
-- ones, accumulating watchers (the "1, 2, 3, 4 notifications" symptom).
-- Keying on _G means there is exactly one state table for the lifetime of
-- the Neovim session no matter how many times the module reloads.
_G.__aether_hotreload_state = _G.__aether_hotreload_state or {
  did_setup = false,
  -- Keep libuv fs_event handles alive (keyed by path); if collected the
  -- watcher stops firing.
  fs_event_handles = {},
  -- Per-path debounce timers. Cancel-and-reschedule on each event so a
  -- burst of inotify events collapses to a single reload.
  pending_reload_timers = {},
  -- Hash of the opts last applied to the colorscheme. Used to dedup reloads
  -- across ALL trigger sources (fs_event, LazyReload, manual).
  last_applied_opts_hash = nil,
  -- Last colors_name observed immediately after aether.load() ran. Used so
  -- derivative colorschemes (e.g. hackerman) that call aether.load() from
  -- their colors/<name>.lua still count as "aether active" even though
  -- g:colors_name != "aether".
  engine_colors_name = nil,
}
local state = _G.__aether_hotreload_state
state.fs_event_handles = state.fs_event_handles or {}
state.pending_reload_timers = state.pending_reload_timers or {}

--- Hash an opts table by its inspected representation. Cheap enough to run
--- on every reload candidate and stable across identical tables.
--- @param opts table
--- @return string
local function opts_hash(opts)
  return vim.fn.sha256(vim.inspect(opts))
end

--- Check if aether is the engine behind the currently active colorscheme.
--- True when g:colors_name is "aether" (direct) OR when it matches the
--- name observed at the end of the most recent aether.load() call (a
--- derivative scheme like hackerman whose colors/<name>.lua delegates to
--- aether.load).
--- @return boolean
local function is_aether_active()
  if vim.g.colors_name == "aether" then
    return true
  end
  return vim.g.colors_name ~= nil
    and state.engine_colors_name ~= nil
    and state.engine_colors_name == vim.g.colors_name
end

--- Record that aether.load() just finished, with whatever colors_name is
--- now in effect. Called from aether.load() via the exported notify hook.
local function notify_engine_loaded()
  state.engine_colors_name = vim.g.colors_name
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

--- Find the first entry in a lazy.nvim plugin spec list whose plugin name
--- (positional [1] or `name=` field) matches a Lua pattern. Returns the
--- entry or nil.
--- @param theme_spec table
--- @param pattern string
--- @return table|nil
local function find_spec_entry(theme_spec, pattern)
  if type(theme_spec) ~= "table" then
    return nil
  end
  for _, entry in ipairs(theme_spec) do
    if type(entry) == "table" then
      local plugin_name = entry[1] or entry.name
      if type(plugin_name) == "string" and plugin_name:match(pattern) then
        return entry
      end
    end
  end
  return nil
end

--- Resolve a parsed lazy.nvim plugin spec to a reload action.
--- Two recognised shapes:
---   1. Direct  - contains an aether.nvim entry with `opts = {...}`. The
---      reload applies those opts via aether.setup + aether.load.
---   2. Indirect - contains a LazyVim entry with `opts.colorscheme = "X"`.
---      The reload re-runs `:colorscheme X`, which fires colors/X.lua and
---      lets that file call aether.load() with whatever palette it bundles
---      (e.g. hackerman.nvim's colors/hackerman.lua).
--- @param theme_spec table
--- @return table|nil action { kind = "opts", opts = table } or { kind = "colorscheme", name = string }
local function resolve_reload_action(theme_spec)
  local aether_entry = find_spec_entry(theme_spec, "aether")
  if aether_entry and type(aether_entry.opts) == "table" then
    return { kind = "opts", opts = aether_entry.opts }
  end

  local lazyvim_entry = find_spec_entry(theme_spec, "LazyVim")
  if lazyvim_entry
    and type(lazyvim_entry.opts) == "table"
    and type(lazyvim_entry.opts.colorscheme) == "string"
  then
    return { kind = "colorscheme", name = lazyvim_entry.opts.colorscheme }
  end

  return nil
end

--- Resolve a reload action from the local lazy.nvim plugins.theme module.
--- @return table|nil action
local function get_reload_action()
  package.loaded["plugins.theme"] = nil

  local ok, theme_spec = pcall(require, "plugins.theme")
  if not ok then
    return nil
  end

  return resolve_reload_action(theme_spec)
end

--- Resolve a reload action by executing an external lazy spec file directly.
--- Used when the aether/omarchy CLI rewrites the spec on disk.
--- @param path string Absolute path to a lazy.nvim plugin spec file
--- @return table|nil action
local function get_reload_action_from_file(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end

  local ok, theme_spec = pcall(dofile, path)
  if not ok then
    return nil
  end

  return resolve_reload_action(theme_spec)
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

--- Reload by delegating to Neovim's colorscheme mechanism. The named
--- colors/<name>.lua is responsible for calling aether.load() with its
--- bundled palette. Used for indirect specs (e.g. LazyVim drives
--- :colorscheme hackerman, hackerman.nvim's colors/hackerman.lua calls
--- aether.load with hackerman's palette).
--- @param name string Colorscheme name to apply
local function reload_via_colorscheme(name)
  local was_active = is_aether_active()

  clear_aether_modules(true)
  clear_highlights()

  local ok, err = pcall(vim.cmd.colorscheme, name)
  if not ok then
    vim.notify(
      ("aether.nvim: failed to apply colorscheme %s (%s)"):format(name, err or "unknown"),
      vim.log.levels.ERROR
    )
    return
  end

  trigger_post_reload_events()

  if was_active then
    vim.notify(("aether.nvim reloaded via %s"):format(name), vim.log.levels.INFO)
  else
    vim.notify(("aether.nvim loaded via %s"):format(name), vim.log.levels.INFO)
  end
end

--- Reload the aether colorscheme with fresh options from config
--- This clears ALL modules including config and reloads with new options
--- This works both when aether is active (reload) and when switching to aether (load)
--- @param source_path string|nil Optional path to read opts from directly; falls back to plugins.theme
local function reload_with_fresh_opts(source_path)
  local action = source_path and get_reload_action_from_file(source_path) or get_reload_action()
  if not action then
    -- Spec isn't recognised (not aether, no LazyVim colorscheme entry).
    return
  end

  if action.kind == "colorscheme" then
    -- Dedup against the running scheme. Re-applying the same scheme when the
    -- spec file is rewritten with identical content would be pointless churn.
    if vim.g.colors_name == action.name then
      return
    end
    state.last_applied_opts_hash = nil -- invalidate aether-opts dedup; different path
    reload_via_colorscheme(action.name)
    return
  end

  local opts = action.opts

  -- Cross-source dedup: skip if the resolved opts match the last applied
  -- ones. Catches both repeat fs_event reloads (CLI rewrites the file
  -- several times with identical content) and the LazyReload event that
  -- lazy.nvim fires for the same write.
  local new_hash = opts_hash(opts)
  if new_hash == state.last_applied_opts_hash then
    return
  end
  state.last_applied_opts_hash = new_hash

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
--- @param augroup integer augroup id created with clear=true
local function setup_lazy_reload_autocmd(augroup)
  vim.api.nvim_create_autocmd("User", {
    group = augroup,
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
--- @param augroup integer augroup id created with clear=true
local function setup_dev_file_watcher(augroup)
  local plugin_path = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = augroup,
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
  local existing = state.fs_event_handles[path]
  if not existing then
    return
  end
  pcall(function()
    if not existing:is_closing() then
      existing:stop()
      existing:close()
    end
  end)
  state.fs_event_handles[path] = nil
end

--- Schedule a reload for `path`, cancelling any in-flight reload for the
--- same path. Collapses bursts of inotify events into a single reload.
--- @param path string
local function schedule_reload(path)
  local existing = state.pending_reload_timers[path]
  if existing then
    pcall(function()
      if not existing:is_closing() then
        existing:stop()
        existing:close()
      end
    end)
  end

  state.pending_reload_timers[path] = vim.defer_fn(function()
    state.pending_reload_timers[path] = nil
    if not is_aether_active() then
      return
    end
    reload_with_fresh_opts(path)
  end, EXTERNAL_RELOAD_DELAY_MS)
end

--- Start a libuv fs_event watcher on a single file path.
--- Re-arms itself on every event because atomic writes (write-temp + rename)
--- swap the inode and would otherwise leave the original watcher stranded.
--- No-op when the file is not readable; the directory watcher set up by
--- start_fs_watch_dir is responsible for re-arming this once the file
--- appears.
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
    state.fs_event_handles[path] = handle
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

--- Start a libuv fs_event watcher on a directory. Fires when any entry in
--- the directory is created, renamed, deleted, or modified. Each tracked
--- file gets its individual file watcher re-armed and a reload scheduled
--- whenever an event names it (or names anything, if filtering is disabled).
---
--- Used for two scenarios:
---   1. Parent dir of a theme spec file - catches creation when the file
---      didn't exist at nvim startup, and the rename half of an atomic
---      write that left the file watcher pointed at a stale inode.
---   2. ~/.config/omarchy/ itself - catches `omarchy theme set <name>`
---      retargeting the `current` symlink so the resolved theme spec
---      changes underneath us. inotify on the resolved path alone would
---      not fire for this.
---
--- @param dir string Absolute directory path to watch
--- @param tracked_files string[] List of absolute file paths to re-arm and reload on dir events
--- @param filter_basenames string[]|nil Optional basenames; if set, only events naming one of these trigger action
local function start_fs_watch_dir(dir, tracked_files, filter_basenames)
  if not uv or not uv.new_fs_event then
    return
  end

  stop_fs_watch(dir)

  if vim.fn.isdirectory(dir) ~= 1 then
    return
  end

  local handle = uv.new_fs_event()
  if not handle then
    return
  end

  local filter_set
  if filter_basenames then
    filter_set = {}
    for _, name in ipairs(filter_basenames) do
      filter_set[name] = true
    end
  end

  local function on_change(_, filename)
    if filter_set and filename and not filter_set[filename] then
      return
    end

    for _, target in ipairs(tracked_files) do
      start_fs_watch(target) -- no-op if file still doesn't exist
      schedule_reload(target)
    end
  end

  local ok, err = handle:start(dir, {}, vim.schedule_wrap(on_change))
  if ok == 0 then
    state.fs_event_handles[dir] = handle
  else
    vim.schedule(function()
      vim.notify(
        ("aether.nvim: failed to watch dir %s (%s)"):format(dir, err or "unknown"),
        vim.log.levels.WARN
      )
    end)
    handle:close()
  end
end

--- Group tracked files by their parent directory so one dir watcher covers
--- all targets sharing a parent (cheap when EXTERNAL_THEME_PATHS contains
--- multiple files under the same dir).
--- @param paths string[]
--- @return table<string, string[]> dir -> list of paths whose parent is dir
local function group_paths_by_parent(paths)
  local grouped = {}
  for _, path in ipairs(paths) do
    local parent = vim.fn.fnamemodify(path, ":h")
    grouped[parent] = grouped[parent] or {}
    table.insert(grouped[parent], path)
  end
  return grouped
end

--- For paths routed through a known symlink (e.g. ~/.config/omarchy/current),
--- return the symlink-anchor directory we must watch separately so symlink
--- retargeting is observed. Currently hardcoded to the omarchy `current`
--- symlink because it is the only known dynamic anchor.
--- @param paths string[]
--- @return string|nil dir, string[] tracked_files, string[] filter_basenames
local function omarchy_symlink_anchor(paths)
  local relevant = {}
  for _, path in ipairs(paths) do
    if path:find("/omarchy/current/", 1, true) then
      table.insert(relevant, path)
    end
  end
  if #relevant == 0 then
    return nil, nil, nil
  end
  return vim.fn.expand("~/.config/omarchy"), relevant, { "current" }
end

--- Setup filesystem watchers for external theme spec files written by CLI
--- tools (aether, omarchy). BufWritePost only fires for in-editor writes, so
--- we use libuv fs_event to catch out-of-process rewrites too. Three layers:
---   1. Per-file watcher for low-latency in-place edits.
---   2. Per-parent-dir watcher to catch file creation (file may not exist
---      at startup) and inode swaps from atomic writes.
---   3. Symlink-anchor watcher (e.g. ~/.config/omarchy/) to catch the
---      `current` symlink being retargeted by `omarchy theme set`.
--- Stops any pre-existing watchers first so re-setup replaces rather than stacks.
local function setup_external_config_watcher()
  for _, path in ipairs(EXTERNAL_THEME_PATHS) do
    start_fs_watch(path) -- no-op if file doesn't yet exist
  end

  for parent, paths_in_parent in pairs(group_paths_by_parent(EXTERNAL_THEME_PATHS)) do
    local basenames = {}
    for _, p in ipairs(paths_in_parent) do
      table.insert(basenames, vim.fn.fnamemodify(p, ":t"))
    end
    start_fs_watch_dir(parent, paths_in_parent, basenames)
  end

  local omarchy_dir, omarchy_paths, omarchy_filter = omarchy_symlink_anchor(EXTERNAL_THEME_PATHS)
  if omarchy_dir then
    start_fs_watch_dir(omarchy_dir, omarchy_paths, omarchy_filter)
  end
end

--- Setup user command for manual reloading.
--- nvim_create_user_command is replace-by-name, so no augroup needed.
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
    table.insert(lines, ("  colors_name        = %s"):format(tostring(vim.g.colors_name)))
    table.insert(lines, ("  engine_colors_name = %s"):format(tostring(state.engine_colors_name)))
    table.insert(lines, ("  is_aether_active   = %s"):format(tostring(is_aether_active())))
    table.insert(lines, ("  uv backend         = %s"):format(uv == vim.uv and "vim.uv" or "vim.loop"))

    local function describe(path, kind)
      local handle = state.fs_event_handles[path]
      local active = handle and not handle:is_closing() or false
      local extra
      if kind == "file" then
        extra = "readable=" .. tostring(vim.fn.filereadable(path) == 1)
      else
        extra = "isdir=" .. tostring(vim.fn.isdirectory(path) == 1)
      end
      table.insert(
        lines,
        ("  [%s] %s  %s  watching=%s"):format(kind, path, extra, tostring(active))
      )
    end

    for _, path in ipairs(EXTERNAL_THEME_PATHS) do
      describe(path, "file")
    end
    for parent in pairs(group_paths_by_parent(EXTERNAL_THEME_PATHS)) do
      describe(parent, "dir")
    end
    local omarchy_dir = omarchy_symlink_anchor(EXTERNAL_THEME_PATHS)
    if omarchy_dir then
      describe(omarchy_dir, "anchor")
    end

    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
  end, { desc = "Show aether hotreload watcher status" })
end

--- Initialize hot reload functionality
--- Sets up autocmds and user commands for automatic theme reloading.
--- Idempotent in two layers:
---   1. did_setup short-circuits on the common case (state survived module load).
---   2. If the module was reloaded externally (lazy.nvim change_detection) and
---      state nevertheless survived via _G, the augroup's clear=true and the
---      stop-then-start in start_fs_watch make re-registration a no-op net
---      change instead of a stacking one.
function M.setup()
  if state.did_setup then
    return
  end
  state.did_setup = true

  local augroup = vim.api.nvim_create_augroup("AetherHotreload", { clear = true })

  setup_lazy_reload_autocmd(augroup)
  setup_dev_file_watcher(augroup)
  setup_external_config_watcher()
  setup_reload_command()
  setup_status_command()
end

M.notify_engine_loaded = notify_engine_loaded

return M
