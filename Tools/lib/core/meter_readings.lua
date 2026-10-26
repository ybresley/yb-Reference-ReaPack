-- Pure calculations for the optional meter readouts.
local readings = {}

local function valid_level(value)
  return type(value) == 'number'
    and value == value
    and value ~= math.huge
    and value ~= -100
    and value ~= -150
end

local function channel_power(value)
  if value == nil or value == -150 or value == -math.huge then
    return 0, true
  end
  if not valid_level(value) then return nil, false end
  return 10 ^ (value / 10), true
end

function readings.rms(values)
  values = values or {}
  local left, right = values.rms_l, values.rms_r
  if left == nil and right == nil then return nil end
  local left_power, left_valid = channel_power(left)
  local right_power, right_valid = channel_power(right)
  -- A malformed reading must not make the other channel look like a complete
  -- stereo measurement. The denominator remains two for a silent channel.
  if not left_valid or not right_valid then return nil end
  local power = left_power + right_power
  if power == 0 then return -math.huge end
  return 10 * math.log(power / 2) / math.log(10)
end

function readings.target_difference(model)
  if type(model) ~= 'table' then return nil end
  local prefs = model.prefs or {}
  local values = model.values or {}
  local measurement = prefs.target_difference_measurement or 'Integrated'
  local key = measurement == 'Momentary' and 'm'
    or measurement == 'Short-Term' and 's'
    or measurement == 'Integrated' and 'i'
  if not key then return nil end
  if key == 'i' and prefs.keep_integrated == false
      and model.playing == false and not model.hold then
    return nil
  end
  local value, target = values[key], prefs.target
  if not (valid_level(value) or value == -math.huge)
      or not valid_level(target) or target == -math.huge then
    return nil
  end
  return value - target
end

return readings
