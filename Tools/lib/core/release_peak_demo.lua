-- The guide pointer owns this silent demonstration, independently of live input.
local demo = { duration = 5.5 }

local function move(from, to, amount)
  return from + (to - from) * amount * amount * (3 - 2 * amount)
end

function demo.pointer(elapsed, gx, gy, gw, gh, ruler_height)
  local phase = elapsed % demo.duration
  local home_x, home_y = gx + gw * .84, gy + gh + ruler_height * .55
  local target_x, target_y = gx + gw * .55, gy + gh * .34
  local x, y
  if phase < .8 then
    x, y = move(home_x, target_x, phase / .8), move(home_y, target_y, phase / .8)
  elseif phase < 4.65 then
    x, y = target_x, target_y
  elseif phase < 5.25 then
    local amount = (phase - 4.65) / .6
    x, y = move(target_x, home_x, amount), move(target_y, home_y, amount)
  else
    x, y = home_x, home_y
  end
  return x >= gx and x <= gx + gw and y >= gy and y <= gy + gh, x, y
end

return demo
