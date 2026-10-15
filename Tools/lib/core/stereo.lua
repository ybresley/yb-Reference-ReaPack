local stereo = {}

-- Normal-rate packets cover 1/30 second. Retain the six-second blue trail;
-- exceptionally high rates can reuse the bounded history sooner.
local MAX_LAYERS = 192
local MAX_POINTS = 8192
local VISIBLE_OPACITY = 1 / 255
local VISIBLE_SECONDS = 6
local BRIGHT_HOLD_SECONDS = 0.06
-- A brief highlight distinguishes fresh dots. Most brightness belongs to the
-- slower path fade, so losing the highlight does not leave only a dim cloud.
local BRIGHT_RELEASE_SECONDS = 0.03
local PATH_RELEASE_SECONDS = 0.65
local TRAIL_RELEASE_SECONDS = 1.8
local BRIGHT_WEIGHT = 0.4
local TRAIL_WEIGHT = 0.1
local CLIP_HOLD_SECONDS = 2
local LOG_CURVE = 10000
local LOG_DIVISOR = math.log(1 + LOG_CURVE)
local MAX_DISPLAY_GAIN = 10 ^ (42 / 20)
local TRAIL_SECONDS = {short = 2, medium = 4, long = 6}
local CLIP_BINS = 2048
local CORRELATION_SECONDS = 0.3

-- A millisecond table avoids exponentials for every visible pixel on every
-- redraw. Interpolation keeps the fade continuous between table entries.
local OPACITY_STEPS_PER_SECOND = 1000
local opacity_curve = {}
for step = 0, VISIBLE_SECONDS * OPACITY_STEPS_PER_SECOND do
  local age = step / OPACITY_STEPS_PER_SECOND
  local fading_age = math.max(0, age - BRIGHT_HOLD_SECONDS)
  opacity_curve[step] = (BRIGHT_WEIGHT * math.exp(-fading_age / BRIGHT_RELEASE_SECONDS)
    + (1 - BRIGHT_WEIGHT - TRAIL_WEIGHT) * math.exp(-fading_age / PATH_RELEASE_SECONDS)
    + TRAIL_WEIGHT * math.exp(-fading_age / TRAIL_RELEASE_SECONDS))
    * math.min(1, (VISIBLE_SECONDS - age) / 0.3)
end

local function finite(value)
  return type(value) == 'number' and value == value and math.abs(value) < math.huge
end

local function clear(state)
  for i = 1, MAX_LAYERS do
    state.layers[i].count = 0
  end
  state.head = 0
  state.last_sequence = nil
  state.display_gain, state.overflow_clip, state.overrun_until = nil, nil, nil
  state.held_clips = {lissajous = {}, polar_sample = {}}
  state.frozen, state.frozen_at, state.resume_at = false, nil, nil
end

function stereo.new()
  local state = { layers = {}, head = 0, last_sequence = nil, capture_id = 0,
    source_key = nil, epoch = nil, session = nil, playing = false,
    status = 'waiting', frozen = false,
    held_clips = {lissajous = {}, polar_sample = {}} }
  for i = 1, MAX_LAYERS do
    state.layers[i] = { left = {}, right = {}, polar_x = {}, polar_y = {},
      lissajous_x = {}, lissajous_y = {},
      clip_indices = {}, clip_count = 0, count = 0, at = 0 }
  end
  return state
end

function stereo.reset(state)
  clear(state)
  state.status = 'waiting'
end

function stereo.clear_display(state)
  -- Preserve the last sequence and display gain: clearing the picture must not
  -- replay the latest packet or change the scale of the next captured tail.
  for i = 1, MAX_LAYERS do
    state.layers[i].count = 0
    state.layers[i].clip_count = 0
  end
  state.head = 0
  state.overflow_clip = nil
  state.held_clips = {lissajous = {}, polar_sample = {}}
end

function stereo.display_time(state, now)
  return state.frozen and state.frozen_at or now
end

function stereo.set_frozen(state, frozen, now)
  frozen = frozen == true
  now = finite(now) and now or state.now or 0
  if frozen == state.frozen then return end
  if frozen then
    state.frozen, state.frozen_at = true, now
  else
    local elapsed = math.max(0, now - state.frozen_at)
    for _, layer in ipairs(state.layers) do layer.at = layer.at + elapsed end
    for _, view in pairs(state.held_clips) do
      for _, clip in pairs(view) do clip.at = clip.at + elapsed end
    end
    if state.overflow_clip then state.overflow_clip.at = state.overflow_clip.at + elapsed end
    state.frozen, state.frozen_at, state.resume_at = false, nil, now
    return elapsed
  end
end

local function retain_clip(state, left, right, at)
  local x, y = stereo.point(left, right)
  local angle = math.atan(y, x)
  local bin = math.min(CLIP_BINS - 1, math.floor((angle + math.pi) / (2 * math.pi) * CLIP_BINS))
  local held = state.held_clips.lissajous[bin] or {}
  held.x, held.y, held.at = x, y, at
  state.held_clips.lissajous[bin] = held
  x, y = stereo.polar_point(left, right)
  bin = math.min(CLIP_BINS - 1, math.floor(math.atan(y, x) / math.pi * CLIP_BINS))
  held = state.held_clips.polar_sample[bin] or {}
  held.x, held.y, held.at = x, y, at
  state.held_clips.polar_sample[bin] = held
end

-- Each layer contains only samples received from the helper. Time controls
-- brightness, never synthesised positions or interpolated audio.
local function update_frame(state, frame, context)
  context = context or {}
  local now = finite(context.now) and context.now or 0
  state.now = now
  local source_changed = state.source_key ~= context.source_key
  local session_changed = context.session and state.session ~= context.session
  local resumed_epoch = context.playing and state.epoch ~= context.epoch
  if source_changed or session_changed or resumed_epoch then clear(state) end
  if context.status == 'unavailable' or context.status == 'invalid' then clear(state) end
  state.source_key, state.epoch, state.session =
    context.source_key, context.epoch, context.session
  state.playing = context.playing == true
  state.status = context.status or 'waiting'
  if not frame or (not state.playing and not frame.final and not finite(frame.at))
      or frame.sequence == state.last_sequence then return end
  local count = frame.count
  if not finite(count) or count < 1 or count > MAX_POINTS or count % 1 ~= 0
      or frame.epoch ~= state.epoch
      or (state.session and frame.session ~= state.session) then return end
  local left, right = frame.left, frame.right
  if type(left) ~= 'table' or type(right) ~= 'table' then return end
  for i = 1, count do
    if not finite(left[i]) or not finite(right[i]) then return end
  end
  if state.frozen or (state.resume_at and finite(frame.at) and frame.at < state.resume_at) then
    state.last_sequence = frame.sequence
    return
  end
  local head = state.head % MAX_LAYERS + 1
  local layer = state.layers[head]
  layer.clip_count, layer.peak = 0, 0
  for i = 1, count do
    layer.left[i], layer.right[i] = left[i], right[i]
    layer.peak = math.max(layer.peak, math.abs(left[i]), math.abs(right[i]))
    -- Captured samples do not move. Project once for both scope views;
    -- only brightness and panel dimensions change during subsequent drawing.
    local x, y, clipped = stereo.polar_point(left[i], right[i])
    layer.polar_x[i], layer.polar_y[i] = x, y
    layer.lissajous_x[i], layer.lissajous_y[i] = stereo.point(left[i], right[i])
    if clipped then
      layer.clip_count = layer.clip_count + 1
      layer.clip_indices[layer.clip_count] = i
    end
  end
  state.capture_id = state.capture_id + 1
  layer.capture_id = state.capture_id
  layer.count, layer.at = count, finite(frame.at) and math.min(now, frame.at) or now
  layer.sample_rate = finite(frame.sample_rate) and frame.sample_rate > 0
    and frame.sample_rate or nil
  local interval = layer.sample_rate and 1 / layer.sample_rate or 0
  for i = 1, layer.clip_count do
    local index = layer.clip_indices[i]
    retain_clip(state, left[index], right[index], layer.at - (count - index) * interval)
  end
  -- Scale before squaring so valid very quiet or over-range samples cannot
  -- underflow or overflow the correlation calculation.
  layer.energy_left, layer.energy_right, layer.energy_cross = 0, 0, 0
  if layer.peak > 0 then
    for i = 1, count do
      local l, r = left[i] / layer.peak, right[i] / layer.peak
      layer.energy_left = layer.energy_left + l * l
      layer.energy_right = layer.energy_right + r * r
      layer.energy_cross = layer.energy_cross + l * r
    end
  end
  if finite(frame.missed_packets) and frame.missed_packets > 0 then
    state.overrun_until = now + 3
    local clip = frame.overflow_clip
    if clip and finite(clip.left) and finite(clip.right) and finite(clip.at)
        and (math.abs(clip.left) >= 1 or math.abs(clip.right) >= 1) then
      local held = state.overflow_clip or {}
      held.left, held.right, held.at = clip.left, clip.right, math.min(now, clip.at)
      state.overflow_clip = held
      retain_clip(state, clip.left, clip.right, held.at)
    end
  end
  state.head, state.last_sequence, state.status = head, frame.sequence, 'ready'
  return layer
end

local fade_cache, fade_order = {}, {}

function stereo.fade_curve(prefs)
  if not prefs or (prefs.brightness == 1 and prefs.history == 1 and prefs.trail == 'long') then
    return opacity_curve
  end
  local brightness, history = prefs.brightness or 1, prefs.history or 1
  local duration = TRAIL_SECONDS[prefs.trail] or VISIBLE_SECONDS
  local key = brightness .. ':' .. history .. ':' .. duration
  if fade_cache[key] then return fade_cache[key] end
  local curve = {}
  for index = 0, VISIBLE_SECONDS * OPACITY_STEPS_PER_SECOND do
    local age = index / OPACITY_STEPS_PER_SECOND
    -- Trail length changes the history fade, never the brief live highlight.
    if duration ~= VISIBLE_SECONDS and age > BRIGHT_HOLD_SECONDS then
      age = BRIGHT_HOLD_SECONDS + (age - BRIGHT_HOLD_SECONDS)
        * (VISIBLE_SECONDS - BRIGHT_HOLD_SECONDS) / (duration - BRIGHT_HOLD_SECONDS)
    end
    if age >= VISIBLE_SECONDS then curve[index] = 0
    else
      local position = age * OPACITY_STEPS_PER_SECOND
      local step = math.floor(position)
      local start = opacity_curve[step]
      local value = start + (opacity_curve[step + 1] - start) * (position - step)
      local history_blend = math.min(1, math.max(0, age - BRIGHT_HOLD_SECONDS) / 0.12)
      curve[index] = math.min(1, value * brightness * (1 + (history - 1) * history_blend))
    end
  end
  if #fade_order >= 4 then fade_cache[table.remove(fade_order, 1)] = nil end
  fade_order[#fade_order + 1], fade_cache[key] = key, curve
  return curve
end

function stereo.opacity_at(at, now, prefs, curve)
  local age = math.max(0, now - at)
  if age >= VISIBLE_SECONDS then return 0 end
  -- Allow for both the age spread inside a 33 ms packet and its wait for the
  -- next packet. A steady signal must not dim and relight between updates.
  local position = age * OPACITY_STEPS_PER_SECOND
  local step = math.floor(position)
  curve = curve or stereo.fade_curve(prefs)
  local start = curve[step]
  return start + (curve[step + 1] - start) * (position - step)
end

function stereo.opacity(layer, now, prefs)
  if layer.count == 0 then return 0 end
  return stereo.opacity_at(layer.at, now, prefs)
end

function stereo.clip_visible(layer, now, prefs)
  if prefs and prefs.show_clipping == false then return false end
  local hold = prefs and prefs.clip_hold or CLIP_HOLD_SECONDS
  return layer.count > 0 and layer.clip_count > 0
    and (hold == 0 or math.max(0, now - layer.at) < hold)
end

function stereo.overflow_clip_visible(state, now, prefs)
  if prefs and prefs.show_clipping == false then return false end
  local hold = prefs and prefs.clip_hold or CLIP_HOLD_SECONDS
  return state.overflow_clip ~= nil
    and (hold == 0 or math.max(0, now - state.overflow_clip.at) < hold)
end

function stereo.correlation(state, now)
  now = stereo.display_time(state, finite(now) and now or state.now or 0)
  local scale, left, right, cross = 0, 0, 0, 0
  for _, layer in ipairs(state.layers) do
    if layer.count > 0 and layer.at <= now and now - layer.at < CORRELATION_SECONDS
        and layer.peak and layer.peak > 0 and layer.energy_left then
      if layer.peak > scale then
        local factor = (scale / layer.peak) ^ 2
        left, right, cross = left * factor, right * factor, cross * factor
        scale = layer.peak
      end
      local factor = (layer.peak / scale) ^ 2
      left = left + layer.energy_left * factor
      right = right + layer.energy_right * factor
      cross = cross + layer.energy_cross * factor
    end
  end
  if left <= 0 or right <= 0 then return nil end
  return math.max(-1, math.min(1, cross / math.sqrt(left) / math.sqrt(right)))
end

function stereo.display_level(level)
  if level <= 0 then return 0 end
  if level >= 1 then return 1 end
  local scaled = LOG_CURVE * level
  -- Lua has no log1p. This series preserves tiny levels that would round away
  -- in 1 + scaled, while meeting the ordinary logarithm smoothly.
  local value = scaled < 0.0001
    and scaled * (1 - scaled * 0.5 + scaled * scaled / 3)
    or math.log(1 + scaled)
  return value / LOG_DIVISOR
end

function stereo.update(state, frame, context)
  local captured = update_frame(state, frame, context)
  if not captured then return end
  local peak = captured.peak
  -- Scale the whole capture once, never individual points or existing history.
  -- A loud packet cannot suppress subsequent quiet packets, and history expiry
  -- cannot trigger enlargement. Full-scale samples retain their true boundary.
  if peak > 0 then
    local gain = peak >= 1 and 1
      or math.min(MAX_DISPLAY_GAIN, stereo.display_level(peak) / peak)
    -- A short final packet can contain only the quiet end of a waveform.
    -- Let it fade at the existing scale instead of zooming into that tail.
    if frame.final and state.display_gain then gain = math.min(gain, state.display_gain) end
    state.display_gain = gain
  end
  captured.display_gain = state.display_gain or 1
end

function stereo.point(left, right)
  -- A fixed rotation maps the +/-1 channel limits to a diamond. Saturate only
  -- display coordinates, before rotation, so over-range samples land on the
  -- correct channel edge without changing captured audio or the other channel.
  local clipped = math.abs(left) >= 1 or math.abs(right) >= 1
  local l = math.max(-1, math.min(1, left)) * 0.5
  local r = math.max(-1, math.min(1, right)) * 0.5
  return r - l, l + r, clipped
end

function stereo.polar_point(left, right)
  -- Radius measures channel peak level; angle retains the raw mid/side ratio.
  -- Normalise before the sum/difference to avoid overflow, then limit radius
  -- only: a channel reaching full scale must land on the arc, not a diamond.
  local peak = math.max(math.abs(left), math.abs(right))
  if peak == 0 then return 0, 0, false end
  local l, r = left / peak, right / peak
  local x, y = (r - l) * 0.5, (l + r) * 0.5
  local radial_scale = math.min(peak, 1) / math.sqrt(x * x + y * y)
  x, y = x * radial_scale, y * radial_scale
  -- Opposite halves of the waveform describe the same stereo position. Rotate
  -- negative mid samples into the upper half instead of discarding them.
  if y < 0 then return -x, -y, peak >= 1 end
  return x, y, peak >= 1
end

stereo.MAX_LAYERS = MAX_LAYERS
stereo.MAX_POINTS = MAX_POINTS
stereo.VISIBLE_OPACITY = VISIBLE_OPACITY
stereo.CLIP_BINS = CLIP_BINS

return stereo
