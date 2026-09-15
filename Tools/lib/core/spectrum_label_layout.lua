-- Label rectangles keep their owners while moving or fading. New labels must
-- fit around those reservations, regardless of the order peaks are detected.
local layout = {}

local function intersects(a, b, gap)
  return a.x0 < b.x1 + gap and a.x1 + gap > b.x0
    and a.y0 < b.y1 + gap and a.y1 + gap > b.y0
end

function layout.new()
  return { entries = {}, count = 0 }
end

function layout.reset(state, bounds, gap)
  state.count, state.bounds, state.gap = 0, bounds, gap
end

function layout.reserve(state, owner, rect)
  local entry
  for i = 1, state.count do
    if state.entries[i].owner == owner then entry = state.entries[i]; break end
  end
  if not entry then
    state.count = state.count + 1
    entry = state.entries[state.count] or {}
    state.entries[state.count] = entry
  end
  entry.owner = owner
  entry.x0, entry.y0, entry.x1, entry.y1 = rect.x0, rect.y0, rect.x1, rect.y1
end

function layout.fits(state, rect, owner)
  local bounds, gap = state.bounds, state.gap
  if rect.x0 < bounds.x0 or rect.y0 < bounds.y0
      or rect.x1 > bounds.x1 or rect.y1 > bounds.y1 then return false end
  if bounds.excluded and intersects(rect, bounds.excluded, gap)
      or bounds.controls and intersects(rect, bounds.controls, gap)
      or bounds.clear and intersects(rect, bounds.clear, gap) then return false end
  for i = 1, state.count do
    local entry = state.entries[i]
    if entry.owner ~= owner and intersects(rect, entry, gap) then return false end
  end
  return true
end

return layout
