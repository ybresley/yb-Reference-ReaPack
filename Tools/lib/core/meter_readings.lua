-- Pure calculations for the optional meter readouts.
local scale = require('core.meter_scale')
local readings = {}
local SIDES = { 'l', 'r' }

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

-- The highest peak since reset, in the measurement the channels use.
function readings.peak_maximum(model)
  if readings.peak_measurement(model) == 'Sample Peak' then return model.sp_max end
  return model.tp_max
end

-- REAPER keeps an already loaded meter's old controls until it restarts, so
-- an updated install cannot report the Sample Peak maximum before then.
function readings.peak_maximum_hint(model)
  if readings.peak_measurement(model) == 'Sample Peak' and model.true_peak_available ~= false
      and model.sample_peak_max_available == false then
    return 'Restart REAPER to show the Sample Peak maximum.'
  end
end

-- Short label, unit and tooltip name for that maximum.
function readings.peak_maximum_label(model)
  if readings.peak_measurement(model) == 'Sample Peak' then return 'P', 'dBFS', 'Sample-peak' end
  return 'TP', 'dBTP', 'True-peak'
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

-- After playback ends, the live numbers follow their falling bars down and
-- show a dash once a bar leaves the scale. Integrated, and the maxima, crest
-- and LRA of a measurement that a reset replaced, keep their last values until
-- playback starts again. Returns the model itself when nothing is fading, so
-- normal drawing is unchanged.
function readings.shown(model)
  local fade = model.readout_fade
  if not fade then return model end
  local prefs = model.prefs or {}
  local loudness_low = prefs.range and scale.loudness(prefs) or -math.huge
  local level_low = prefs.lr_floor or -48
  local display = model.display or {}
  local snapshot = fade.reset and fade.values or nil
  local base = snapshot or model.values or {}
  local function above(value, low)
    return type(value) == 'number' and value > low and value or nil
  end
  local view = fade.view
  if not view then
    view = setmetatable({}, { __index = model })
    fade.view, fade.view_values, fade.view_channels = view, {}, {}
  end
  local values = fade.view_values
  for key in pairs(values) do values[key] = nil end
  for key, value in pairs(base) do values[key] = value end
  values.m, values.s = above(display.m, loudness_low), above(display.s, loudness_low)
  values.i = fade.values.i
  for _, side in ipairs(SIDES) do
    local peak = above(display['live_peak_' .. side], level_low)
    values['rms_' .. side] = above(display['rms_' .. side], level_low)
    values['peak_' .. side], values['live_peak_' .. side] = peak, peak
  end
  local channels = fade.view_channels
  for index = #channels, 1, -1 do channels[index] = nil end
  for index, drawn in ipairs(display.channels or {}) do
    local source = (base.channels or {})[index] or {}
    local channel = channels[index] or {}
    for key in pairs(channel) do channel[key] = nil end
    for key, value in pairs(source) do channel[key] = value end
    local peak = above(drawn.live_peak, level_low)
    channel.rms, channel.peak, channel.live_peak = above(drawn.rms, level_low), peak, peak
    channels[index] = channel
  end
  values.channels = channels
  view.values = values
  view.m_max = snapshot and fade.m_max or model.m_max
  view.s_max = snapshot and fade.s_max or model.s_max
  view.tp_max = snapshot and fade.tp_max or model.tp_max
  view.sp_max = snapshot and fade.sp_max or model.sp_max
  return view
end

return readings
