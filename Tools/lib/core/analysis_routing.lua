-- The selected speaker labels describe Monitor FX input lanes. Project sends
-- determine their sound, but do not decide whether those lanes can be measured.
local routing = {}

local function integer(value, minimum)
  return type(value) == 'number' and value < math.huge
    and value >= minimum and value == math.floor(value)
end

function routing.check(count, outputs)
  if not integer(count, 1) or count > 8 or not integer(outputs, 0) or outputs > 128 then
    return nil, 'routing_unknown'
  end
  if outputs < count then return nil, 'outputs_unavailable' end
  return true
end

return routing
