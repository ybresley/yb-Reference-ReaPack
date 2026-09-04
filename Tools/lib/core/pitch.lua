-- pitch: the one rule shared by audition playback and timeline items.
-- User-facing values are semitones; REAPER's playback paths take a rate.

local pitch = {}

pitch.MIN = -24
pitch.MAX = 24

function pitch.clamp(value)
  value = tonumber(value) or 0
  if value ~= value then return 0 end -- NaN
  if value < pitch.MIN then return pitch.MIN end
  if value > pitch.MAX then return pitch.MAX end
  return value
end

function pitch.rate(value)
  return 2 ^ (pitch.clamp(value) / 12)
end

function pitch.unit(value)
  return value == "percent" and "percent" or "st"
end

function pitch.display(value, unit)
  return unit == "percent" and pitch.rate(value) * 100 or pitch.clamp(value)
end

function pitch.parse(text, unit)
  local value = tonumber(text)
  if not value or value ~= value then return nil end
  if unit == "percent" then
    value = math.max(25, math.min(400, value))
    return pitch.clamp(12 * math.log(value / 100, 2))
  end
  return pitch.clamp(math.floor(value * 10 + 0.5) / 10)
end

function pitch.format(value, unit)
  if unit == "percent" then return string.format("%.1f%%", pitch.display(value, unit)) end
  value = pitch.clamp(value)
  if math.abs(value) < 0.0005 then return "0.0 st" end
  return string.format("%+.1f st", value)
end

return pitch
