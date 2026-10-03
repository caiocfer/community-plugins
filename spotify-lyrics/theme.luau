--!nonstrict
-- Color and idle-state helpers shared by the bar, panel and desktop widget.

local M = {}

-- Settings are declared on the desktop widget entry, and getConfig only sees the
-- scope of the entry calling it. widget.luau therefore republishes what it
-- resolved; the bar and panel read that instead.
local function spec(key, stateKey, fallback)
  local v = noctalia.state.get(stateKey)
  if type(v) ~= "string" or v == "" then v = noctalia.getConfig(key) end
  if type(v) ~= "string" or v == "" then return fallback end
  return v
end

-- Alpha suffix is only parsed on a color role, so hex values get a fourth byte
-- instead: #RRGGBB + 0.5 -> #RRGGBB80.
function M.alpha(color, a)
  local base = color
  if string.sub(base, 1, 1) ~= "#" then
    local slash = string.find(base, "/", 1, true)
    if slash then base = string.sub(base, 1, slash - 1) end
  else
    local hex = string.gsub(base, "^#", "")
    if #hex == 6 then
      return "#" .. hex .. string.format("%02X", math.floor(a * 255 + 0.5))
    end
    return base
  end

  local s = string.gsub(string.format("%.2f", a), "0+$", "")
  return base .. "/" .. string.gsub(s, "%.$", "")
end

function M.colors()
  local accent = spec("accent_color", "lyricsAccent", "primary")
  local active = spec("active_color", "lyricsActive", "on_surface")
  local inactive = spec("inactive_color", "lyricsInactive", "on_surface_variant")
  return {
    accent = accent,
    active = active,
    activeDim = M.alpha(active, 0.45),
    inactive = inactive,
    inactiveFaint = M.alpha(inactive, 0.3),
  }
end

function M.hideWhenIdle()
  local v = noctalia.state.get("lyricsHideIdle")
  if v == nil then v = noctalia.getConfig("hide_when_idle") end
  return v ~= false
end

-- Paused still counts as playing.
function M.isIdle(status)
  return status == nil or status == "" or status == "Stopped"
end

return M