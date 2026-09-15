local spectrum_curve = {}
-- Blend overlapping three-bin maxima to round captured joins without copying
-- a summit into a flat shelf. A narrow peak keeps its height and position.
-- Each endpoint retains at least three quarters of either adjacent raw rise;
-- the monotone sampler's slopes are bounded by twice its segment rise, which
-- keeps the curve above the raw segment between measurements too. Drawing
-- chords between those samples preserves that coverage.
--
-- Always read the original values: feeding this result back would keep
-- widening the spectrum for as long as the pointer remained over it.
function spectrum_curve.smooth_outline(values, count, destination)
  for index = 1, count do
    local before = values[math.max(1, index - 1)]
    local centre = values[index]
    local after = values[math.min(count, index + 1)]
    local left = math.max(values[math.max(1, index - 2)], before, centre)
    local middle = math.max(before, centre, after)
    local right = math.max(centre, after, values[math.min(count, index + 2)])
    destination[index] = (left + 2 * middle + right) / 4
  end
  return destination
end

local function value_at(values, index)
  return values[index]
end

local function monotone_slope(before, after)
  if before * after <= 0 then return 0 end
  return 2 * before * after / (before + after)
end

function spectrum_curve.subdivisions(count, width)
  count = math.max(0, math.floor(tonumber(count) or 0))
  if count == 0 then return 0 end
  width = math.max(0, tonumber(width) or 0)
  -- Quarter points are needed to round an isolated peak: its midpoint alone
  -- can lie on the same straight segment as the unsmoothed drawing.
  return math.min(8, math.max(4, math.ceil(width / count)))
end

-- Interpolate the drawn line between dB measurements without changing any
-- measurement or introducing a value beyond either neighbouring point.
function spectrum_curve.sample(values, count, position)
  count = math.max(0, math.floor(tonumber(count) or 0))
  if count == 0 then return nil end
  if count == 1 then return value_at(values, 1) end

  position = tonumber(position) or 1
  if position <= 1 then return value_at(values, 1) end
  if position >= count then return value_at(values, count) end

  local left = math.floor(position)
  local right = left + 1
  local previous = value_at(values, math.max(1, left - 1))
  local first = value_at(values, left)
  local second = value_at(values, right)
  local following = value_at(values, math.min(count, right + 1))
  local left_slope = monotone_slope(first - previous, second - first)
  local right_slope = monotone_slope(second - first, following - second)
  local t = position - left
  local t2 = t * t
  local t3 = t2 * t
  local result = (2 * t3 - 3 * t2 + 1) * first
    + (t3 - 2 * t2 + t) * left_slope
    + (-2 * t3 + 3 * t2) * second
    + (t3 - t2) * right_slope
  return math.max(math.min(first, second), math.min(result, math.max(first, second)))
end

-- Match the straight segments sent to the renderer between its sampled curve
-- vertices, so labels sit on the visible line rather than the ideal curve.
function spectrum_curve.sample_drawn(values, count, position, width)
  count = math.max(0, math.floor(tonumber(count) or 0))
  if count <= 1 then return spectrum_curve.sample(values, count, position) end

  position = tonumber(position) or 1
  if position <= 1 or position >= count then
    return spectrum_curve.sample(values, count, position)
  end

  local subdivisions = spectrum_curve.subdivisions(count, width)
  local left = 1 + math.floor((position - 1) * subdivisions) / subdivisions
  local right = math.min(count, left + 1 / subdivisions)
  local left_value = spectrum_curve.sample(values, count, left)
  local right_value = spectrum_curve.sample(values, count, right)
  return left_value + (right_value - left_value) * (position - left) / (right - left)
end

-- A nearby summit belongs to a different peak if reaching it crosses a clear
-- dip or gives up height. The wider saddle allowance follows shallow reshaping
-- on one visible crest without letting an identity move to a lower neighbour.
function spectrum_curve.same_crest(values, count, from, target)
  if count < 1 then return false end
  from = math.max(1, math.min(count, from))
  target = math.max(1, math.min(count, target))
  local from_db = spectrum_curve.sample(values, count, from)
  local target_db = spectrum_curve.sample(values, count, target)
  local height_tolerance = 0.15
  local saddle_tolerance = 0.5
  if target_db < from_db - height_tolerance then return false end
  local floor = math.min(from_db, target_db) - saddle_tolerance
  for index = math.ceil(math.min(from, target)), math.floor(math.max(from, target)) do
    if values[index] < floor then return false end
  end
  return true
end

return spectrum_curve
