-- Pure listening-filter rules shared by the UI and the Monitoring FX adapter.
-- The live on/off state is deliberately never decoded from preferences: a
-- monitoring check must start full-range on every launch.

local monitor_filter = {}
local json = require("vendor.json")

monitor_filter.MIN_HZ = 10
monitor_filter.MAX_HZ = 20000
monitor_filter.MIN_GAP_HZ = 1

monitor_filter.SLOPES = { 12, 24, 36, 48 }

monitor_filter.PRESETS = {
  { id = "sub",     label = "Sub",     low_hz = 10,   high_hz = 60 },
  { id = "bass",    label = "Bass",    low_hz = 10,   high_hz = 250 },
  { id = "low_mid", label = "Low Mid", low_hz = 250,  high_hz = 700 },
  { id = "mid",     label = "Mid",     low_hz = 700,  high_hz = 3000 },
  { id = "high",    label = "High",    low_hz = 3000, high_hz = 20000 },
}

local PRESET_BY_ID = {}
for _, preset in ipairs(monitor_filter.PRESETS) do
  PRESET_BY_ID[preset.id] = preset
end

local LEGACY_MODE = { below = true, band = true, above = true }
local VALID_SLOPE = {}
for _, slope in ipairs(monitor_filter.SLOPES) do VALID_SLOPE[slope] = true end

local function clamp(value, low, high)
  return math.max(low, math.min(high, value))
end

local function finite(value)
  value = tonumber(value)
  return value and value == value and math.abs(value) < math.huge and value or nil
end

local function copy_presets(source)
  local result = {}
  for _, preset in ipairs(monitor_filter.PRESETS) do
    local candidate = type(source) == "table" and source[preset.id]
    local low = type(candidate) == "table" and finite(candidate.low_hz)
    local high = type(candidate) == "table" and finite(candidate.high_hz)
    if not low or not high or low < 10 or high > 20000 or high - low < 1 then
      low, high = preset.low_hz, preset.high_hz
    end
    result[preset.id] = { low_hz = math.floor(low + 0.5), high_hz = math.floor(high + 0.5) }
  end
  return result
end

local function rounded_hz(value)
  return math.floor(tonumber(value) + 0.5)
end

function monitor_filter.defaults()
  return {
    on = false,
    low_hz = 700,
    high_hz = 3000,
    slope = 24,
    presets = copy_presets(),
  }
end

function monitor_filter.normalise(value)
  local defaults = monitor_filter.defaults()
  value = type(value) == "table" and value or {}

  local slope = finite(value.slope)
  slope = VALID_SLOPE[slope] and slope or defaults.slope

  local low_hz = rounded_hz(clamp(finite(value.low_hz) or defaults.low_hz,
    monitor_filter.MIN_HZ, monitor_filter.MAX_HZ - 1))
  local high_hz = rounded_hz(clamp(finite(value.high_hz) or defaults.high_hz,
    monitor_filter.MIN_HZ + 1, monitor_filter.MAX_HZ))
  high_hz = math.max(high_hz, low_hz + 1)

  return {
    on = value.on == true,
    low_hz = rounded_hz(low_hz),
    high_hz = rounded_hz(high_hz),
    slope = slope,
    presets = copy_presets(value.presets),
    selected_id = value.on == true and PRESET_BY_ID[value.selected_id] and value.selected_id or nil,
  }
end

function monitor_filter.set_boundary(value, boundary, hz)
  local result = monitor_filter.normalise(value)
  hz = finite(hz)
  if not hz then return result end

  if boundary == "low" then
    result.low_hz = rounded_hz(clamp(hz, monitor_filter.MIN_HZ,
      result.high_hz - 1))
  elseif boundary == "high" then
    result.high_hz = rounded_hz(clamp(hz,
      result.low_hz + 1, monitor_filter.MAX_HZ))
  else
    return result
  end
  result.on, result.selected_id = true, nil
  return monitor_filter.normalise(result)
end

function monitor_filter.apply_preset(value, id)
  local result = monitor_filter.normalise(value)
  local preset = result.presets[id]
  if not preset then return result end
  result.on = true
  result.low_hz = preset.low_hz
  result.high_hz = preset.high_hz
  result.selected_id = id
  return result
end

function monitor_filter.frequency_to_t(hz)
  hz = clamp(finite(hz) or monitor_filter.MIN_HZ,
    monitor_filter.MIN_HZ, monitor_filter.MAX_HZ)
  return math.log(hz / monitor_filter.MIN_HZ)
    / math.log(monitor_filter.MAX_HZ / monitor_filter.MIN_HZ)
end

function monitor_filter.t_to_frequency(t)
  t = clamp(finite(t) or 0, 0, 1)
  return rounded_hz(monitor_filter.MIN_HZ
    * (monitor_filter.MAX_HZ / monitor_filter.MIN_HZ) ^ t)
end

function monitor_filter.format_frequency(hz)
  hz = rounded_hz(clamp(finite(hz) or monitor_filter.MIN_HZ,
    monitor_filter.MIN_HZ, monitor_filter.MAX_HZ))
  if hz >= 1000 then
    local khz = hz / 1000
    if hz % 1000 == 0 then return string.format("%d kHz", khz) end
    if hz % 100 == 0 then return string.format("%.1f kHz", khz) end
    return string.format("%d Hz", hz)
  end
  return string.format("%d Hz", hz)
end

-- One line keeps the preference inspectable in Reaper's ini. On/off is omitted
-- so every launch starts dry even if the previous session ended unexpectedly.
function monitor_filter.encode(value)
  value = monitor_filter.normalise(value)
  -- Keep the previous four-part shape so existing preferences and older copies
  -- remain readable. The retired mode slot is always written as band isolation.
  return table.concat({ "band", value.low_hz, value.high_hz, value.slope }, "|")
end

function monitor_filter.decode(text)
  if type(text) ~= "string" then return monitor_filter.defaults() end
  local legacy_mode, low_hz, high_hz, slope = text:match(
    "^([a-z_]+)|([%d%.]+)|([%d%.]+)|([%d%.]+)$")
  if not LEGACY_MODE[legacy_mode] then return monitor_filter.defaults() end
  low_hz, high_hz, slope = tonumber(low_hz), tonumber(high_hz), tonumber(slope)
  if not VALID_SLOPE[slope] or not low_hz or not high_hz
    or low_hz < monitor_filter.MIN_HZ or low_hz > monitor_filter.MAX_HZ
    or high_hz < monitor_filter.MIN_HZ or high_hz > monitor_filter.MAX_HZ then
    return monitor_filter.defaults()
  end
  if legacy_mode == "band" and high_hz < low_hz + 1 then
    return monitor_filter.defaults()
  end
  if legacy_mode == "below" then low_hz = monitor_filter.MIN_HZ end
  if legacy_mode == "above" then high_hz = monitor_filter.MAX_HZ end
  local result = monitor_filter.normalise({
    low_hz = low_hz,
    high_hz = high_hz,
    slope = slope,
  })
  result.on = false
  return result
end

function monitor_filter.full(value)
  local result = monitor_filter.normalise(value)
  result.on, result.selected_id = false, nil
  return result
end

function monitor_filter.parse_frequency(text)
  local number, suffix
  if type(text) == "number" then number, suffix = finite(text), ""
  elseif type(text) == "string" then
    number, suffix = text:lower():match("^%s*(%d*%.?%d+)%s*([a-z]*)%s*$")
    number = finite(number)
  end
  if not number or (suffix ~= "" and suffix ~= "hz" and suffix ~= "k" and suffix ~= "khz") then
    return nil, "Enter a frequency in Hz or kHz."
  end
  if suffix == "k" or suffix == "khz" then number = number * 1000 end
  if number < 10 or number > 20000 then return nil, "Enter a frequency from 10 to 20000 Hz." end
  return rounded_hz(number)
end

function monitor_filter.validate_range(low, high)
  local low_hz, low_error = monitor_filter.parse_frequency(low)
  if not low_hz then return nil, low_error end
  local high_hz, high_error = monitor_filter.parse_frequency(high)
  if not high_hz then return nil, high_error end
  if high_hz < low_hz + 1 then
    if low_hz >= 20000 then return nil, "Low must be 19999 Hz or lower." end
    return nil, string.format("High must be at least %d Hz.", low_hz + 1)
  end
  return { low_hz = low_hz, high_hz = high_hz }
end

function monitor_filter.set_range(value, low, high)
  local range, err = monitor_filter.validate_range(low, high)
  if not range then return nil, err end
  local result = monitor_filter.normalise(value)
  result.low_hz, result.high_hz = range.low_hz, range.high_hz
  result.on, result.selected_id = true, nil
  return result
end

function monitor_filter.edit_preset(value, id, low, high)
  if not PRESET_BY_ID[id] then return nil, "Unknown filter preset." end
  local range, err = monitor_filter.validate_range(low, high)
  if not range then return nil, err end
  local result = monitor_filter.normalise(value)
  result.presets[id] = range
  if result.on and result.selected_id == id then
    result.low_hz, result.high_hz = range.low_hz, range.high_hz
  end
  return result
end

function monitor_filter.restore_preset(value, id)
  local preset = PRESET_BY_ID[id]
  if not preset then return nil, "Unknown filter preset." end
  return monitor_filter.edit_preset(value, id, preset.low_hz, preset.high_hz)
end

function monitor_filter.preset_changed(value, id)
  local original = PRESET_BY_ID[id]
  local current = value and value.presets and value.presets[id]
  return original ~= nil and current ~= nil
    and (original.low_hz ~= current.low_hz or original.high_hz ~= current.high_hz)
end

-- Stored records omit live activation and selected identity. Invalid records
-- return an error so callers can leave the original preference untouched.
function monitor_filter.encode_preferences(value)
  local result = monitor_filter.normalise(value)
  return json.encode({ version = 1, low_hz = result.low_hz, high_hz = result.high_hz,
    slope = result.slope, presets = result.presets })
end

function monitor_filter.decode_preferences(text)
  if text == nil or text == "" then return monitor_filter.defaults() end
  if type(text) ~= "string" then return nil, "Saved filter settings are invalid." end
  if text:match("^[a-z]+|") then
    local mode, low, high, slope = text:match("^([a-z]+)|([%d%.]+)|([%d%.]+)|([%d%.]+)$")
    if not LEGACY_MODE[mode] or not VALID_SLOPE[tonumber(slope)] then
      return nil, "Saved filter settings are invalid."
    end
    low, high = tonumber(low), tonumber(high)
    if not low or not high or low < 10 or low > 20000 or high < 10 or high > 20000 then
      return nil, "Saved filter settings are invalid."
    end
    low = mode == "below" and 10 or low
    high = mode == "above" and 20000 or high
    if not monitor_filter.validate_range(low, high) then return nil, "Saved filter settings are invalid." end
    return monitor_filter.full({low_hz=low, high_hz=high, slope=tonumber(slope)})
  end
  local ok, data = pcall(json.decode, text)
  if not ok or type(data) ~= "table" then return nil, "Saved filter settings are invalid." end
  if data.version ~= 1 then return nil, "Saved filter settings use an unsupported version." end
  if not VALID_SLOPE[data.slope] or not monitor_filter.validate_range(data.low_hz, data.high_hz)
    or type(data.presets) ~= "table" then return nil, "Saved filter settings are invalid." end
  for _, preset in ipairs(monitor_filter.PRESETS) do
    local entry = data.presets[preset.id]
    if type(entry) ~= "table" or not monitor_filter.validate_range(entry.low_hz, entry.high_hz) then
      return nil, "Saved filter presets are invalid."
    end
  end
  return monitor_filter.full(data)
end

return monitor_filter
