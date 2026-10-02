-- Run from the repository root:
-- nvim --headless -u NONE -i NONE -n -c "lua dofile('tests/lsp_references.lua')"
local function run()
  vim.opt.rtp:prepend(vim.fn.getcwd())
  local theme = require("aether.theme")
  local references = { "LspReferenceText", "LspReferenceRead", "LspReferenceWrite" }
  local count = 0

  local function check(label, opts, foreground, background, write_bold)
    opts = vim.tbl_deep_extend("force", {
      terminal_colors = false,
      plugins = { all = false, auto = false },
    }, opts)
    local colors = theme.setup(opts)
    for _, group in ipairs(references) do
      -- Compatible with the project's minimum Neovim 0.8 version.
      local actual = vim.api.nvim_get_hl_by_name(group, true)
      assert(actual.foreground == tonumber(foreground:sub(2), 16), label .. ": " .. group .. " foreground")
      assert(actual.background == tonumber(background:sub(2), 16), label .. ": " .. group .. " background")
      local expected_bold = group == "LspReferenceWrite" and write_bold ~= false
      assert((actual.bold or false) == expected_bold, label .. ": " .. group .. " bold")
    end
    count = count + 1
    return colors
  end

  check("defaults", {}, "#dfe6eb", "#4a5366")

  local colors = check("Felix light selection over matching foreground", {
    colors = {
      bg = "#000000", fg = "#e7e9ea", yellow = "#9e9e9e",
      selection = "#e7e9ea",
      selection_foreground = "#000000", selection_background = "#e7e9ea",
    },
  }, "#000000", "#e7e9ea")
  assert(vim.api.nvim_get_hl_by_name("Normal", true).foreground == 0xe7e9ea,
    "unselected text must retain its foreground")
  assert(vim.api.nvim_get_hl_by_name("Type", true).foreground == 0x9e9e9e,
    "unselected syntax must retain its foreground")
  assert(colors.bg_visual == colors.selection and colors.diff.text == colors.selection,
    "shared selection-derived colors must remain unchanged")

  -- The stock Omarchy palettes resolve missing selection_foreground to
  -- bright_foreground and selection_background to selection before injection.
  check("Tokyo Night dark selection", {
    colors = {
      fg = "#a9b1d6", yellow = "#e0af68", selection = "#292e42",
      selection_foreground = "#c0caf5", selection_background = "#292e42",
    },
  }, "#c0caf5", "#292e42")
  check("Flexoki Light selection", {
    colors = {
      bg = "#FFFCF0", fg = "#100F0F", yellow = "#D0A215", selection = "#CECDC3",
      selection_foreground = "#100F0F", selection_background = "#CECDC3",
    },
  }, "#100F0F", "#CECDC3")

  check("independent selection colors with transparency", {
    transparent = true,
    colors = {
      fg = "#445566", selection = "#112233",
      selection_foreground = "#eeeeee", selection_background = "#334455",
    },
  }, "#eeeeee", "#334455")

  check("missing selection overrides retain palette defaults", {
    colors = { fg = "#abcdef", selection = "#123456" },
  }, "#dfe6eb", "#4a5366")

  check("on_colors customization", {
    on_colors = function(c)
      c.selection_foreground = "#ffffff"
      c.selection_background = "#223344"
    end,
  }, "#ffffff", "#223344")

  check("on_highlights customization", {
    on_highlights = function(hl)
      for _, group in ipairs(references) do
        hl[group] = { fg = "#abcdef", bg = "#123456" }
      end
    end,
  }, "#abcdef", "#123456", false)

  check("reload clears previous custom reference colors", {}, "#dfe6eb", "#4a5366")
  print("PASS: " .. count .. " LSP reference cases")
end

local ok, err = pcall(run)
if not ok then
  vim.api.nvim_err_writeln(tostring(err))
  vim.cmd("cquit 1")
else
  vim.cmd("qa!")
end
