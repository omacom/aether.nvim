---@class aether.Util
local M = {}

---@type string Default background for blending
M.bg = "#1a1d24"
---@type string Default foreground for blending
M.fg = "#a2aebb"

---Parse hex color to RGB components
---@param hex string Hex color string (e.g., "#ff0000")
---@return number[] RGB values as {r, g, b}
local function hex_to_rgb(hex)
  hex = hex:lower()
  return {
    tonumber(hex:sub(2, 3), 16),
    tonumber(hex:sub(4, 5), 16),
    tonumber(hex:sub(6, 7), 16),
  }
end

---Blend two colors together
---@param foreground string Foreground hex color
---@param alpha number|string Blend factor (0-1, or hex string)
---@param background string Background hex color
---@return string Blended hex color
function M.blend(foreground, alpha, background)
  alpha = type(alpha) == "string" and (tonumber(alpha, 16) / 0xff) or alpha
  local bg = hex_to_rgb(background)
  local fg = hex_to_rgb(foreground)

  local function blend_channel(i)
    local ret = (alpha * fg[i] + ((1 - alpha) * bg[i]))
    return math.floor(math.min(math.max(0, ret), 255) + 0.5)
  end

  return string.format("#%02x%02x%02x", blend_channel(1), blend_channel(2), blend_channel(3))
end

---Blend color towards background (darken)
---@param hex string Hex color to blend
---@param amount number Blend amount (0-1)
---@param bg? string Optional background color
---@return string Blended hex color
function M.blend_bg(hex, amount, bg)
  return M.blend(hex, amount, bg or M.bg)
end

---Blend color towards foreground (lighten)
---@param hex string Hex color to blend
---@param amount number Blend amount (0-1)
---@param fg? string Optional foreground color
---@return string Blended hex color
function M.blend_fg(hex, amount, fg)
  return M.blend(hex, amount, fg or M.fg)
end

---Resolve style tables in highlight definitions. Builds a fresh groups
---table so the per-plugin tables exported from `groups/*.lua` are never
---mutated - those are owned by `package.loaded[...]` and reused across
---reload cycles. Mutating them would strip `style` (italic/bold etc.)
---on every subsequent setup call.
---@param groups table<string, aether.Highlight> Highlight groups
---@return table<string, vim.api.keyset.highlight>
function M.resolve(groups)
  local resolved = {}
  for name, hl in pairs(groups) do
    if type(hl) == "table" and type(hl.style) == "table" then
      local merged = {}
      for k, v in pairs(hl) do
        if k ~= "style" then
          merged[k] = v
        end
      end
      for k, v in pairs(hl.style) do
        merged[k] = v
      end
      resolved[name] = merged
    else
      resolved[name] = hl
    end
  end
  return resolved
end

return M