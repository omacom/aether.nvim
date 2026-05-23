local M = {}

---Apply the colorscheme
---@param opts? aether.Config
---@return ColorScheme colors
---@return table<string, vim.api.keyset.highlight> groups
---@return aether.Config opts
function M.setup(opts)
  opts = require("aether.config").extend(opts)

  local colors = require("aether.colors").setup(opts)
  local groups = require("aether.groups").setup(colors, opts)

  -- Clear existing highlights if switching from another colorscheme
  if vim.g.colors_name then
    vim.cmd.hi("clear")
  end

  if opts.terminal_colors then
    vim.o.termguicolors = true
  end
  vim.g.colors_name = opts.name

  -- Apply highlight groups
  for group, hl in pairs(groups) do
    hl = type(hl) == "string" and { link = hl } or hl
    vim.api.nvim_set_hl(0, group, hl)
  end

  -- Apply terminal colors
  if opts.terminal_colors then
    M.terminal(colors)
    M.refresh_terminals()
  end

  return colors, groups, opts
end

---Make :terminal buffers reflect the new palette.
---
---Vterm caches its palette in the terminal struct at creation time, so
---`vim.g.terminal_color_*` updates do not flow into already-running
---terminals - SIGWINCH-triggered redraws repaint cells using the OLD
---cached palette. The only reliable fix is to recreate the terminal.
---
---For lazygit specifically (which LazyVim/snacks binds to <leader>gg and
---caches as a hidden buffer for toggle-style reuse), force-delete the
---buffer. The next <leader>gg invocation has nothing to reuse and spawns
---a fresh :terminal lazygit that boots vterm with the new palette from
---cell zero. Safe because lazygit's view is reconstructible from git.
function M.refresh_terminals()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "terminal" then
      local name = vim.api.nvim_buf_get_name(buf)
      if type(name) == "string" and name:find("lazygit", 1, true) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
  end
end

---Set terminal colors
---@param colors ColorScheme
function M.terminal(colors)
  vim.g.terminal_color_0 = colors.terminal.black
  vim.g.terminal_color_8 = colors.terminal.black_bright
  vim.g.terminal_color_7 = colors.terminal.white
  vim.g.terminal_color_15 = colors.terminal.white_bright
  vim.g.terminal_color_1 = colors.terminal.red
  vim.g.terminal_color_9 = colors.terminal.red_bright
  vim.g.terminal_color_2 = colors.terminal.green
  vim.g.terminal_color_10 = colors.terminal.green_bright
  vim.g.terminal_color_3 = colors.terminal.yellow
  vim.g.terminal_color_11 = colors.terminal.yellow_bright
  vim.g.terminal_color_4 = colors.terminal.blue
  vim.g.terminal_color_12 = colors.terminal.blue_bright
  vim.g.terminal_color_5 = colors.terminal.magenta
  vim.g.terminal_color_13 = colors.terminal.magenta_bright
  vim.g.terminal_color_6 = colors.terminal.cyan
  vim.g.terminal_color_14 = colors.terminal.cyan_bright
end

return M
