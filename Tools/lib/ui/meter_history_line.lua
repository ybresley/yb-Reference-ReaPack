local colours = require('ui.meter_colours')

local line = {}

-- Reuse one list; drawing is synchronous and at most one split per source point.
local corners = {}
local function find_corners(points, count)
  local used = 0
  for i = 2, count - 1 do
    local x, y = points[i * 2 - 1], points[i * 2]
    local ax, ay = x - points[i * 2 - 3], y - points[i * 2 - 2]
    local bx, by = points[i * 2 + 1] - x, points[i * 2 + 2] - y
    local dot = ax * bx + ay * by
    -- Split turns greater than 60 degrees, including either end of a narrow
    -- flat-bottomed dip. Native miters can fold over these short segments.
    if dot < 0 or dot * dot < .25 * (ax * ax + ay * ay) * (bx * bx + by * by) then
      used = used + 1
      corners[used] = i
    end
  end
  return used
end

local function stroke(R, dl, points, count, scratch, colour, thickness, splits)
  if splits == 0 then
    R.ImGui_DrawList_AddPolyline(dl, points, colour, 0, thickness)
    return
  end
  -- The fill has already been painted, so its native buffer is free for runs.
  -- Source points stay intact for the next colour band and hover readings.
  local first = 1
  for part = 1, splits + 1 do
    local last = part <= splits and corners[part] or count
    local size = (last - first + 1) * 2
    scratch.resize(size)
    scratch.copy(points, (first - 1) * 2 + 1, size, 1)
    R.ImGui_DrawList_AddPolyline(dl, scratch, colour, 0, thickness)
    if part <= splits then
      R.ImGui_DrawList_AddCircleFilled(dl, points[last * 2 - 1], points[last * 2],
        thickness / 2, colour, 12)
    end
    first = last
  end
end

function line.stroke(R, dl, points, count, scratch, colour, thickness)
  if count < 2 then return end
  stroke(R, dl, points, count, scratch, colour, thickness, find_corners(points, count))
end

-- Fixed level boundaries keep colour changes still while history scrolls.
local steps = { 16, 16 }

local function colour_at(options, level)
  local lead=options.yellow_lead or 5
  return colours.at(options.palette or 'Accent Fade',
    math.max(-lead, level - options.target), options.accent, options)
end

local function level_at_y(y, map, bottom, top, low, high, target, lead, span)
  for i=1,3 do
    local offset=i==1 and -lead or i==2 and 0 or span
    -- The exact landmark matters for a flat line on the target.
    local level = target + offset
    if y == map(level, bottom, top, low, high) and level >= low and level <= high then
      return level
    end
  end
  local a, b = low, high
  for _ = 1, 24 do
    local mid = (a + b) / 2
    if map(mid, bottom, top, low, high) > y then a = mid else b = mid end
  end
  return (a + b) / 2
end

-- The line and fill share colour boundaries so their target crossings agree.
function line.bands(options, draw)
  local low,high,top,bottom=options.low,options.high,options.top,options.bottom
  local map,target=options.map,options.target
  local lead,span=options.yellow_lead or 5,options.red_span or 3
  local function landmark(i) return i==1 and -lead or i==2 and 0 or span end
  local function band(a,b)
    a,b=math.max(low,a),math.min(high,b)
    if b<=a then return end
    local upper=math.max(top,math.floor(map(b,bottom,top,low,high)+.5))
    local lower=math.min(bottom,math.floor(map(a,bottom,top,low,high)+.5))
    if lower>upper then
      draw(upper,lower,colour_at(options,b))
    end
  end
  band(low,target-lead)
  for i=1,#steps do
    local a,b=target+landmark(i),target+landmark(i+1)
    local step=(b-a)/steps[i]
    for j=1,steps[i] do band(a+step*(j-1),a+step*j) end
  end
  band(target+span,high)
end

function line.paint(R, dl, points, count, options, scratch)
  if count < 2 then return 0 end
  local left, right = options.left, options.right
  local top, bottom = options.top, options.bottom
  local low, high = options.low, options.high
  if right <= left or bottom <= top or high <= low then return 0 end

  local map, target = options.map, options.target
  local palette, accent = options.palette or 'Accent Fade', options.accent
  local thickness = math.max(1, math.floor(options.thickness + .5))
  local min_y, max_y = points[2], points[2]
  for i = 2, count do
    local y = points[i * 2]
    if y < min_y then min_y = y end
    if y > max_y then max_y = y end
  end
  if max_y + thickness / 2 + 1 < top or min_y - thickness / 2 - 1 > bottom then return 0 end

  local splits = find_corners(points, count)
  local function draw(upper, lower, colour)
    if upper >= lower or lower < min_y - thickness / 2 - 1 or
        upper > max_y + thickness / 2 + 1 then return 0 end
    upper, lower = math.max(top, upper), math.min(bottom, lower)
    if upper >= lower then return 0 end
    R.ImGui_DrawList_PushClipRect(dl, left, upper, right, lower, true)
    stroke(R, dl, points, count, scratch, colour, thickness, splits)
    R.ImGui_DrawList_PopClipRect(dl)
    return 1
  end

  if min_y == max_y then
    local value = level_at_y(min_y, map, bottom, top, low, high, target,
      options.yellow_lead or 5, options.red_span or 3)
    local colour = colour_at(options, value)
    return draw(top, bottom, colour)
  end

  local draws = 0
  line.bands(options,function(upper,lower,colour)
    draws=draws+draw(upper,lower,colour)
  end)
  return draws
end

return line
