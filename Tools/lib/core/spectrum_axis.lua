-- Bounds and spacing for the spectrum's frequency-axis labels.
local axis = {}

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

return axis
