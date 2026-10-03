--!nonstrict
-- Spotify Player desktop widget.
--
-- Standalone: polls `playerctl` for the Spotify player only, so other MPRIS
-- players never take over. Album art fills the whole card, with a progress bar
-- above the playback controls.
--
-- Sizing: the desktop widget API exposes no box-size call, so the script reads
-- its own instance from `desktop_widgets.widget` (matched by plugin entry id,
-- then by settings) and lays everything out in display pixels. Noctalia fits
-- the script's natural size into the box with one uniform scale and keeps a
-- high-water mark of that natural size that never shrinks. To stay exact, the
-- tree is drawn inside a fixed REF×REF reference and pre-divided by the same
-- scale the host will apply, so the artwork covers the box at any size/aspect.

local POLL_MS = 1000
local PLAYER = "spotify"
local REF = 1000 -- fixed natural reference; must never change at runtime
local DESIGN_W = 391.0 -- reference size the strip metrics were designed at
local DESIGN_H = 518.0

local SEP = string.char(31) -- unit separator: one playerctl call, six fields
local FORMAT = table.concat({
  "{{status}}",
  "{{position}}",
  "{{mpris:length}}",
  "{{title}}",
  "{{artist}}",
  "{{mpris:artUrl}}",
}, SEP)

--------------------------------------------------------------------------------
-- Settings
--------------------------------------------------------------------------------

local function cfgString(key, fallback)
  local v = noctalia.getConfig(key)
  if type(v) == "string" and v ~= "" then return v end
  return fallback
end

local function cfgNumber(key, fallback)
  local v = noctalia.getConfig(key)
  if type(v) == "number" then return v end
  if type(v) == "string" then
    local n = tonumber(v)
    if n then return n end
  end
  return fallback
end

local function cfgBool(key, fallback)
  local v = noctalia.getConfig(key)
  if type(v) == "boolean" then return v end
  return fallback
end

local function widgetWidth()
  return math.max(120, math.floor(cfgNumber("widget_width", 337)))
end

local function widgetHeight()
  return math.max(160, math.floor(cfgNumber("widget_height", 518)))
end

local function hideWhenIdle()
  return cfgBool("hide_when_idle", true)
end

--------------------------------------------------------------------------------
-- Layout space (box size + host fit compensation)
--------------------------------------------------------------------------------

local SCORE_KEYS = {
  "widget_width",
  "widget_height",
  "corner_radius",
  "show_track_info",
  "accent_color",
  "hide_when_idle",
}

-- The widget instance records the box the user dragged. There is no direct box
-- API, so pick the instance of this plugin whose settings match the settings
-- this script was loaded with. Returns width, height, settings or nil.
local function instanceBox()
  local dir = noctalia.pluginDataDir()
  if type(dir) ~= "string" then return nil end
  local author, plugin = dir:match("([^/]+)/([^/]+)$")
  if author == nil then return nil end

  local mine = {}
  for _, key in ipairs(SCORE_KEYS) do
    local v = noctalia.getConfig(key)
    if v ~= nil then mine[key] = tostring(v) end
  end

  local all = noctalia.getSetting("desktop_widgets.widget")
  if type(all) ~= "table" then return nil end

  local prefix = author .. "/" .. plugin .. ":"
  local best, bestScore = nil, -1
  for _, inst in pairs(all) do
    if type(inst) == "table" and type(inst.type) == "string" and inst.type:sub(1, #prefix) == prefix then
      local score = 0
      if type(inst.settings) == "table" then
        for key, value in pairs(mine) do
          local other = inst.settings[key]
          if other ~= nil and tostring(other) == value then score = score + 1 end
        end
      end
      if score > bestScore then
        best, bestScore = inst, score
      end
    end
  end

  if best == nil then return nil end
  local bw = tonumber(best.box_width)
  local bh = tonumber(best.box_height)
  if bw == nil or bh == nil or bw <= 0 or bh <= 0 then return nil end
  return bw, bh, best.settings
end

-- The host insets boxed content by its own background padding (only when the
-- background is enabled). Mirror that so the fit math matches the host exactly.
local function hostPadding(settings)
  if type(settings) ~= "table" or settings.background ~= true then return 0 end
  local padding = tonumber(settings.background_padding) or 10
  local uiScale = tonumber(noctalia.getSetting("accessibility.ui_scale")) or 1
  return math.floor(padding * uiScale + 0.5)
end

-- `w`/`h` are the display-pixel extents the content must cover; `s` is the
-- uniform scale Noctalia will apply to the script's tree (so the script emits
-- `value / s` and the host turns it back into `value`).
local function layoutSpace()
  local bw, bh, settings = instanceBox()
  if bw ~= nil then
    local pad = hostPadding(settings)
    local iw = math.max(1, bw - 2 * pad)
    local ih = math.max(1, bh - 2 * pad)
    local s = math.min(iw / REF, ih / REF)
    if s > 0 then
      return { box = true, w = iw, h = ih, s = s }
    end
  end
  -- Auto-fit box (drag not used yet): the host sizes to the natural content, so
  -- fall back to the configured draw size and don't pre-scale.
  return { box = false, w = widgetWidth(), h = widgetHeight(), s = 1 }
end

-- Uniform "responsive" factor for strip typography and controls. Derived from
-- the smaller axis so a wide-but-short box stays compact.
local function sizeFactor(w, h)
  local u = math.min(w / DESIGN_W, h / DESIGN_H)
  if u < 0.55 then return 0.55 end
  if u > 3.0 then return 3.0 end
  return u
end

--------------------------------------------------------------------------------
-- Player state
--------------------------------------------------------------------------------

local player = nil -- { status, positionMs, durationMs, title, artist, artPath }
local pollInFlight = false
local artPaths = {}
local artPending = {}

local function trim(value)
  if type(value) ~= "string" then return "" end
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- playerctl reports microseconds for both position and length.
local function microsToMs(raw)
  local n = tonumber(raw)
  if not n or n ~= n then return 0 end
  return math.max(0, math.floor(n / 1000))
end

local function artPathFor(url)
  if url == "" then return nil end
  if url:sub(1, 7) == "file://" then return url:sub(8) end
  if url:sub(1, 7) == "http://" or url:sub(1, 8) == "https://" then
    if artPaths[url] then return artPaths[url] end
    if artPending[url] then return nil end

    local base = url:match("([^/?#]+)$") or "cover"
    base = base:gsub("[^%w%._-]", "_")
    if #base > 80 then base = base:sub(-80) end

    local dir = noctalia.pluginDataDir() .. "/art"
    noctalia.mkdirAll(dir)
    local dest = dir .. "/" .. base

    artPending[url] = true
    local started = noctalia.download(url, dest, function(ok)
      artPending[url] = nil
      if ok and noctalia.fileExists(dest) then
        artPaths[url] = dest
        render()
      end
    end)
    if not started then artPending[url] = nil end
    return nil
  end
  return nil
end

--------------------------------------------------------------------------------
-- Cover accent (Android Auto style)
--------------------------------------------------------------------------------

-- Text, icons and the progress bar all derive from the dominant cover hue,
-- like Android Auto's Material You media widget. The legibility scrim is a
-- static gradient asset, so the backdrop is there on the first frame while the
-- palette is sampled in the background.
local MAGICK_BINS = { "magick", "convert" }
local magickBin = 1
local paletteCache = {}
local palettePending = {}
local paletteDisabled = false -- both ImageMagick binaries missing

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function srgbToLinear(c)
  if c <= 0.04045 then return c / 12.92 end
  return ((c + 0.055) / 1.055) ^ 2.4
end

local function relLuma(r, g, b)
  return 0.2126 * srgbToLinear(r) + 0.7152 * srgbToLinear(g) + 0.0722 * srgbToLinear(b)
end

local function contrastRatio(l1, l2)
  local hi, lo = math.max(l1, l2), math.min(l1, l2)
  return (hi + 0.05) / (lo + 0.05)
end

local function rgbToHsl(r, g, b)
  local mx = math.max(r, g, b)
  local mn = math.min(r, g, b)
  local l = (mx + mn) / 2
  if mx == mn then return 0, 0, l end
  local d = mx - mn
  local s = l > 0.5 and d / (2 - mx - mn) or d / (mx + mn)
  local h
  if mx == r then
    h = (g - b) / d + (g < b and 6 or 0)
  elseif mx == g then
    h = (b - r) / d + 2
  else
    h = (r - g) / d + 4
  end
  return (h * 60) % 360, s, l
end

local function hslToRgb(h, s, l)
  h = (h % 360) / 360
  if s <= 0 then return l, l, l end
  local function hue(p, q, t)
    if t < 0 then t = t + 1 elseif t > 1 then t = t - 1 end
    if t < 1 / 6 then return p + (q - p) * 6 * t end
    if t < 1 / 2 then return q end
    if t < 2 / 3 then return p + (q - p) * (2 / 3 - t) * 6 end
    return p
  end
  local q = l < 0.5 and l * (1 + s) or l + s - l * s
  local p = 2 * l - q
  return hue(p, q, h + 1 / 3), hue(p, q, h), hue(p, q, h - 1 / 3)
end

local function hexOf(r, g, b, a)
  local function byte(v)
    return math.floor(clamp(v, 0, 1) * 255 + 0.5)
  end
  if a then
    return string.format("#%02X%02X%02X%02X", byte(r), byte(g), byte(b), byte(a))
  end
  return string.format("#%02X%02X%02X", byte(r), byte(g), byte(b))
end

-- Pick the most cover-defining bucket, the way Android's palette does: wide
-- enough to matter, saturated enough to feel like the artwork, and not crushed
-- into near-black/near-white. Extremes are only used as a last resort.
local function pickDominant(histogram)
  local best, bestScore = nil, -1
  local fallback, fallbackScore = nil, -1
  for line in histogram:gmatch("[^\n]+") do
    local count, r, g, b = line:match("(%d+):%s*%(%s*([%d%.]+),%s*([%d%.]+),%s*([%d%.]+)%)")
    if count then
      local n = tonumber(count) or 0
      local rr, gg, bb = tonumber(r) / 255, tonumber(g) / 255, tonumber(b) / 255
      if rr and gg and bb then
        local _, s, l = rgbToHsl(rr, gg, bb)
        local mid = 1 - math.abs(l - 0.55) * 1.9
        local score = math.sqrt(n) * (0.25 + s) * math.max(0.04, mid)
        if score > fallbackScore then
          fallback, fallbackScore = { rr, gg, bb }, score
        end
        if l >= 0.09 and l <= 0.94 and score > bestScore then
          best, bestScore = { rr, gg, bb }, score
        end
      end
    end
  end
  return best or fallback
end

-- HSL saturation is not chroma: at a fixed lightness a high S can still look
-- washed out. Convert a target chroma into the S that actually produces it so
-- "30% chroma" means the same thing for pale and deep tints.
local function chromaS(chroma, l)
  local denom = 1 - math.abs(2 * l - 1)
  if denom <= 0.0001 then return 0 end
  return clamp(chroma / denom, 0, 1)
end

-- Walk lightness away from the scrim until the color clears `target` contrast,
-- rebuilding S each step so the tint keeps its chroma instead of fading out.
local function fitContrast(h, chroma, l, backdrop, target, step)
  local c = clamp(chroma, 0, 1)
  local L = l
  local r, g, b = hslToRgb(h, chromaS(c, L), L)
  for _ = 1, 40 do
    if contrastRatio(relLuma(r, g, b), backdrop) >= target then break end
    local nextL = clamp(L + step, 0, 1)
    if nextL == L then break end
    L = nextL
    r, g, b = hslToRgb(h, chromaS(c, L), L)
  end
  return hexOf(r, g, b)
end

-- Material You dynamic color: the title, artist and icons are all tints of the
-- dominant cover hue, not fixed theme roles. On the dark scrim they are a light
-- pastel (high lightness, visible chroma); on the light scrim they are a deep
-- tone. The progress accent keeps the same hue at full vividness. Everything is
-- contrast-fitted: 4.5:1 for the title, 3:1 for muted text/icons.
local function buildPalette(r, g, b, lightScrim)
  local h, s = rgbToHsl(r, g, b)
  -- Worst-case scrimmed pixel behind each element, from the static gradient:
  -- text sits high in the band where the scrim is ~0.72 opaque, the progress
  -- bar sits near the bottom where it is ~0.86. That keeps a pure-white (dark
  -- theme) or pure-black (light theme) cover from washing the tint out.
  local accentBackdrop = lightScrim and 0.50 or 0.05
  local textBackdrop = lightScrim and 0.48 or 0.07
  local mutedBackdrop = lightScrim and 0.48 or 0.07
  -- Neutral sleeves stay neutral; only a real hue gets pushed.
  local colorful = s >= 0.10

  local accentC = colorful and clamp(s * 0.62, 0.20, 0.42) or 0.06
  local textC = colorful and clamp(s * 0.46, 0.14, 0.28) or 0.03
  local mutedC = colorful and clamp(s * 0.38, 0.10, 0.22) or 0.02

  local accent = fitContrast(h, accentC, lightScrim and 0.42 or 0.72, accentBackdrop, 3.0, lightScrim and -0.01 or 0.01)
  local text = fitContrast(h, textC, lightScrim and 0.30 or 0.86, textBackdrop, 4.5, lightScrim and -0.01 or 0.01)
  local muted = fitContrast(h, mutedC, lightScrim and 0.42 or 0.76, mutedBackdrop, 3.0, lightScrim and -0.01 or 0.01)

  -- Track and hover are the tint at low alpha, so the bars and haloes also
  -- follow the artwork instead of falling back to grey.
  local track = text .. "59" -- ~35% alpha
  local hover = text .. "29" -- ~16% alpha
  return {
    accent = accent,
    text = text,
    muted = muted,
    track = track,
    hover = hover,
  }
end

local function runMagick(args, callback)
  local bin = MAGICK_BINS[magickBin]
  if bin == nil then
    paletteDisabled = true
    callback(nil)
    return
  end
  local argv = { bin }
  for _, arg in ipairs(args) do argv[#argv + 1] = arg end
  local started = noctalia.runAsync(argv, function(result)
    if not result or result.exitCode ~= 0 or type(result.stdout) ~= "string" or result.stdout == "" then
      magickBin = magickBin + 1
      runMagick(args, callback)
      return
    end
    callback(result.stdout)
  end, 4000)
  if not started then
    paletteDisabled = true
    callback(nil)
  end
end

local function extractPalette(path, lightScrim, done)
  local histogram = { path, "-resize", "48x48", "-colors", "8", "-depth", "8", "-format", "%c", "histogram:info:-" }
  runMagick(histogram, function(colors)
    if colors == nil then
      done(nil)
      return
    end
    local dominant = pickDominant(colors)
    if dominant == nil then
      done(nil)
      return
    end
    done(buildPalette(dominant[1], dominant[2], dominant[3], lightScrim))
  end)
end

-- Returns the accent for this art path, or nil while it is being sampled.
local function paletteForArt(path, lightScrim)
  if type(path) ~= "string" or path == "" or paletteDisabled then return nil end
  local key = path .. (lightScrim and "|light" or "|dark")
  local cached = paletteCache[key]
  if cached ~= nil then return cached or nil end
  if palettePending[key] then return nil end
  palettePending[key] = true
  extractPalette(path, lightScrim, function(result)
    palettePending[key] = nil
    paletteCache[key] = result or false
    if result and player and player.artPath == path then render() end
  end)
  return nil
end

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

-- No desktopWidget.setVisible(): an invisible root stops the surface from
-- presenting frames and wedges Noctalia's frame loop. Paint a fully transparent
-- frame instead so the surface keeps committing while idle.
local function renderHidden(space)
  desktopWidget.render(ui.column({
    width = space.box and REF or space.w,
    height = space.box and REF or space.h,
    fill = "#00000000",
  }))
end

-- In box mode the visible tree is a canvas of exactly the box size (already
-- divided by `s`), wrapped in the fixed REF reference so the host's natural
-- size stays constant. The canvas overflows REF on one axis; a row lets the
-- cross (vertical) axis center that overflow with a negative offset, a column
-- does the same for the horizontal axis.
local function present(canvas, space)
  if not space.box then
    desktopWidget.render(canvas)
    return
  end
  if space.h / space.s > REF + 0.01 then
    desktopWidget.render(ui.row({
      width = REF,
      height = REF,
      align = "center",
      justify = "center",
    }, { canvas }))
  else
    desktopWidget.render(ui.column({
      width = REF,
      height = REF,
      align = "center",
      justify = "center",
    }, { canvas }))
  end
end

local function formatTime(ms)
  local total = math.max(0, math.floor(ms / 1000))
  return string.format("%d:%02d", math.floor(total / 60), total % 60)
end

local hoveredControl = nil

-- The scrim and the theme text are paired: dark scrim for light text, light
-- scrim for dark text. Reading the shell mode keeps Material You legible in
-- both themes without having to sample any theme color.
local function themeIsLight()
  local mode = noctalia.getSetting("theme.shell_mode") or noctalia.getSetting("theme.mode")
  return mode == "light"
end

local function scrimPath(lightScrim)
  return noctalia.pluginDir() .. (lightScrim and "/assets/scrim-light.png" or "/assets/scrim-dark.png")
end

-- A glyph inside a hit-testable column: the stock button does not take a color,
-- and the icons follow the theme text color.
local function controlButton(glyph, size, glyphSize, action, color, hoverFill)
  return ui.column({
    key = action,
    width = size,
    height = size,
    radius = size * 0.5,
    fill = (hoveredControl == action) and hoverFill or "#00000000",
    align = "center",
    justify = "center",
    onClick = function()
      noctalia.runAsync({ "playerctl", "-p", PLAYER, action }, function()
        poll()
      end, 3000)
    end,
    onHover = function(value)
      local over = value == true or value == "true"
      if over then
        hoveredControl = action
      elseif hoveredControl == action then
        hoveredControl = nil
      end
      render()
    end,
  }, {
    ui.glyph({ name = glyph, size = glyphSize, color = color }),
  })
end

local function renderPlayer()
  local space = layoutSpace()
  local w, h = space.w, space.h
  local function px(v) return v / space.s end

  local u = sizeFactor(w, h)
  -- Type and controls stop shrinking before they get illegible: spacing keeps
  -- following the box, but a small widget still renders readable text.
  local tf = math.max(u, 1.0)
  local radius = math.max(0, cfgNumber("corner_radius", 16)) * u
  radius = math.min(radius, math.min(w, h) * 0.5)
  local showInfo = cfgBool("show_track_info", true)
  local coverColors = cfgBool("cover_colors", true)
  local lightScrim = themeIsLight()
  local pal = coverColors and paletteForArt(player.artPath, lightScrim) or nil
  local accent = pal and pal.accent or cfgString("accent_color", "primary")
  -- Cover-tinted Material You text. Until the palette lands, fall back to the
  -- theme roles so the first frames are still readable.
  local textColor = pal and pal.text or "on_surface"
  local mutedColor = pal and pal.muted or "on_surface_variant"
  local trackColor = pal and pal.track or "on_surface/0.35"
  local hoverFill = pal and pal.hover or "on_surface/0.12"

  local title = trim(player.title)
  local artist = trim(player.artist)

  local inset = 8 * u
  local padding = 12 * u
  local gap = 8 * u
  local titleSize = 16 * tf
  local artistSize = 12 * tf
  local lineGap = 1 * u
  -- Two stacked text lines: title, then artist.
  local infoHeight = 0
  if showInfo then
    infoHeight = 21 * tf
    if artist ~= "" then infoHeight = infoHeight + 16 * tf + lineGap end
  end
  local progressRow = 14 * tf
  local smallControl = 34 * tf
  local largeControl = 40 * tf
  local smallGlyph = 20 * tf
  local largeGlyph = 26 * tf
  local controlsGap = 22 * u
  local progressHeight = 4 * tf
  local progressRadius = 2 * tf
  local timeWidth = 30 * tf

  local stripHeight = padding * 2 + progressRow + gap + largeControl
                    + (showInfo and (infoHeight + gap) or 0)
  local stripWidth = w - inset * 2
  local innerWidth = stripWidth - padding * 2

  local durationMs = player.durationMs or 0
  local positionMs = player.positionMs or 0
  if durationMs > 0 and positionMs > durationMs then positionMs = durationMs end
  local fraction = 0
  if durationMs > 0 then fraction = math.min(1, math.max(0, positionMs / durationMs)) end

  local strip = {}

  if showInfo then
    local info = {}
    if title ~= "" then
      table.insert(info, ui.label({
        text = title,
        fontSize = px(titleSize),
        fontWeight = "semibold",
        color = textColor,
        maxLines = 1,
      }))
    end
    if artist ~= "" then
      table.insert(info, ui.label({
        text = artist,
        fontSize = px(artistSize),
        color = mutedColor,
        maxLines = 1,
      }))
    end
    table.insert(strip, ui.column({
      key = "info",
      width = px(innerWidth),
      gap = px(lineGap),
      align = "stretch",
    }, info))
  end

  -- The strip sits in the card's outer padding; its own inner width is what
  -- the progress row and control row center themselves in.
  local barWidth = math.max(24 * u, innerWidth - 2 * timeWidth - 2 * gap)
  table.insert(strip, ui.row({
    key = "progress",
    width = px(innerWidth),
    gap = px(gap),
    justify = "center",
    align = "center",
  }, {
    ui.label({
      text = formatTime(positionMs),
      fontSize = px(11 * tf),
      color = mutedColor,
    }),
    ui.progress({
      width = px(barWidth),
      height = px(progressHeight),
      radius = px(progressRadius),
      progress = fraction,
      fill = accent,
      track = trackColor,
    }),
    ui.label({
      text = durationMs > 0 and formatTime(durationMs) or "--:--",
      fontSize = px(11 * tf),
      color = mutedColor,
    }),
  }))

  local playing = player.status == "Playing"
  table.insert(strip, ui.row({
    key = "controls",
    width = px(innerWidth),
    gap = px(controlsGap),
    justify = "center",
    align = "center",
  }, {
    controlButton("player-skip-back", px(smallControl), px(smallGlyph), "previous", textColor, hoverFill),
    controlButton(
      playing and "player-pause" or "player-play",
      px(largeControl),
      px(largeGlyph),
      "play-pause",
      textColor,
      hoverFill
    ),
    controlButton("player-skip-forward", px(smallControl), px(smallGlyph), "next", textColor, hoverFill),
  }))

  -- Both art variants share the same key: the reconciler matches children by
  -- (type, key) and retains props, so the placeholder's opaque fill must never
  -- be recycled into the overlay column below.
  local art
  local artPath = player.artPath
  local hasArt = artPath ~= nil and noctalia.fileExists(artPath)
  if hasArt then
    art = ui.image({
      key = "art",
      width = px(w),
      height = px(h),
      radius = px(radius),
      fit = "cover",
      path = artPath,
    })
  else
    art = ui.column({
      key = "art",
      width = px(w),
      height = px(h),
      radius = px(radius),
      fill = "surface_variant",
      align = "center",
      justify = "center",
    }, {
      ui.glyph({ name = "music", size = px(48 * u), color = "on_surface_variant" }),
    })
  end

  local overlay = ui.column({
    key = "overlay",
    width = px(w),
    height = px(h),
    padding = px(inset),
    justify = "end",
    align = "stretch",
  }, {
    ui.column({
      width = px(stripWidth),
      height = px(stripHeight),
      fill = "#00000000", -- transparent: props are retained, so it must be set
      padding = px(padding),
      gap = px(gap),
      justify = "center",
      align = "stretch",
    }, strip),
  })

  -- Full-bleed cover: the art fills the whole widget box, the scrim darkens
  -- just the lower band (a static asset, so it is there on the first frame),
  -- and the controls float on top. The negative gap pulls each sibling back to
  -- the canvas top so they overlap instead of stacking.
  local children = { art }
  if hasArt then
    table.insert(children, ui.image({
      key = "scrim",
      width = px(w),
      height = px(h),
      radius = px(radius),
      fit = "stretch",
      path = scrimPath(lightScrim),
    }))
  end
  table.insert(children, overlay)
  present(ui.column({
    width = px(w),
    height = px(h),
    gap = -px(h),
  }, children), space)
end

local function renderEmpty()
  local space = layoutSpace()
  local w, h = space.w, space.h
  local function px(v) return v / space.s end
  local u = sizeFactor(w, h)
  local tf = math.max(u, 1.0)
  local radius = math.max(0, cfgNumber("corner_radius", 16)) * u
  radius = math.min(radius, math.min(w, h) * 0.5)

  present(ui.column({
    width = px(w),
    height = px(h),
    radius = px(radius),
    fill = "surface/0.92",
    align = "center",
    justify = "center",
    gap = px(8 * u),
  }, {
    ui.glyph({ name = "music", size = px(34 * tf), color = "on_surface_variant" }),
    ui.label({
      text = "No music playing",
      fontSize = px(13 * tf),
      color = "on_surface_variant",
    }),
  }), space)
end

-- "Nothing playing" = no Spotify player, or a player sitting in Stopped. Paused
-- still counts as active, so the widget only disappears when playback is over.
local function isActive()
  if not player or trim(player.title) == "" then return false end
  return player.status == "Playing" or player.status == "Paused"
end

function render()
  if not isActive() then
    if hideWhenIdle() then
      renderHidden(layoutSpace())
    else
      renderEmpty()
    end
    return
  end
  renderPlayer()
end

--------------------------------------------------------------------------------
-- Polling
--------------------------------------------------------------------------------

local function applyOutput(out)
  local f = {}
  local start = 1
  while true do
    local sep = string.find(out, SEP, start, true)
    if not sep then
      table.insert(f, out:sub(start))
      break
    end
    table.insert(f, out:sub(start, sep - 1))
    start = sep + 1
  end

  if #f < 4 or trim(f[1]) == "" then
    player = nil
    return
  end

  local artUrl = trim(f[6] or "")
  player = {
    status = trim(f[1]),
    positionMs = microsToMs(f[2]),
    durationMs = microsToMs(f[3]),
    title = trim(f[4]),
    artist = trim(f[5]),
    artPath = artPathFor(artUrl),
  }
end

function poll()
  if pollInFlight then return end
  pollInFlight = true
  noctalia.runAsync(
    { "playerctl", "-p", PLAYER, "metadata", "--format", FORMAT },
    function(result)
      pollInFlight = false
      if result and result.exitCode == 0 and type(result.stdout) == "string" then
        applyOutput(result.stdout)
      else
        player = nil
      end
      render()
    end,
    3000
  )
end

function update()
  noctalia.setUpdateInterval(POLL_MS)
  poll()
end

poll()
