-- Pure geometry for the loop control's path-following repeat arrows.

local loop_icon = {}

local pi = math.pi
local tau = pi * 2
local arc_length = pi * 2
local shaft_length = 1 + arc_length + 14
local half_route = shaft_length + 7
local route_length = half_route * 2

-- The UI draws this many straight sections for each moving shaft.
loop_icon.SEGMENTS = 32

local function unit(value, message)
  if type(value) ~= "number" or value ~= value
      or value == math.huge or value == -math.huge then
    error(message, 3)
  end
  if value <= 0 then return 0 end
  if value >= 1 then return 1 end
  return value
end

local function arrow_tip(arrow_index)
  assert(arrow_index == 1 or arrow_index == 2,
    "arrow_index must be 1 or 2")
  if arrow_index == 1 then return shaft_length end
  return half_route + shaft_length
end

-- Return one point on the closed route, addressed by distance along it.
local function route_point(distance)
  distance = distance % route_length

  if distance < 1 then
    return 3, 11 - distance
  end
  distance = distance - 1

  if distance < arc_length then
    local angle = pi + distance / 4
    return 7 + 4 * math.cos(angle), 10 + 4 * math.sin(angle)
  end
  distance = distance - arc_length

  if distance < 14 then
    return 7 + distance, 6
  end
  distance = distance - 14

  if distance < 7 then
    return 21, 6 + distance
  end
  distance = distance - 7

  if distance < 1 then
    return 21, 13 + distance
  end
  distance = distance - 1

  if distance < arc_length then
    local angle = distance / 4
    return 17 + 4 * math.cos(angle), 14 + 4 * math.sin(angle)
  end
  distance = distance - arc_length

  if distance < 14 then
    return 17 - distance, 18
  end
  distance = distance - 14

  return 3, 18 - distance
end

local function travel(progress)
  local eased = progress * progress * (3 - 2 * progress)
  return half_route * eased
end

-- Sample a moving shaft in the icon's 24 x 24 coordinates.
-- `fraction` runs from tail (0) to arrowhead (1). Values outside either
-- unit interval clamp to its nearest end so drawing remains inside the icon.
function loop_icon.sample(progress, arrow_index, fraction)
  progress = unit(progress, "progress must be a finite number")
  fraction = unit(fraction, "fraction must be a finite number")
  local tip = arrow_tip(arrow_index) + travel(progress)
  return route_point(tip - shaft_length + shaft_length * fraction)
end

-- Return the arrowhead position and direction in radians. Direction uses a
-- short chord across the tip, matching the mockup's smooth corner movement.
function loop_icon.head(progress, arrow_index)
  local raw_progress = unit(progress, "progress must be a finite number")
  local offset = travel(raw_progress)
  local tip = arrow_tip(arrow_index) + offset
  local x, y = route_point(tip)
  local behind_x, behind_y = route_point(tip - 1.6)
  local ahead_x, ahead_y = route_point(tip + 0.15)
  local angle = math.atan(ahead_y - behind_y, ahead_x - behind_x)

  -- Pin the exact rest directions at both ends, then fade into the route's
  -- direction over the first and last 1.5 path units.
  local edge = math.min(1, offset / 1.5, (half_route - offset) / 1.5)
  local endpoint = arrow_index == 1 and 0 or pi
  if raw_progress >= 0.5 then endpoint = endpoint + pi end
  while angle - endpoint > pi do angle = angle - tau end
  while angle - endpoint < -pi do angle = angle + tau end
  angle = endpoint + (angle - endpoint) * edge

  return x, y, angle
end

return loop_icon
