-- Bounds and spacing for the spectrum's frequency-axis labels.
local axis = {}
axis.MAX_HZ = 25000

-- Measurements keep their original frequency span within the wider ruler.
function axis.trace_width(width, low_hz, measured_high_hz)
  return width * math.log(measured_high_hz / low_hz) / math.log(axis.MAX_HZ / low_hz)
end

local function clamp(value, low, high)
  return math.max(low, math.min(high, value))
end

function axis.label_left(centre_x, label_width, left, right)
  if right - left <= label_width then return left end
  return clamp(centre_x - label_width * 0.5, left, right - label_width)
end

-- The value reaches zero exactly when two labels touch. A positive falloff
-- makes nearby labels dim before they reach that point.
function axis.label_opacity(label_left, label_width, readout_left,
    readout_width, falloff)
  local label_right = label_left + label_width
  local readout_right = readout_left + readout_width
  local gap = math.max(label_left - readout_right, readout_left - label_right)
  if gap <= 0 then return 0 end
  return clamp(gap / math.max(0.001, falloff), 0, 1)
end

-- Keep the zero marker when it fits, then use the remaining vertical space for
-- as many well-spaced negative level labels as the plot can hold.
function axis.level_ticks(height, bottom, label_height, gap)
  height = tonumber(height) or 0
  bottom = tonumber(bottom) or 0
  label_height = tonumber(label_height) or 0
  gap = tonumber(gap) or 0
  if height <= 0 or bottom >= 0 or label_height <= 0 then return {} end

  local denominator = 6 - bottom
  local step = 10
  while step * height / denominator < label_height + gap do
    step = step + 10
  end

  local ticks = {}
  local zero_y = 6 * height / denominator
  local last_bottom = 0
  if zero_y - label_height * 0.5 >= 0
      and zero_y + label_height * 0.5 <= height then
    ticks[#ticks + 1] = 0
    last_bottom = zero_y + label_height * 0.5
  end

  for db = -step, bottom, -step do
    local y = (6 - db) * height / denominator
    local top = y - label_height * 0.5
    if top >= last_bottom + gap and top + label_height <= height then
      ticks[#ticks + 1] = db
      last_bottom = top + label_height
    end
  end
  return ticks
end

return axis
