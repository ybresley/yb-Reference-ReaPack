-- Adaptive ruler ticks for the Reference View waveform's visible time range.

local ruler = {}

local EPS = 1e-9
local LABEL_PAD_PX = 12
local TARGET_MAJOR_GAP_PX = 90
local MIN_MINOR_GAP_PX = 4

local function decimal_places(step)
  if step >= 1 then return 0 end
  return math.min(6, math.max(1,
    math.ceil(-math.log(step) / math.log(10) - EPS)))
end

function ruler.format_label(seconds, step)
  local places = decimal_places(step)
  local scale = 10 ^ places
  local rounded = math.floor(math.max(0, seconds) * scale + 0.5) / scale
  if rounded == 0 then return "0" end
  if rounded < 60 then return string.format("%." .. places .. "f", rounded) end
  if rounded < 3600 then
    local minutes = math.floor(rounded / 60)
    local remaining = rounded - minutes * 60
    local width = places > 0 and 3 + places or 2
    return string.format("%d:%0" .. width .. "." .. places .. "f", minutes, remaining)
  end
  local hours = math.floor(rounded / 3600)
  local remaining = rounded - hours * 3600
  local minutes = math.floor(remaining / 60)
  local seconds_in_minute = remaining - minutes * 60
  local width = places > 0 and 3 + places or 2
  return string.format("%d:%02d:%0" .. width .. "." .. places .. "f",
    hours, minutes, seconds_in_minute)
end

local function nice_step_at_least(raw)
  local exponent = math.floor(math.log(raw) / math.log(10))
  local scale = 10 ^ exponent
  local normalised = raw / scale
  if normalised <= 1 + EPS then return scale, 5 end
  if normalised <= 2 + EPS then return 2 * scale, 4 end
  if normalised <= 5 + EPS then return 5 * scale, 5 end
  return 10 * scale, 5
end

local function label_left(x, label_width, width)
  return math.max(0, math.min(x - label_width * 0.5, math.max(0, width - label_width)))
end

local function tick_label(time, step, is_last)
  local label = ruler.format_label(time, step)
  if is_last and label ~= "0" then
    local _, colons = label:gsub(":", "")
    label = label .. (colons == 2 and " h" or colons == 1 and " m" or " s")
  end
  return label
end

local function labels_fit(start_time, finish_time, width, step, measure)
  local span = finish_time - start_time
  local first = math.ceil(start_time / step - EPS)
  local last = math.floor(finish_time / step + EPS)
  local previous_right
  for index = first, last do
    local time = index * step
    local x = (time - start_time) / span * width
    local label = tick_label(time, step, index == last)
    local label_width = measure(label)
    local left = label_left(x, label_width, width)
    if previous_right and left < previous_right + LABEL_PAD_PX then return false end
    previous_right = left + label_width
  end
  return true
end

local function choose_step(start_time, finish_time, width, measure)
  local span = finish_time - start_time
  local step, divisions = nice_step_at_least(span / math.max(1, width / TARGET_MAJOR_GAP_PX))
  for _ = 1, 16 do
    if labels_fit(start_time, finish_time, width, step, measure) then return step, divisions end
    step, divisions = nice_step_at_least(step * 1.01)
  end
  return step, divisions
end

function ruler.build(start_time, finish_time, width, measure)
  if type(start_time) ~= "number" or type(finish_time) ~= "number"
    or finish_time <= start_time or type(width) ~= "number" or width <= 0
    or type(measure) ~= "function" then return {} end

  local span = finish_time - start_time
  local major_step, divisions = choose_step(start_time, finish_time, width, measure)
  local minor_step = major_step / divisions
  local tick_step = (minor_step / span * width >= MIN_MINOR_GAP_PX) and minor_step or major_step
  local first = math.ceil(start_time / tick_step - EPS)
  local last = math.floor(finish_time / tick_step + EPS)
  local ticks, previous_label_right = {}
  for index = first, last do
    local time = index * tick_step
    local major_index = math.floor(time / major_step + 0.5)
    local is_major = math.abs(time - major_index * major_step) <= major_step * EPS
    local x = (time - start_time) / span * width
    local tick = { x = x, time = time, major = is_major }
    if is_major then
      local label = tick_label(time, major_step,
        major_index == math.floor(finish_time / major_step + EPS))
      local label_width = measure(label)
      local left = label_left(x, label_width, width)
      if not previous_label_right or left >= previous_label_right + LABEL_PAD_PX then
        tick.label, tick.label_x = label, left
        previous_label_right = left + label_width
      end
    end
    ticks[#ticks + 1] = tick
  end
  return ticks
end

return ruler
