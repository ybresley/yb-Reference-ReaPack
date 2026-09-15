-- Silent presentation steps. Applying a step never changes the live filter.
local demo = { settings_at = 6.95, duration = 15.31 }
local steps = {
  { at = 0, target = 'bass', travel = .4 },
  { at = 0.45, click = true, preset = 'bass', on = true, low = 10, high = 250 },
  { at = 1.95, click = true, preset = false, on = false, low = 10, high = 20000 },
  { at = 2.15, target = 'mid', travel = .4 },
  { at = 2.6, click = true, preset = 'mid', on = true, low = 700, high = 3000 },
  { at = 4.1, target = 'low_handle', travel = .45 },
  { at = 4.6, click = true, held = true },
  { at = 4.7, target = 'low_dragged', travel = .65, drag = 'low', preset = false },
  { at = 5.35, low = 180, drag = false, held = false },
  { at = 5.55, target = 'high_handle', travel = .4 },
  { at = 6, click = true, held = true },
  { at = 6.1, target = 'high_dragged', travel = .65, drag = 'high' },
  { at = 6.75, high = 6000, drag = false, held = false },
}

function demo.sample(elapsed, out)
  out = out or {}
  for key in pairs(out) do out[key] = nil end
  local phase = math.max(0, elapsed) % demo.duration
  out.on, out.preset = false, false
  out.low, out.high = 10, 20000
  out.settings_phase = phase >= demo.settings_at and phase - demo.settings_at or nil
  local target, from, start, travel = 'home', 'home', 0, 0
  local click_at
  for _, step in ipairs(steps) do
    if phase < step.at then break end
    if step.target then
      from, target, start, travel = target, step.target, step.at, step.travel
      click_at = nil
    end
    if step.click then click_at = step.at end
    for key, value in pairs(step) do
      if key ~= 'target' and key ~= 'travel' and key ~= 'at' and key ~= 'click' then
        out[key] = value
      end
    end
  end
  out.from, out.target = from, target
  out.progress = travel > 0 and math.min(1, (phase - start) / travel) or 1
  -- Frequency is logarithmic on the graph, so the boundary follows the arrow.
  local amount = out.progress * out.progress * (3 - 2 * out.progress)
  if out.drag == 'low' then out.low = 700 * (180 / 700) ^ amount end
  if out.drag == 'high' then out.high = 3000 * (6000 / 3000) ^ amount end
  out.pulse = click_at and phase - click_at < 0.55 and (phase - click_at) / 0.55 or nil
  return out
end

return demo
