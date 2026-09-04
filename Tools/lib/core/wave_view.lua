-- Pure viewport maths for the Reference View waveform.
-- Time is normalised to the file (0..1); amplitude is normalised to -1..1.

local view = {}

view.MIN_TIME_SPAN = 1 / 64
view.MIN_AMP_SPAN = 1 / 16

local function clamp(x, lo, hi)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

local function clamp_range(lo, hi, full_lo, full_hi, min_span)
  local full_span = full_hi - full_lo
  local span = clamp(hi - lo, min_span, full_span)
  local centre = (lo + hi) * 0.5
  lo, hi = centre - span * 0.5, centre + span * 0.5
  if lo < full_lo then lo, hi = full_lo, full_lo + span end
  if hi > full_hi then lo, hi = full_hi - span, full_hi end
  return lo, hi
end

function view.new()
  return { t0 = 0, t1 = 1, a0 = -1, a1 = 1 }
end

function view.copy(v)
  return { t0 = v.t0, t1 = v.t1, a0 = v.a0, a1 = v.a1 }
end

function view.set_time(v, t0, t1)
  v.t0, v.t1 = clamp_range(t0, t1, 0, 1, view.MIN_TIME_SPAN)
  return v
end

function view.set_amp(v, a0, a1)
  v.a0, v.a1 = clamp_range(a0, a1, -1, 1, view.MIN_AMP_SPAN)
  return v
end

function view.zoom_time(v, scale, anchor)
  if not scale or scale <= 0 then return v end
  local old_span = v.t1 - v.t0
  local new_span = clamp(old_span / scale, view.MIN_TIME_SPAN, 1)
  anchor = clamp(anchor or (v.t0 + v.t1) * 0.5, v.t0, v.t1)
  local relative = old_span > 0 and (anchor - v.t0) / old_span or 0.5
  return view.set_time(v, anchor - relative * new_span,
    anchor + (1 - relative) * new_span)
end

function view.pan_time(v, delta)
  return view.set_time(v, v.t0 + delta, v.t1 + delta)
end

function view.zoom_amp(v, scale, anchor)
  if not scale or scale <= 0 then return v end
  local old_span = v.a1 - v.a0
  local new_span = clamp(old_span / scale, view.MIN_AMP_SPAN, 2)
  anchor = anchor or (v.a0 + v.a1) * 0.5
  -- A named anchor outside the current view is still meaningful. Vertical
  -- waveform zoom names channel zero explicitly, so bring it back into view
  -- instead of silently substituting the nearest visible edge.
  if anchor < v.a0 or anchor > v.a1 then
    return view.set_amp(v, anchor - new_span * 0.5, anchor + new_span * 0.5)
  end
  local relative = old_span > 0 and (anchor - v.a0) / old_span or 0.5
  return view.set_amp(v, anchor - relative * new_span,
    anchor + (1 - relative) * new_span)
end

function view.pan_amp(v, delta)
  return view.set_amp(v, v.a0 + delta, v.a1 + delta)
end

function view.time_at(v, x_fraction)
  return v.t0 + clamp(x_fraction or 0, 0, 1) * (v.t1 - v.t0)
end

function view.x_of_time(v, time_fraction)
  local span = v.t1 - v.t0
  if span <= 0 then return 0 end
  return (time_fraction - v.t0) / span
end

function view.y_of_amp(v, amplitude)
  local span = v.a1 - v.a0
  if span <= 0 then return 0.5 end
  return (v.a1 - amplitude) / span
end

-- Divide a small overlay thumb into two resize ends and a draggable centre.
-- Shrinking the end zones with the thumb preserves all three actions even at
-- maximum zoom, where fixed grab zones would consume the entire thumb.
function view.thumb_part(position, start_pos, finish_pos, max_edge)
  if type(position) ~= "number" or type(start_pos) ~= "number"
    or type(finish_pos) ~= "number" or finish_pos <= start_pos
    or position < start_pos or position > finish_pos then return nil end
  local edge = math.min(math.max(0, max_edge or 0), (finish_pos - start_pos) / 3)
  if position - start_pos <= edge then return "start" end
  if finish_pos - position <= edge then return "finish" end
  return "body"
end

return view
