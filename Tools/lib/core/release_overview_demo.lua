-- The introduction runs once; replay returns from the ruler to the first frequency.
local mathx = require('core.spectrum_math')
local demo = { intro_duration = 1.9, duration = 11.9 }
local points = {
  { at = 0, hz = 400 },
  { at = 1.5, hz = 400 },
  { at = 2.7, hz = 1200 },
  { at = 4.2, hz = 1200 },
  { at = 5.3, hz = 1500, axis = true },
  { at = 10.8, hz = 300, axis = true },
  { at = 11.9, hz = 400 },
}

function demo.capture(model)
  local path = { fmin = model.fmin, fmax = model.fmax, heights = {} }
  -- Choose inspection positions once so the pointer does not follow the live trace.
  for _, mark in ipairs(points) do
    if not mark.axis and not path.heights[mark.hz] then
      local db = mathx.sample_log_values(model.live, model.count, mark.hz, model.fmin, model.fmax)
      db = mathx.tilted_db(db, mark.hz, model.prefs.tilt)
      path.heights[mark.hz] = mathx.db_fraction(db, 6, model.bottom)
    end
  end
  return path
end

local function point(mark, gx, gy, gw, gh, ruler_height, path)
  local x = gx + mathx.frequency_fraction(mark.hz, path.fmin, path.fmax) * gw
  if mark.axis then return x, gy + gh + ruler_height * .55 end
  return x, gy + path.heights[mark.hz] * gh
end

function demo.pointer(elapsed, gx, gy, gw, gh, ruler_height, path)
  elapsed = math.max(0, elapsed)
  local ax, ay, bx, by, amount
  if elapsed < demo.intro_duration then
    ax, ay = gx + gw + ruler_height * .4, gy + gh + ruler_height * .05
    bx, by = point(points[1], gx, gy, gw, gh, ruler_height, path)
    amount = math.max(0, (elapsed - .8) / (demo.intro_duration - .8))
  else
    local phase = (elapsed - demo.intro_duration) % demo.duration
    for index = 2, #points do
      local a, b = points[index - 1], points[index]
      if phase < b.at then
        ax, ay = point(a, gx, gy, gw, gh, ruler_height, path)
        bx, by = point(b, gx, gy, gw, gh, ruler_height, path)
        amount = (phase - a.at) / (b.at - a.at)
        break
      end
    end
  end
  amount = amount * amount * (3 - 2 * amount)
  local x, y = ax + (bx - ax) * amount, ay + (by - ay) * amount
  return x >= gx and x <= gx + gw and y >= gy and y < gy + gh, x, y
end

return demo
