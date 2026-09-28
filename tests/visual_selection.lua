-- Run from the repository root:
-- nvim --headless -u NONE -i NONE -n -c "lua dofile('tests/visual_selection.lua')"
local function run()
  vim.opt.rtp:prepend(vim.fn.getcwd())
  local theme = require("aether.theme")
  local count = 0

  local function check(label, opts, foreground, background)
    opts = vim.tbl_deep_extend("force", {
      terminal_colors = false,
      plugins = { all = false, auto = false },
    }, opts)
    local colors = theme.setup(opts)
    for _, group in ipairs({ "Visual", "VisualNOS" }) do
      -- Compatible with the project's minimum Neovim 0.8 version.
      local actual = vim.api.nvim_get_hl_by_name(group, true)
      local expected_fg = foreground and tonumber(foreground:sub(2), 16) or nil
      assert(actual.foreground == expected_fg, label .. ": " .. group .. " foreground")
      assert(actual.background == tonumber(background:sub(2), 16), label .. ": " .. group .. " background")
    end
    count = count + 1
    return colors
  end

  check("defaults", {}, "#dfe6eb", "#4a5366")

  local colors = check("light selection over matching syntax", {
    colors = {
      bg = "#131516",
      fg = "#F8EBE3",
      blue = "#A5B5AB",
      selection = "#A5B5AB",
      selection_foreground = "#131516",
      selection_background = "#A5B5AB",
    },
  }, "#131516", "#A5B5AB")
  assert(vim.api.nvim_get_hl_by_name("Function", true).foreground == 0xA5B5AB,
    "unselected syntax colors must remain unchanged")
  assert(colors.bg_visual == colors.selection, "shared selection-derived colors must remain unchanged")

  check("independent selection background", {
    transparent = true,
    colors = {
      selection = "#112233",
      selection_foreground = "#eeeeee",
      selection_background = "#334455",
    },
  }, "#eeeeee", "#334455")

  check("on_colors customization", {
    on_colors = function(c)
      c.selection_foreground = "#ffffff"
      c.selection_background = "#223344"
    end,
  }, "#ffffff", "#223344")

  check("on_highlights customization", {
    on_highlights = function(hl)
      hl.Visual = { fg = "#abcdef", bg = "#123456" }
      hl.VisualNOS = { fg = "#abcdef", bg = "#123456" }
    end,
  }, "#abcdef", "#123456")

  check("restore background-only selection", {
    on_highlights = function(hl, c)
      hl.Visual = { bg = c.bg_visual }
      hl.VisualNOS = { bg = c.bg_visual }
    end,
  }, nil, "#2c3040")

  print("PASS: " .. count .. " visual selection cases")
end

local ok, err = pcall(run)
if not ok then
  vim.api.nvim_err_writeln(tostring(err))
  vim.cmd("cquit 1")
else
  vim.cmd("qa!")
end
