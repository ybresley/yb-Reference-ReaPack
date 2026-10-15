-- Screen-space drawing points derived from measured loudness history.
-- The caller splits invalid readings and time gaps before calling this module.
local display = {}

-- Match the native drawing buffer allocated by the meter adapter.
local MAX_POINTS = 6001

function display.radius(width)
  return math.max(1, math.ceil(width / (MAX_POINTS - 2)))
end

local function value_at(points, count, x)
  local low, high = 1, count - 1
  while low < high do
    local mid = (low + high) // 2
    if points[mid * 2 + 1] < x then low = mid + 1 else high = mid end
  end
  local x0, y0 = points[low * 2 - 1], points[low * 2]
  local x1, y1 = points[low * 2 + 1], points[low * 2 + 2]
  if x1 <= x0 then return y1 end
  return y0 + (y1 - y0) * (x - x0) / (x1 - x0)
end

-- Each cursor integrates the measured polyline once as sample windows advance.
local function area_at(points, count, cursor, x)
  local segment, area = cursor.segment, cursor.area
  while segment < count - 1 and points[segment * 2 + 1] <= x do
    local x0, y0 = points[segment * 2 - 1], points[segment * 2]
    local x1, y1 = points[segment * 2 + 1], points[segment * 2 + 2]
    area = area + (y0 + y1) * (x1 - x0) / 2
    segment = segment + 1
  end
  cursor.segment, cursor.area = segment, area
  local x0, y0 = points[segment * 2 - 1], points[segment * 2]
  local x1, y1 = points[segment * 2 + 1], points[segment * 2 + 2]
  local y = x1 <= x0 and y1 or y0 + (y1 - y0) * (x - x0) / (x1 - x0)
  return area + (y0 + y) * (x - x0) / 2
end

function display.reduce(points, count, output, left, right, origin)
  if count < 1 or right <= left then return 0 end
  local source_first, source_last = points[1], points[count * 2 - 1]
  local first, last = math.max(left, source_first), math.min(right, source_last)
  if last < first then return 0 end
  origin = origin or 0

  local used = 0
  local function add(x, y)
    used = used + 1
    output[used * 2 - 1], output[used * 2] = x, y
  end
  if count == 1 then
    add(first, points[2])
    return used
  end
  add(first, value_at(points, count, first))
  if last == first then return used end

  -- Each completed point averages two screen pixels of the measured curve.
  -- The grid follows audio time, so completed bends only translate as it scrolls.
  -- At unusually wide sizes, spacing grows to respect the native buffer limit.
  local spacing = display.radius(right - left)
  local radius = spacing
  local earliest = math.max(first, source_first + radius)
  local latest = math.min(last, source_last - radius)
  local column = math.ceil((earliest - origin) / spacing - 0.5)
  local before, after = { segment = 1, area = 0 }, { segment = 1, area = 0 }
  while used < MAX_POINTS - 1 do
    local centre = origin + (column + 0.5) * spacing
    if centre > latest then break end
    if centre > first and centre < last and centre - radius >= source_first then
      local a = area_at(points, count, before, centre - radius)
      local b = area_at(points, count, after, centre + radius)
      add(centre, (b - a) / (2 * radius))
    end
    column = column + 1
  end
  -- The still-growing tip stays at its exact measured value; it is never used
  -- to revise a completed sample whose full two-pixel window was already known.
  add(last, value_at(points, count, last))
  return used
end

return display
