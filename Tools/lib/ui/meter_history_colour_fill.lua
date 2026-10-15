local line = require('ui.meter_history_line')

local fill = {}

-- The caller owns the tile clip and supplies a polygon already closed at the floor.
-- A band wholly below the contour needs only a rectangle; bands crossing it reuse
-- the same native polygon with a narrower clip.
function fill.paint(R, dl, points, left, right, highest, lowest, options)
  if right <= left or options.bottom <= options.top or options.high <= options.low
      or options.opacity == 0 then return 0, 0 end

  local polygons, rectangles = 0, 0
  line.bands(options, function(upper, lower, opaque_colour)
    if lower <= highest then return end
    local colour = (opaque_colour & 0xFFFFFF00) | options.opacity
    if upper >= lowest then
      R.ImGui_DrawList_AddRectFilled(dl, left, upper, right, lower, colour)
      rectangles = rectangles + 1
    else
      R.ImGui_DrawList_PushClipRect(dl, left, upper, right, lower, true)
      R.ImGui_DrawList_AddConcavePolyFilled(dl, points, colour)
      R.ImGui_DrawList_PopClipRect(dl)
      polygons = polygons + 1
    end
  end)
  return polygons, rectangles
end

return fill
