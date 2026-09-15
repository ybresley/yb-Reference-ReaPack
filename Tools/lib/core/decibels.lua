local decibels = {}

-- A tapered control can reserve its bottom endpoint for silence. Ordinary
-- numeric readings keep their finite value, even at the same number.
function decibels.format(db, silence_at)
  if silence_at and db <= silence_at then return "-inf" end
  local rounded = math.floor(db * 10 + 0.5) / 10
  if rounded == 0 then return "0.0" end
  return string.format("%+.1f", rounded)
end

return decibels
