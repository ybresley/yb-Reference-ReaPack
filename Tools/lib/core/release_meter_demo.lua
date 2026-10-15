-- A silent guide to the meter display. The points name controls, not screen pixels.
local demo = {}
local durations = { meter_overview = 4.8, meter_customization = 13.5 }
local reading_fields = { 'm', 's', 'i', 'rms_l', 'rms_r', 'peak_l', 'peak_r', 'tp_max' }
local customization_clicks = {1.1, 3.7, 6.3, 7.8, 9.2, 11.8}

function demo.readings(signal, time, values)
  time = math.max(0, math.min(signal.duration, time))
  local points = signal.points
  local low, high = 0, #points
  while low < high do
    local middle = (low + high + 1) // 2
    if points[middle].t <= time + 1e-9 then low = middle else high = middle - 1 end
  end
  local point = points[low]
  for _, key in ipairs(reading_fields) do values[key] = point and point[key] end
  -- The moving peak has its own sample-rate release envelope. Read its finer
  -- snapshots without advancing the measured numbers or history into the future.
  local peaks = signal.live_peaks
  local index = math.min(#peaks.l, math.floor(time / peaks.step + 1e-9))
  values.live_peak_l, values.live_peak_r = peaks.l[index], peaks.r[index]
  return low, point
end

-- The recording has 100 ms history points. Advance the visible end of the
-- example between them while leaving the recorded readings untouched.
function demo.history_tip(signal, time, index, out)
  local before, after = signal.points[index], signal.points[index + 1]
  if not before or not after or time <= before.t or time >= after.t then return nil end
  out = out or {}
  local fraction = (time - before.t) / (after.t - before.t)
  out.t = time
  for _, key in ipairs({'m', 's', 'i'}) do
    local a, b = before[key], after[key]
    out[key] = a and b and a + (b - a) * fraction or nil
  end
  return out
end

function demo.duration(topic)
  return durations[topic] or durations.meter_overview
end

local function ease(value)
  value = math.max(0, math.min(1, value))
  return value * value * (3 - 2 * value)
end

local function travel(from, to, elapsed, start, duration, out)
  out.from, out.to = from, to
  out.progress = from == to and 1 or ease((elapsed - start) / duration)
end

function demo.sample(topic, elapsed, out)
  out = out or {}
  for key in pairs(out) do out[key] = nil end
  local phase = math.max(0, tonumber(elapsed) or 0) % demo.duration(topic)
  out.phase = phase
  if topic == 'meter_customization' then
    if phase < .9 then travel('home', 'extra_readings', phase, 0, .9, out)
    elseif phase < 2.6 then travel('extra_readings', 'extra_readings', phase, .9, 1, out)
    elseif phase < 3.5 then travel('extra_readings', 'show_lr', phase, 2.6, .9, out)
    elseif phase < 5.2 then travel('show_lr', 'show_lr', phase, 3.5, 1, out)
    elseif phase < 6.1 then travel('show_lr', 'section', phase, 5.2, .9, out)
    elseif phase < 6.7 then travel('section', 'section', phase, 6.1, 1, out)
    elseif phase < 7.6 then travel('section', 'section_loudness', phase, 6.7, .9, out)
    elseif phase < 8.1 then travel('section_loudness', 'section_loudness', phase, 7.6, 1, out)
    elseif phase < 9 then travel('section_loudness', 'show_target', phase, 8.1, .9, out)
    elseif phase < 10.7 then travel('show_target', 'show_target', phase, 9, 1, out)
    elseif phase < 11.6 then travel('show_target', 'show_i', phase, 10.7, .9, out)
    else travel('show_i', 'show_i', phase, 11.6, 1, out) end
    out.extra_readings = phase >= 1.1
    out.show_lr = phase < 3.7
    out.show_target = phase >= 9.2
    out.show_i = phase < 11.8
    out.settings_page = phase >= 7.8 and 2 or 1
    out.section_open = phase >= 6.3 and phase < 7.8
    out.section_select = phase >= 7.8 and phase < 8.1 and 2 or nil
    for _, click in ipairs(customization_clicks) do
      if phase >= click and phase < click + .3 then out.pulse = (phase-click)/.3 end
    end
  else
    -- Overview is a moving meter, with no artificial pointer gesture.
    out.from, out.to, out.progress = nil, nil, 1
  end
  return out
end

return demo
