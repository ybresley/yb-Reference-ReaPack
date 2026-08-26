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

function pitch.format(value)
  value = pitch.clamp(value)
  if math.abs(value) < 0.0005 then return "0.0 st" end
  return string.format("%+.1f st", value)
end

return pitch
