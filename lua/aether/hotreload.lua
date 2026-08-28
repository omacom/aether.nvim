-- Hot reload configuration for aether.nvim
-- Provides automatic reloading when the plugin or config changes
-- @module aether.hotreload

local M = {}

-- Configuration constants. The aether CLI commonly rewrites neovim.lua
-- several times per theme generation (palette write, blueprint pass,
-- post-process). A 1500 ms trailing-edge window comfortably absorbs that
-- burst while still feeling responsive.
local EXTERNAL_RELOAD_DELAY_MS = 1500
local FS_EVENT_REARM_DELAY_MS = 50

-- External theme spec files written by theme generators (aether CLI, omarchy).
-- Each is a full lazy.nvim plugin spec returning `{ { "...aether.nvim", opts = {...} } }`.
local AETHER_CLI_THEME_PATH = vim.fn.expand("~/.config/aether/theme/neovim.lua")
local OMARCHY_THEME_PATHS = {
  vim.fn.expand("~/.config/omarchy/current/theme/neovim.lua"),
  vim.fn.expand("~/.local/state/omarchy/current/theme/neovim.lua"),
}
local OMARCHY_THEME_PATH_SET = {}
for _, path in ipairs(OMARCHY_THEME_PATHS) do
  OMARCHY_THEME_PATH_SET[path] = true
end

local EXTERNAL_THEME_PATHS = { AETHER_CLI_THEME_PATH }
for _, path in ipairs(OMARCHY_THEME_PATHS) do
  table.insert(EXTERNAL_THEME_PATHS, path)
end

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
  -- when the same opts arrive from multiple trigger paths.
  last_applied_opts_hash = nil,
}
local state = _G.__aether_hotreload_state

--- Omarchy paths delegate to userland on change instead of applying opts.
--- The user's LazyReload handler (e.g.
--- ~/.config/nvim/lua/plugins/omarchy-theme-hotreload.lua) is the right
--- place to drive colorscheme switching, lazy-aware plugin loading, etc.
--- Aether's watcher just fires `User LazyReload` here as a notification.
--- @param path string
--- @return boolean
local function is_omarchy_theme_path(path)
  return OMARCHY_THEME_PATH_SET[path] == true
end

--- Hash an opts table by its inspected representation. Cheap enough to run
--- on every reload candidate and stable across identical tables.
--- @param opts table
--- @return string
local function opts_hash(opts)
  return vim.fn.sha256(vim.inspect(opts))
end

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

--- Trigger post-reload updates.
---
--- 1. Fires `ColorScheme` so plugins with their own ColorScheme autocmds
---    (bufferline, lualine, treesitter rainbow, indent-blankline, ...)
---    re-derive highlights from the new palette. This is the actual lever
---    that makes "everything refresh" - LazyVim itself has no colorscheme
---    handler; plugins react to ColorScheme directly.
---
--- 2. For an external spec-file change, hand the file off to lazy.nvim's
---    reloader (`lazy.manage.reloader.reload(...)`). That runs the same
---    pipeline lazy.nvim's own change_detection runs on a 2s poll, but
---    instantly via our libuv fs_event: re-parses the spec from disk and
---    fires its native `User LazyReload` (no data) at the end. Without
---    this, opts on non-aether entries in the same spec file (lualine
---    theme, bufferline opts, snacks config, ...) are silently dropped
---    because aether's own pipeline only reads `theme_spec[1].opts`.
---
--- 3. Falls back to firing `User LazyReload` ourselves (no data, matching
---    lazy.nvim's emission shape) when lazy.nvim is not present or has no
---    file context to reload (the BufWritePost dev-file path).
---
--- Note: lazy.nvim's reloader does NOT re-invoke each plugin's `config()`
--- function - it only re-parses the spec. That short-circuit lives in
--- `lazy/core/loader.lua` and applies to all change_detection callers,
--- including lazy.nvim itself. Plugin refresh on theme change comes from
--- the ColorScheme event, not from spec re-evaluation.
---
--- @param source_path string|nil Path to the spec file that triggered the
---   reload, if any. When provided, lazy.nvim handles the LazyReload event.
local function trigger_post_reload_events(source_path)
  vim.api.nvim_exec_autocmds("ColorScheme", {
    pattern = vim.g.colors_name or "aether",
    modeline = false,
  })

  local lazy_handled = false
  if source_path then
    local ok_mod, reloader = pcall(require, "lazy.manage.reloader")
    if ok_mod and type(reloader) == "table" and type(reloader.reload) == "function" then
      local ok = pcall(reloader.reload, { { file = source_path, what = "changed" } })
      if ok then
        lazy_handled = true
      end
    end
  end

  if not lazy_handled then
    vim.api.nvim_exec_autocmds("User", {
      pattern = "LazyReload",
      modeline = false,
    })
  end

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

--- Check if a parsed lazy.nvim spec describes aether (first entry's
--- plugin name contains "aether"). Matches the aether CLI's external
--- file shape `{ { "omacom/aether.nvim", opts = {...} } }`.
--- @param theme_spec table
--- @return boolean
local function is_aether_theme(theme_spec)
  if type(theme_spec) ~= "table" or type(theme_spec[1]) ~= "table" then
    return false
  end
  local plugin_name = theme_spec[1][1] or theme_spec[1].name
  return type(plugin_name) == "string" and plugin_name:match("aether") ~= nil
end

--- Read aether opts from an external lazy plugin spec file. Returns nil
--- if the file is missing, fails to evaluate, or its first entry isn't an
--- aether-direct spec with opts. Used for files like the aether CLI's
--- ~/.config/aether/theme/neovim.lua, where the file IS the source of
--- truth for opts.
--- @param path string Absolute path to a lazy plugin spec file
--- @return table|nil opts
local function get_theme_opts_from_file(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local ok, theme_spec = pcall(dofile, path)
  if not ok or not is_aether_theme(theme_spec) then
    return nil
  end
  return theme_spec[1].opts
end

--- Extract the colorscheme name from a parsed lazy plugin spec by scanning
--- for a LazyVim entry with `opts.colorscheme = "X"`. Returns nil when no
--- such entry exists. This is how the omarchy file signals which scheme
--- it wants nvim to be on.
--- @param theme_spec table
--- @return string|nil
local function find_colorscheme_in_spec(theme_spec)
  if type(theme_spec) ~= "table" then
    return nil
  end
  for _, entry in ipairs(theme_spec) do
    if type(entry) == "table" then
      local plugin_name = entry[1] or entry.name
      if type(plugin_name) == "string" and plugin_name:match("LazyVim") then
        if type(entry.opts) == "table" and type(entry.opts.colorscheme) == "string" then
          return entry.opts.colorscheme
        end
      end
    end
  end
  return nil
end

--- Read the desired colorscheme name from an external lazy spec file.
--- Returns nil if the file is missing, fails to evaluate, or has no
--- LazyVim entry naming a colorscheme.
--- @param path string
--- @return string|nil
local function get_colorscheme_from_file(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local ok, theme_spec = pcall(dofile, path)
  if not ok then
    return nil
  end
  return find_colorscheme_in_spec(theme_spec)
end

--- Apply a colorscheme by name, loading its plugin lazy-aware first so
--- it works for `lazy = true` colorscheme plugins (e.g. hackerman.nvim
--- listed in all-themes.lua). Preserves aether.config so the user's
--- saved overrides survive a round-trip through a derivative scheme.
---
--- Caveat: derivative schemes are responsible for using the same color
--- keys as the running aether version. If a derivative passes opts in a
--- foreign convention (e.g. base16 keys against aether v3 which expects
--- named keys), aether's resolver will ignore them and the derivative's
--- intended palette won't apply. That's a plugin-compat issue, not
--- something the hot-reload layer can paper over.
--- @param name string Colorscheme name
--- @param source_path string|nil Path of the spec file that triggered this,
---   forwarded to lazy.nvim's reloader so sibling entries (lualine theme,
---   bufferline opts, ...) get the spec re-parse too.
local function apply_colorscheme(name, source_path)
  if vim.g.colors_name == name then
    -- Same scheme already active. Skipping avoids an unnecessary
    -- highlight-clear flash.
    return
  end

  local was_active = is_aether_active()

  -- Lazy-aware load: if the plugin owning colors/<name>.{lua,vim} is
  -- lazy-loaded, this puts it on rtp so the colorscheme command can find
  -- it. No-op when the plugin is already loaded or lazy isn't installed.
  pcall(function()
    require("lazy.core.loader").colorscheme(name)
  end)

  clear_aether_modules(false) -- preserve M.options across the switch
  clear_highlights()

  local ok, err = pcall(vim.cmd.colorscheme, name)
  if not ok then
    vim.notify(
      ("aether.nvim: failed to apply colorscheme %s (%s)"):format(name, err or "unknown"),
      vim.log.levels.ERROR
    )
    return
  end

  trigger_post_reload_events(source_path)

  if was_active then
    vim.notify(("aether.nvim switched to %s"):format(name), vim.log.levels.INFO)
  else
    vim.notify(("aether.nvim activated %s"):format(name), vim.log.levels.INFO)
  end
end

--- Reload the aether colorscheme using the current saved config.
--- Preserves aether.config so the user's opts survive. Used by the
--- in-tree BufWritePost dev-file watcher.
local function reload_colorscheme()
  clear_aether_modules(false) -- keep aether.config
  vim.schedule(function()
    clear_highlights()
    if not load_theme() then
      return
    end
    trigger_post_reload_events()
    vim.notify("aether.nvim reloaded", vim.log.levels.INFO)
  end)
end

--- Reload the aether colorscheme with fresh opts from an external file
--- (e.g. the aether CLI writes new colors). Clears all modules including
--- config and re-runs aether.setup with the new opts. Skips if the file's
--- opts are byte-identical to the last applied set.
--- @param source_path string Path to a lazy plugin spec file with an aether-direct entry
local function reload_with_fresh_opts(source_path)
  local opts = get_theme_opts_from_file(source_path)
  if not opts then
    return
  end

  local new_hash = opts_hash(opts)
  if new_hash == state.last_applied_opts_hash then
    return
  end

  local was_active = is_aether_active()

  clear_aether_modules(true) -- clear config too: load_theme(opts) re-runs aether.setup
  clear_highlights()

  if not load_theme(opts) then
    -- Do not commit the hash: if load failed, the next identical-bytes
    -- write would dedup against a hash whose effects were never applied,
    -- silently dropping the retry.
    return
  end

  state.last_applied_opts_hash = new_hash
  trigger_post_reload_events(source_path)

  if was_active then
    vim.notify("aether.nvim reloaded with new colors", vim.log.levels.INFO)
  else
    vim.notify("aether.nvim loaded", vim.log.levels.INFO)
  end
end

--- Dispatch an external-path change to the right handler.
---
--- For the omarchy file, prefer the file's aether-direct opts when its
--- first entry is aether (this is the omarchy "aether-themed" case):
--- apply them directly so the omarchy theme's bundled palette becomes
--- active. This matches the pre-refactor behavior the user relies on -
--- omarchy's neovim.lua IS the source of truth for aether colors.
--- Falls back to colorscheme delegation only when no aether-direct
--- entry is present (e.g. hackerman omarchy theme, where the first
--- entry is bjarneo/hackerman.nvim and the LazyVim entry names
--- "hackerman" as the colorscheme).
---
--- The aether CLI's own file (~/.config/aether/theme/neovim.lua) is
--- always aether-direct and applies opts the same way, but gated by
--- is_aether_active so the CLI doesn't force a switch from another
--- colorscheme.
--- @param path string Absolute path that changed
local function on_external_path_changed(path)
  local is_omarchy_path = is_omarchy_theme_path(path)
  local opts = get_theme_opts_from_file(path)
  if opts then
    if not is_omarchy_path and not is_aether_active() then
      return
    end
    reload_with_fresh_opts(path)
    return
  end

  if is_omarchy_path then
    local name = get_colorscheme_from_file(path)
    if name then
      apply_colorscheme(name, path)
    end
  end
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
    -- No is_aether_active() gate: the omarchy path delegates to userland
    -- via User LazyReload, which the user's handler is responsible for
    -- gating. The aether CLI path's apply-opts handler checks file shape
    -- and dedups via opts hash, so a no-op trigger is cheap.
    on_external_path_changed(path)
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

--- For paths routed through a known current anchor (e.g.
--- ~/.config/omarchy/current or ~/.local/state/omarchy/current), return the
--- anchor directories we must watch separately so retargeting is observed.
--- @param paths string[]
--- @return table<string, string[]> anchor_dir -> tracked_files
local function group_omarchy_symlink_anchors(paths)
  local grouped = {}
  local marker = "/omarchy/current/"
  for _, path in ipairs(paths) do
    local marker_start = path:find(marker, 1, true)
    if marker_start then
      local anchor = path:sub(1, marker_start + #"/omarchy" - 1)
      grouped[anchor] = grouped[anchor] or {}
      table.insert(grouped[anchor], path)
    end
  end
  return grouped
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

  for omarchy_dir, omarchy_paths in pairs(group_omarchy_symlink_anchors(EXTERNAL_THEME_PATHS)) do
    start_fs_watch_dir(omarchy_dir, omarchy_paths, { "current" })
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
    table.insert(lines, ("  colors_name      = %s"):format(tostring(vim.g.colors_name)))
    table.insert(lines, ("  is_aether_active = %s"):format(tostring(is_aether_active())))
    table.insert(lines, ("  uv backend       = %s"):format(uv == vim.uv and "vim.uv" or "vim.loop"))
    for _, path in ipairs(OMARCHY_THEME_PATHS) do
      table.insert(
        lines,
        ("  omarchy target   = %s (%s)"):format(tostring(get_colorscheme_from_file(path)), path)
      )
    end

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
    for omarchy_dir in pairs(group_omarchy_symlink_anchors(EXTERNAL_THEME_PATHS)) do
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

  setup_dev_file_watcher(augroup)
  setup_external_config_watcher()
  setup_reload_command()
  setup_status_command()
end

return M
