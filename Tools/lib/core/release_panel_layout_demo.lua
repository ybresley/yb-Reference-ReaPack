-- Silent release examples use fixed map slots; labels can change without
-- moving the guide's target during a drag.
local demo = {}

local durations = {layout_overview=8, layout_settings=28.5}

local function ease(value)
  value = math.max(0, math.min(1, value))
  return value * value * (3 - 2 * value)
end

local function travel(out, from, to, phase, start, duration)
  out.from, out.to = from, to
  out.progress = from == to and 1 or ease((phase-start)/duration)
end

function demo.duration(topic)
  assert(durations[topic], 'Unknown panel layout demo topic.')
  return durations[topic]
end

function demo.sample(topic, elapsed, out)
  local duration = demo.duration(topic)
  out = out or {}
  for key in pairs(out) do out[key] = nil end
  local time = tonumber(elapsed) or 0
  if time ~= time or math.abs(time) == math.huge then time = 0 end
  local phase = math.max(0, time) % duration
  out.phase = phase
  out.swapped = topic == 'layout_settings' and phase >= 2.9 and phase < 25.8
  out.spectrum_visible = not (topic == 'layout_settings' and phase >= 5.7 and phase < 7.4)
  out.width, out.height = 640, 520

  if topic == 'layout_overview' then
    out.pointer = false
    return out
  end

  out.pointer = true
  out.dragging = phase >= 1.4 and phase < 2.9 or phase >= 24.3 and phase < 25.8
  out.resizing = phase >= 10 and phase < 11.6 or phase >= 13.2 and phase < 14.8
    or phase >= 17 and phase < 18.6 or phase >= 20.2 and phase < 21.8
  out.resize_axis = phase >= 9.7 and phase < 16 and 'y'
    or phase >= 16.8 and phase < 23 and 'x' or nil
  out.held = out.dragging or out.resizing
  if phase >= 10 and phase < 11.6 then out.height = 520-240*ease((phase-10)/1.6)
  elseif phase >= 11.6 and phase < 13.2 then out.height = 280
  elseif phase >= 13.2 and phase < 14.8 then out.height = 280+240*ease((phase-13.2)/1.6) end
  if phase >= 17 and phase < 18.6 then out.width = 640-250*ease((phase-17)/1.6)
  elseif phase >= 18.6 and phase < 20.2 then out.width = 390
  elseif phase >= 20.2 and phase < 21.8 then out.width = 390+250*ease((phase-20.2)/1.6) end

  if phase < .3 then travel(out,'home','home',phase,0,1)
  elseif phase < 1.1 then travel(out,'home','top',phase,.3,.8)
  elseif phase < 1.4 then travel(out,'top','top',phase,1.1,1)
  elseif phase < 2.9 then travel(out,'top','bottom',phase,1.4,1.5)
  elseif phase < 4.8 then travel(out,'bottom','bottom',phase,2.9,1)
  elseif phase < 5.5 then travel(out,'bottom','toggle_spectrum',phase,4.8,.7)
  elseif phase < 8.8 then travel(out,'toggle_spectrum','toggle_spectrum',phase,5.5,1)
  elseif phase < 9.7 then travel(out,'toggle_spectrum','bottom_edge',phase,8.8,.9)
  elseif phase < 16 then travel(out,'bottom_edge','bottom_edge',phase,9.7,1)
  elseif phase < 16.8 then travel(out,'bottom_edge','right_edge',phase,16,.8)
  elseif phase < 23 then travel(out,'right_edge','right_edge',phase,16.8,1)
  elseif phase < 24 then travel(out,'right_edge','bottom',phase,23,1)
  elseif phase < 24.3 then travel(out,'bottom','bottom',phase,24,1)
  elseif phase < 25.8 then travel(out,'bottom','top',phase,24.3,1.5)
  elseif phase < 27.3 then travel(out,'top','top',phase,25.8,1)
  elseif phase < 28.1 then travel(out,'top','home',phase,27.3,.8)
  else travel(out,'home','home',phase,28.1,1) end

  for _, release in ipairs({2.9,5.7,7.4,11.6,14.8,18.6,21.8,25.8}) do
    if phase >= release and phase < release+.25 then out.pulse=(phase-release)/.25 end
  end
  return out
end

return demo
