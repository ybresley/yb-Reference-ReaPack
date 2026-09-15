-- Paint-only guide pointer based on this Windows install's 32 px aero_arrow.cur.
-- The source cursor's hotspot is its top-left pixel. Static horizontal runs keep
-- the stock silhouette crisp without creating an image resource in the frame loop.

local theme = require("ui.theme")

local pointer = {}

local SOFT = {
  0, 1, 1,  1, 2, 2,  2, 3, 3,  3, 4, 4,  4, 5, 5,
  5, 6, 6,  6, 7, 7,  7, 8, 8,  8, 9, 9,  9, 10, 10,
  10, 11, 11,  13, 8, 8,  14, 4, 4,  15, 3, 3,  15, 9, 9,
  16, 2, 2,  16, 5, 5,  18, 6, 6,  18, 9, 9,
}

local OUTLINE = {
  0, 0, 0,  1, 0, 1,  2, 0, 0,  2, 2, 2,  3, 0, 0,
  3, 3, 3,  4, 0, 0,  4, 4, 4,  5, 0, 0,  5, 5, 5,
  6, 0, 0,  6, 6, 6,  7, 0, 0,  7, 7, 7,  8, 0, 0,
  8, 8, 8,  9, 0, 0,  9, 9, 9,  10, 0, 0,  10, 10, 10,
  11, 0, 0,  11, 11, 11,  12, 0, 0,  12, 7, 11,
  13, 0, 0,  13, 4, 5,  13, 7, 7,
  14, 0, 0,  14, 3, 3,  14, 5, 5,  14, 8, 8,
  15, 0, 0,  15, 2, 2,  15, 5, 6,  15, 8, 8,
  16, 0, 1,  16, 6, 6,  16, 9, 9,
  17, 6, 6,  17, 9, 9,  18, 7, 8,
}

local FILL = {
  2, 1, 1,  3, 1, 2,  4, 1, 3,  5, 1, 4,  6, 1, 5,
  7, 1, 6,  8, 1, 7,  9, 1, 8,  10, 1, 9,  11, 1, 10,
  12, 1, 6,  13, 1, 3,  13, 6, 6,
  14, 1, 2,  14, 6, 7,  15, 1, 1,  15, 7, 7,
  16, 7, 8,  17, 7, 8,
}

local function paint_runs(dl, ox, oy, scale, runs, colour)
  for i = 1, #runs, 3 do
    local row, first, last = runs[i], runs[i + 1], runs[i + 2]
    local x0 = ox + math.floor(first * scale + 0.5)
    local y0 = oy + math.floor(row * scale + 0.5)
    local x1 = ox + math.floor((last + 1) * scale + 0.5)
    local y1 = oy + math.floor((row + 1) * scale + 0.5)
    reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, x1, y1, colour)
  end
end

function pointer.paint_click(dl, x, y, click)
  local scale = theme.scale
  local ox, oy = math.floor(x + 0.5), math.floor(y + 0.5)

  local pulse
  if type(click) == "number" then
    pulse = math.max(0, math.min(1, click))
  elseif click then
    pulse = 0
  end
  if pulse and pulse < 1 then
    local alpha = math.floor(150 * (1 - pulse) + 0.5)
    local radius = (6 + pulse * 7) * scale
    reaper.ImGui_DrawList_AddCircle(dl, ox, oy, radius,
      0xFFFFFF00 | alpha, 24, math.max(1, scale))
  end
end

function pointer.paint(dl, x, y, click)
  local scale = theme.scale
  local ox, oy = math.floor(x + 0.5), math.floor(y + 0.5)
  pointer.paint_click(dl, x, y, click)
  paint_runs(dl, ox, oy, scale, SOFT, 0x00000066)
  paint_runs(dl, ox, oy, scale, OUTLINE, 0x050505FF)
  paint_runs(dl, ox, oy, scale, FILL, 0xFFFFFFFF)
end

return pointer
