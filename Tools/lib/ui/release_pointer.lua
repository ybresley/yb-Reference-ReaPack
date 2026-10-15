-- Paint-only guide pointer based on this Windows install's 32 px aero_arrow.cur.
-- The source cursor's hotspot is its top-left pixel. Static horizontal runs keep
-- the stock silhouette crisp without creating an image resource in the frame loop.

local theme = require("ui.theme")

local pointer = {}

-- Derived from the bundled Chromium grabbing cursor, Copyright 2015 Chromium Authors.
-- BSD licence: assets/cursors/grabbing.LICENSE.txt. Hotspot: (13, 13).
local GRAB_OUTLINE = {7,12,13,8,9,11,8,14,16,9,8,8,9,11,11,9,14,14,9,17,17,10,8,8,10,11,11,10,14,14,10,17,18,11,8,8,11,17,17,11,19,19,12,7,8,12,19,19,13,6,6,13,9,9,13,19,19,14,6,6,14,9,9,14,19,19,15,6,6,15,18,18,16,6,6,16,18,18,17,7,7,17,17,17,18,8,8,18,17,17,19,8,8,19,16,16,20,9,15}
local GRAB_FILL = {8,12,13,9,9,10,9,12,13,9,15,16,10,9,10,10,12,13,10,15,16,11,9,16,11,18,18,12,9,18,13,7,8,13,10,18,14,7,8,14,10,18,15,7,17,16,7,17,17,8,16,18,9,16,19,9,15}

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

function pointer.paint_grab(dl, x, y)
  local scale = theme.scale
  local ox, oy = math.floor(x-13*scale+.5), math.floor(y-13*scale+.5)
  paint_runs(dl, ox, oy, scale, GRAB_OUTLINE, 0x000000FF)
  paint_runs(dl, ox, oy, scale, GRAB_FILL, 0xFFFFFFFF)
end

-- Windows aero_ns.cur, 32 px variant; hotspot (4, 11).
local RESIZE_NS = {0,3,3,0x02051637,0,4,4,0x010210BD,0,5,5,0x02051637,1,2,2,0x02051637,1,3,3,0x010210BD,1,4,4,0xFFFFFFFF,1,5,5,0x010210BD,1,6,6,0x02051637,2,1,1,0x02051637,2,2,2,0x010210BD,2,3,5,0xFFFFFFFF,2,6,6,0x010210BD,2,7,7,0x02051637,3,0,0,0x02051637,3,1,1,0x010210BD,3,2,6,0xFFFFFFFF,3,7,7,0x010210BD,3,8,8,0x02051637,4,0,0,0x010210BD,4,1,7,0xFFFFFFFF,4,8,8,0x010210BD,5,0,0,0x010210BD,5,1,2,0x00000DFF,5,3,3,0x010210BD,5,4,4,0xFFFFFFFF,5,5,5,0x010210BD,5,6,7,0x00000DFF,5,8,8,0x010210BD,6,3,3,0x010210BD,6,4,4,0xFFFFFFFF,6,5,5,0x010210BD,7,3,3,0x010210BD,7,4,4,0xFFFFFFFF,7,5,5,0x010210BD,8,3,3,0x010210BD,8,4,4,0xFFFFFFFF,8,5,5,0x010210BD,9,3,3,0x010210BD,9,4,4,0xFFFFFFFF,9,5,5,0x010210BD,10,3,3,0x010210BD,10,4,4,0xFFFFFFFF,10,5,5,0x010210BD,11,3,3,0x010210BD,11,4,4,0xFFFFFFFF,11,5,5,0x010210BD,12,3,3,0x010210BD,12,4,4,0xFFFFFFFF,12,5,5,0x010210BD,13,3,3,0x010210BD,13,4,4,0xFFFFFFFF,13,5,5,0x010210BD,14,3,3,0x010210BD,14,4,4,0xFFFFFFFF,14,5,5,0x010210BD,15,3,3,0x010210BD,15,4,4,0xFFFFFFFF,15,5,5,0x010210BD,16,3,3,0x010210BD,16,4,4,0xFFFFFFFF,16,5,5,0x010210BD,17,0,0,0x010210BD,17,1,2,0x00000DFF,17,3,3,0x010210BD,17,4,4,0xFFFFFFFF,17,5,5,0x010210BD,17,6,7,0x00000DFF,17,8,8,0x010210BD,18,0,0,0x010210BD,18,1,1,0xF0F0F3FF,18,2,6,0xFFFFFFFF,18,7,7,0xE8E8EAFF,18,8,8,0x010210BD,19,0,0,0x02051637,19,1,1,0x010210BD,19,2,2,0xECECEEFF,19,3,5,0xFFFFFFFF,19,6,6,0xE8E8EAFF,19,7,7,0x010210BD,19,8,8,0x02051637,20,1,1,0x02051637,20,2,2,0x010210BD,20,3,3,0xE8E8EAFF,20,4,4,0xFFFFFFFF,20,5,5,0xE8E8EAFF,20,6,6,0x010210BD,20,7,7,0x02051637,21,2,2,0x02051637,21,3,3,0x010210BD,21,4,4,0xE8E8EAFF,21,5,5,0x010210BD,21,6,6,0x02051637,22,3,3,0x02051637,22,4,4,0x010210BD,22,5,5,0x02051637}

local function paint_resize(dl, x, y, horizontal)
  local s = theme.scale
  local ox = math.floor(x-(horizontal and 11 or 4)*s+.5)
  local oy = math.floor(y-(horizontal and 4 or 11)*s+.5)
  for i=1,#RESIZE_NS,4 do
    local row,first,last,colour = RESIZE_NS[i],RESIZE_NS[i+1],RESIZE_NS[i+2],RESIZE_NS[i+3]
    local x0,y0,x1,y1=first,row,last+1,row+1
    if horizontal then x0,y0,x1,y1=y0,x0,y1,x1 end
    reaper.ImGui_DrawList_AddRectFilled(dl,ox+math.floor(x0*s+.5),oy+math.floor(y0*s+.5),
      ox+math.floor(x1*s+.5),oy+math.floor(y1*s+.5),colour)
  end
end

function pointer.paint_resize_ns(dl,x,y) paint_resize(dl,x,y,false) end
function pointer.paint_resize_ew(dl,x,y) paint_resize(dl,x,y,true) end

return pointer
