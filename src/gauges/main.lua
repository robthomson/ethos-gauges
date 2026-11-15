-- gauges: a configurable gauge widget for FrSky Ethos.
-- Drop the widget into any screen slot, then pick a gauge style, a source and
-- a min/max range in its configuration page. Each slot keeps its own settings
-- (saved in the model through the widget's read/write handlers).
-- Docs: https://ethos-lua-doc.frsky-rc.com/

-- Loaded once, at load time (relative paths are fine here).
local util = assert(loadfile("lib/util.lua"))()
local widget = assert(loadfile("widget.lua"))(util)

local function init()
  system.registerWidget(widget)
end

return { init = init }
