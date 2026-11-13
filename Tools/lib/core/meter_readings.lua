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

function readings.peak_measurement(model)
  if model.true_peak_available == false then return 'Sample Peak' end
  return (model.prefs or {}).peak_measurement or 'True Peak'
end

function readings.peak(values)
  values = values or {}
  local peak
  local function include(value)
    if valid_level(value) and value ~= -math.huge then
      peak = peak and math.max(peak, value) or value
    end
  end
  if type(values.channels) == 'table' and #values.channels > 0 then
    for _, channel in ipairs(values.channels) do include(channel.peak) end
  else
    include(values.peak_l)
    include(values.peak_r)
  end
  return peak
end

function readings.rms(values)
  values = values or {}
  if type(values.channels)=='table' and #values.channels>0 then
    local power,has_reading=0,false
    for _,channel in ipairs(values.channels) do
      if channel.rms~=nil then has_reading=true end
      local contribution,valid=channel_power(channel.rms)
      if not valid then return nil end
      power=power+contribution
    end
    if not has_reading then return nil end
    return power>0 and 10*math.log(power/#values.channels)/math.log(10) or -math.huge
  end
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
  if type(model) ~= 'table' or model.loudness_available==false then return nil end
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
