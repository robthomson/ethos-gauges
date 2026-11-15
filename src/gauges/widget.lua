-- Gauge widget: one source drawn as an arc, half arc, ring, bar or needle dial
-- between a configurable min and max.
--
-- Settings live in the widget instance and are saved per slot through
-- read/write (storage.read / storage.write), so two slots on the same screen
-- can show different gauges.
--
-- Hot paths (wakeup, paint) allocate nothing: text and layout are rebuilt only
-- when the value (at display precision), the settings or the window size change.
local util = ...

local floor, sin, cos, rad = math.floor, math.sin, math.cos, math.rad

local SETTINGS_VERSION = 1

-- Gauge types (stored in the model: never renumber, only append)
local TYPE_ARC    = 1   -- 270 degree arc
local TYPE_HALF   = 2   -- 180 degree arc
local TYPE_RING   = 3   -- full circle
local TYPE_HBAR   = 4   -- horizontal bar
local TYPE_VBAR   = 5   -- vertical bar
local TYPE_NEEDLE = 6   -- 270 degree dial with a needle

local TYPE_CHOICES = {
  { "@i18n(widget.type_arc)@", TYPE_ARC },
  { "@i18n(widget.type_half)@", TYPE_HALF },
  { "@i18n(widget.type_ring)@", TYPE_RING },
  { "@i18n(widget.type_hbar)@", TYPE_HBAR },
  { "@i18n(widget.type_vbar)@", TYPE_VBAR },
  { "@i18n(widget.type_needle)@", TYPE_NEEDLE },
}

-- Arc geometry: angles in degrees, 0 at the top, clockwise (lcd.drawAnnulusSector)
local ARC_START = { [TYPE_ARC] = 225, [TYPE_HALF] = 270, [TYPE_RING] = 0, [TYPE_NEEDLE] = 225 }
local ARC_SWEEP = { [TYPE_ARC] = 270, [TYPE_HALF] = 180, [TYPE_RING] = 360, [TYPE_NEEDLE] = 270 }

-- min/max number fields have one decimal: stored values are tenths
local RANGE_LIMIT = 1000000          -- +/- 100000.0
local DEFAULT_MIN, DEFAULT_MAX = 0, 1000
local DEFAULT_COLOR = lcd.RGB(0, 190, 90)

local hasTriangle = lcd.drawFilledTriangle ~= nil

-- Draw an arc of `sweep` degrees from angle `a`. drawAnnulusSector takes at
-- most 180 degrees per call (it wraps through 0 by itself), so longer arcs
-- are drawn in pieces that overlap by a degree to leave no seam.
local function drawArc(cx, cy, ri, ro, a, sweep)
  a = a % 360
  local full = sweep >= 359.9          -- a closed ring also overlaps where it ends
  while sweep > 0.05 do
    local seg = sweep
    if seg > 180 then seg = 180 end
    local stop = a + seg
    if seg < sweep or full then stop = stop + 1 end
    if stop > 360 then stop = stop - 360 end   -- keep 360 itself: 0 leaves a notch
    lcd.drawAnnulusSector(cx, cy, ri, ro, a, stop)
    sweep = sweep - seg
    a = (a + seg) % 360
  end
end

local function formatLimit(tenths)
  if tenths % 10 == 0 then
    return string.format("%d", tenths // 10)
  end
  return string.format("%.1f", tenths / 10)
end

-- Settings changed: rebuild the strings derived from them and force a redraw.
local function refresh(w)
  w.minText = formatLimit(w.min)
  w.maxText = formatLimit(w.max)
  w.title = w.source and w.source:name() or ""
  w.shown = false     -- re-read the value on the next wakeup
  w.layoutW = nil     -- re-run the layout on the next paint
end

local function create()
  local w = {
    gtype = TYPE_ARC, source = nil, min = DEFAULT_MIN, max = DEFAULT_MAX,
    color = DEFAULT_COLOR, showTitle = true, showLimits = true,
    value = nil, shown = false, text = "--", frac = 0,
  }
  refresh(w)
  return w
end

local function wakeup(w)
  if not w then return end           -- instance lost after a script reload
  local src = w.source
  if not src then
    if w.shown ~= nil then w.shown = nil; lcd.invalidate() end
    return
  end
  local v = src:value()
  -- compare at display precision so sensor noise doesn't trigger redraws
  local shown = v and floor(v * 10 ^ (src:decimals() or 0) + 0.5)
  if shown ~= w.shown then
    w.shown = shown
    w.value = v
    w.text = v and src:stringValue() or "--"
    local lo, hi = w.min / 10, w.max / 10
    local f = 0
    if v and hi ~= lo then
      f = (v - lo) / (hi - lo)
      if f < 0 then f = 0 elseif f > 1 then f = 1 end
    end
    w.frac = f
    lcd.invalidate()
  end
end

-- Window size, gauge type or title setting changed: compute the geometry.
local function layout(w, W, H)
  w.layoutW, w.layoutH = W, H
  local pad = floor(math.min(W, H) * 0.04) + 2

  -- title strip
  local top = pad
  w.titleFont = H < 90 and FONT_XS or FONT_S
  if w.showTitle and w.source then
    lcd.font(w.titleFont)
    local _, th = lcd.getTextSize("Ag")
    w.titleY = top
    top = top + th + 2
  end
  lcd.font(FONT_XS)
  local _, limH = lcd.getTextSize("0")
  w.limH = limH

  local gx, gy, gw, gh = pad, top, W - 2 * pad, H - top - pad
  if gw < 4 then gw = 4 end
  if gh < 4 then gh = 4 end
  w.gx, w.gy, w.gw, w.gh = gx, gy, gw, gh

  local t = w.gtype
  if t == TYPE_ARC or t == TYPE_NEEDLE then
    -- a 270 degree arc is 1 + cos(45) radii tall
    local r = math.min(gw / 2, gh / 1.7071)
    w.cx = floor(gx + gw / 2)
    w.cy = floor(gy + r + (gh - r * 1.7071) / 2)
    w.r = floor(r)
    w.thick = t == TYPE_NEEDLE and math.max(3, floor(r * 0.10)) or math.max(4, floor(r * 0.22))
    -- value text box (inside the arc)
    if t == TYPE_NEEDLE then
      w.tw, w.th = floor(r * 1.0), floor(r * 0.42)
      w.tx, w.ty = w.cx, floor(w.cy + r * 0.2)
    else
      w.tw, w.th = floor(r * 1.25), floor(r * 0.6)
      w.tx, w.ty = w.cx, floor(w.cy - w.th / 2)
    end
    -- min/max labels just below the arc ends
    w.limY = floor(w.cy + r * 0.7071 - limH / 2)
    w.limL, w.limR = floor(w.cx - r * 0.7071), floor(w.cx + r * 0.7071)
  elseif t == TYPE_HALF then
    local r = math.min(gw / 2, gh - limH)
    if r < 2 then r = 2 end
    w.cx = floor(gx + gw / 2)
    w.cy = floor(gy + (gh + r - limH) / 2)
    w.r = floor(r)
    w.thick = math.max(4, floor(r * 0.25))
    w.tw, w.th = floor((r - w.thick) * 1.6), floor((r - w.thick) * 0.75)
    w.tx, w.ty = w.cx, w.cy - w.th
    w.limY = w.cy + 1
    w.limL, w.limR = floor(w.cx - r + w.thick / 2), floor(w.cx + r - w.thick / 2)
  elseif t == TYPE_RING then
    local r = math.min(gw, gh) / 2
    w.cx, w.cy, w.r = floor(gx + gw / 2), floor(gy + gh / 2), floor(r)
    w.thick = math.max(4, floor(r * 0.2))
    w.tw, w.th = floor((r - w.thick) * 1.5), floor((r - w.thick) * 0.8)
    w.tx, w.ty = w.cx, floor(w.cy - w.th / 2)
  elseif t == TYPE_HBAR then
    -- value above, bar below, limits under the bar
    local limits = w.showLimits and limH or 0
    local bh = floor(math.max(6, (gh - limits) * 0.45))
    w.bx, w.bw, w.bh = gx, gw, bh
    w.by = gy + gh - limits - bh
    w.tw, w.th = gw, w.by - gy - 2
    w.tx, w.ty = floor(gx + gw / 2), gy
    w.limY = w.by + bh
  else -- TYPE_VBAR
    -- bar on the left, value on the right, limits beside the bar ends
    local bw = floor(math.max(6, gw * 0.3))
    w.bx, w.by, w.bw, w.bh = gx, gy, bw, gh
    w.tw, w.th = gw - bw - pad, gh
    w.tx, w.ty = gx + bw + pad + floor(w.tw / 2), gy
    w.limX = gx + bw + pad
  end
  w.fitKey = nil
end

local function drawLimits(w, fg)
  if not w.showLimits then return end
  lcd.font(FONT_XS)
  lcd.color(fg)
  local t = w.gtype
  if t == TYPE_HBAR then
    lcd.drawText(w.bx, w.limY, w.minText, LEFT)
    lcd.drawText(w.bx + w.bw, w.limY, w.maxText, RIGHT)
  elseif t == TYPE_VBAR then
    lcd.drawText(w.limX, w.by, w.maxText, LEFT)
    lcd.drawText(w.limX, w.by + w.bh - w.limH, w.minText, LEFT)
  elseif t ~= TYPE_RING and w.r >= 30 then
    lcd.drawText(w.limL, w.limY, w.minText, CENTERED)
    lcd.drawText(w.limR, w.limY, w.maxText, CENTERED)
  end
end

local function drawValue(w, fg)
  local text = w.text
  local key = #text
  if key ~= w.fitKey then           -- re-measure only when the length changes
    w.fitKey = key
    local font, _, th = util.fitFont(text, w.tw, w.th)
    w.valueFont, w.valueH = font, th
  end
  lcd.font(w.valueFont)
  lcd.color(fg)
  local y = w.ty
  if w.gtype == TYPE_VBAR or w.gtype == TYPE_RING or w.gtype == TYPE_ARC then
    y = floor(w.ty + (w.th - w.valueH) / 2)
  elseif w.gtype == TYPE_HALF then
    y = w.ty + w.th - w.valueH
  elseif w.gtype == TYPE_HBAR then
    y = floor(w.ty + (w.th - w.valueH) / 2)
  end
  lcd.drawText(w.tx, y, text, CENTERED)
end

local function drawNeedle(w, fg)
  local a = rad(ARC_START[TYPE_NEEDLE] + ARC_SWEEP[TYPE_NEEDLE] * w.frac)
  local dx, dy = sin(a), -cos(a)
  local cx, cy = w.cx, w.cy
  local len = w.r - w.thick - 2
  local bw = math.max(2, w.r * 0.06)
  lcd.color(fg)
  if hasTriangle then
    lcd.drawFilledTriangle(floor(cx + dx * len), floor(cy + dy * len),
      floor(cx - dy * bw), floor(cy + dx * bw),
      floor(cx + dy * bw), floor(cy - dx * bw))
  else
    lcd.drawLine(cx, cy, floor(cx + dx * len), floor(cy + dy * len))
  end
  lcd.drawFilledCircle(cx, cy, floor(bw * 1.6))
end

local function paint(w)
  if not w then return end
  local W, H = lcd.getWindowSize()
  local fg = lcd.themeColor(THEME_DEFAULT_COLOR)

  if not w.source then
    lcd.font(FONT_S)
    lcd.color(fg)
    local _, th = lcd.getTextSize("Ag")
    lcd.drawText(W / 2, (H - th) / 2, "@i18n(widget.configure)@", CENTERED)
    return
  end

  if W ~= w.layoutW or H ~= w.layoutH then layout(w, W, H) end

  local track = (lcd.darkMode and lcd.darkMode()) and lcd.GREY(70) or lcd.GREY(200)

  if w.showTitle then
    lcd.font(w.titleFont)
    lcd.color(fg)
    lcd.drawText(W / 2, w.titleY, w.title, CENTERED)
  end

  local t = w.gtype
  if t == TYPE_HBAR or t == TYPE_VBAR then
    lcd.color(track)
    lcd.drawFilledRectangle(w.bx, w.by, w.bw, w.bh)
    lcd.color(w.color)
    if t == TYPE_HBAR then
      local fw = floor(w.bw * w.frac + 0.5)
      if fw > 0 then lcd.drawFilledRectangle(w.bx, w.by, fw, w.bh) end
    else
      local fh = floor(w.bh * w.frac + 0.5)
      if fh > 0 then lcd.drawFilledRectangle(w.bx, w.by + w.bh - fh, w.bw, fh) end
    end
  else
    local start, sweep = ARC_START[t], ARC_SWEEP[t]
    local ro, ri = w.r, w.r - w.thick
    lcd.color(track)
    drawArc(w.cx, w.cy, ri, ro, start, sweep)
    if w.frac > 0 then
      lcd.color(w.color)
      drawArc(w.cx, w.cy, ri, ro, start, sweep * w.frac)
    end
    if t == TYPE_NEEDLE then drawNeedle(w, fg) end
  end

  drawLimits(w, fg)
  drawValue(w, fg)
end

-- A newly picked source pre-fills min/max with its own range (sticks are
-- -1024..1024, sensors carry their configured range). The pilot can then
-- narrow it. Ranges the number fields can't hold are ignored.
local function useSourceRange(w, src)
  if not src or not src.minimum or not src.maximum then return end
  local ok, lo, hi = pcall(function() return src:minimum(), src:maximum() end)
  if not ok or type(lo) ~= "number" or type(hi) ~= "number" or hi <= lo then return end
  lo, hi = floor(lo * 10 + 0.5), floor(hi * 10 + 0.5)
  if lo < -RANGE_LIMIT or hi > RANGE_LIMIT then return end
  w.min, w.max = lo, hi
  if form.invalidate then form.invalidate() end
end

local function configure(w)
  local line = form.addLine("@i18n(widget.type)@")
  form.addChoiceField(line, nil, TYPE_CHOICES,
    function() return w.gtype end,
    function(v) w.gtype = v; refresh(w) end)

  line = form.addLine("@i18n(widget.source)@")
  form.addSourceField(line, nil,
    function() return w.source end,
    function(v)
      if v ~= w.source then useSourceRange(w, v) end
      w.source = v
      refresh(w)
    end)

  line = form.addLine("@i18n(widget.min)@")
  local f = form.addNumberField(line, nil, -RANGE_LIMIT, RANGE_LIMIT,
    function() return w.min end,
    function(v) w.min = v; refresh(w) end)
  f:decimals(1)

  line = form.addLine("@i18n(widget.max)@")
  f = form.addNumberField(line, nil, -RANGE_LIMIT, RANGE_LIMIT,
    function() return w.max end,
    function(v) w.max = v; refresh(w) end)
  f:decimals(1)

  line = form.addLine("@i18n(widget.color)@")
  form.addColorField(line, nil,
    function() return w.color end,
    function(v) w.color = v; lcd.invalidate() end)

  line = form.addLine("@i18n(widget.show_title)@")
  form.addBooleanField(line, nil,
    function() return w.showTitle end,
    function(v) w.showTitle = v; refresh(w) end)

  line = form.addLine("@i18n(widget.show_limits)@")
  form.addBooleanField(line, nil,
    function() return w.showLimits end,
    function(v) w.showLimits = v; refresh(w) end)
end

local function read(w)
  local _ = storage.read("v")   -- settings version, for future migrations
  w.gtype = storage.read("type") or TYPE_ARC
  w.source = storage.read("source")
  w.min = storage.read("min") or DEFAULT_MIN
  w.max = storage.read("max") or DEFAULT_MAX
  w.color = storage.read("color") or DEFAULT_COLOR
  local v = storage.read("title")
  w.showTitle = v == nil or v == true
  v = storage.read("limits")
  w.showLimits = v == nil or v == true
  if not ARC_SWEEP[w.gtype] and w.gtype ~= TYPE_HBAR and w.gtype ~= TYPE_VBAR then
    w.gtype = TYPE_ARC
  end
  refresh(w)
end

local function write(w)
  storage.write("v", SETTINGS_VERSION)
  storage.write("type", w.gtype)
  storage.write("source", w.source)
  storage.write("min", w.min)
  storage.write("max", w.max)
  storage.write("color", w.color)
  storage.write("title", w.showTitle)
  storage.write("limits", w.showLimits)
end

return {
  key = "etgauge",                -- unique, 7 characters max; never change after release
  name = "@i18n(project.name)@",
  title = false,                  -- the gauge draws the source name itself
  create = create, wakeup = wakeup, paint = paint,
  configure = configure, read = read, write = write,
}
