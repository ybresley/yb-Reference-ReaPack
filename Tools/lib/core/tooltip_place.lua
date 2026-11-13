-- Where a tooltip sits relative to the thing it explains.
--
-- A tip is pinned to the hovered control or area, not to the pointer, so it
-- holds still while the pointer moves across a meter, waveform or plot. It goes
-- centred just below the anchor, then above it, then beside it, so it never covers what
-- it describes. Only when none of those fit on the monitor does it fall back to
-- the spot under the pointer where the tip first appeared.
--
-- Pure geometry in one shared coordinate space: `anchor` and `work` are
-- {left, top, right, bottom}; the result is the tip's top-left corner.

local tooltip_place = {}

local function clamp(value, low, high)
  if high < low then return low end
  if value < low then return low end
  if value > high then return high end
  return value
end

-- `pointer_x`, `pointer_y`: where the pointer was when the tip was pinned.
-- `gap`: space between anchor and tip. `margin`: space kept from monitor edges.
-- `pointer_offset`: how far below the pointer the last-resort position sits.
function tooltip_place.place(anchor, work, w, h, pointer_x, pointer_y, gap, margin, pointer_offset)
  local min_x, max_x = work.left + margin, work.right - margin - w
  local min_y, max_y = work.top + margin, work.bottom - margin - h

  -- Centred on what it explains: one meter, a button, or a whole panel.
  local x = clamp((anchor.left + anchor.right - w) * 0.5, min_x, max_x)

  local below = anchor.bottom + gap
  if below <= max_y then return math.floor(x), math.floor(below) end
  local above = anchor.top - gap - h
  if above >= min_y then return math.floor(x), math.floor(above) end

  -- An anchor too tall for room above or below: try either side, centred.
  local side_y = clamp((anchor.top + anchor.bottom - h) * 0.5, min_y, max_y)
  local right = anchor.right + gap
  if right <= max_x then return math.floor(right), math.floor(side_y) end
  local left = anchor.left - gap - w
  if left >= min_x then return math.floor(left), math.floor(side_y) end

  return math.floor(clamp(pointer_x - w * 0.5, min_x, max_x)),
    math.floor(clamp(pointer_y + pointer_offset, min_y, max_y))
end

return tooltip_place
