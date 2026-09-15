-- Small, pure timing state for controls that remain visible across frames.
-- A missed frame snaps to the live state so an old animation is never replayed
-- when a panel is shown again.

local motion = {}

local function clamp(value, low, high)
  if value < low then return low end
  if value > high then return high end
  return value
end

local function smoothstep(t)
  return t * t * (3 - 2 * t)
end

local function ease_out(t)
  local remaining = 1 - t
  return 1 - remaining * remaining * remaining
end

-- CSS cubic-bezier(.4, 0, .2, 1). CSS defines progress by the curve's x axis,
-- so solve x before reading y instead of treating the parameter as time.
local function slide_ease(time)
  local low, high = 0, 1
  local t = time
  for _ = 1, 16 do
    local inverse = 1 - t
    local x = 3 * inverse * inverse * t * 0.4 + 3 * inverse * t * t * 0.2 + t * t * t
    if x < time then low = t else high = t end
    t = (low + high) * 0.5
  end
  local inverse = 1 - t
  return 3 * inverse * t * t + t * t * t
end

local function new_entry(tracker, key)
  if tracker.count >= tracker.limit then
    local oldest_key, oldest_seen
    for existing_key, entry in pairs(tracker.entries) do
      if not oldest_seen or entry.seen < oldest_seen then
        oldest_key, oldest_seen = existing_key, entry.seen
      end
    end
    tracker.entries[oldest_key] = nil
    tracker.count = tracker.count - 1
  end

  local entry = {}
  tracker.entries[key] = entry
  tracker.count = tracker.count + 1
  return entry
end

local function entry_for(tracker, key)
  local entry = tracker.entries[key]
  if not entry then entry = new_entry(tracker, key) end
  tracker.seen = tracker.seen + 1
  entry.seen = tracker.seen
  return entry
end

function motion.new(limit)
  limit = math.floor(tonumber(limit) or 64)
  if limit < 1 then limit = 1 end
  return { limit = limit, entries = {}, count = 0, seen = 0 }
end

function motion.value(tracker, key, target, now, frame, duration)
  local entry = entry_for(tracker, key)
  local slide = entry.slide

  if not slide then
    entry.slide = {
      value = target, target = target, time = now, last_now = now, frame = frame,
    }
    return target
  end

  local stale = frame > slide.frame + 1 or now < slide.last_now or duration <= 0
  if stale then
    slide.value, slide.target, slide.time, slide.last_now, slide.frame =
      target, target, now, now, frame
    return target
  end

  -- Drawing can seed an old value and submit a click's new value in one frame.
  -- Start that one transition, but leave duplicate reads of the same target alone.
  if frame == slide.frame then
    if target ~= slide.target then
      slide.start, slide.target, slide.time = slide.value, target, now
    end
    return slide.value
  end

  local elapsed = now - slide.time
  if slide.value ~= slide.target then
    local progress = clamp(elapsed / duration, 0, 1)
    slide.value = slide.start + (slide.target - slide.start) * slide_ease(progress)
    if progress >= 1 then slide.value = slide.target end
  end

  if target ~= slide.target then
    -- Sample first, then reverse from that exact value so rapid toggles do not jump.
    slide.start, slide.target, slide.time = slide.value, target, now
  end
  slide.last_now, slide.frame = now, frame
  return slide.value
end

function motion.slide(tracker, key, on, now, frame, duration)
  return motion.value(tracker, key, on and 1 or 0, now, frame, duration)
end

local function pulse_value(start, now, duration)
  local t = (now - start) / duration
  if t >= 1 then return 0, false end
  if t <= 0 then return 0.3, true end

  if t < 0.12 then
    return 0.3 + 0.7 * smoothstep(t / 0.12), true
  end
  if t < 0.35 then
    return 1 - 0.15 * ease_out((t - 0.12) / 0.23), true
  end
  return 0.85 * (1 - ease_out((t - 0.35) / 0.65)), true
end

local function update_pulse(tracker, key, on, now, frame, duration, trigger, rise)
  local entry = entry_for(tracker, key)
  local pulse = entry.pulse

  if not pulse then
    pulse = { on = on, last_now = now, frame = frame }
    entry.pulse = pulse
    if on and trigger and duration > 0 then
      pulse.start, pulse.triggered_frame = now, frame
    end
  elseif not on then
    -- Off must win even if this is a second draw in the same frame.
    pulse.on, pulse.start, pulse.last_now, pulse.frame = false, nil, now, frame
  elseif frame > pulse.frame + 1 or now < pulse.last_now or duration <= 0 then
    pulse.on, pulse.start, pulse.last_now, pulse.frame = on, nil, now, frame
    if trigger and duration > 0 then
      pulse.start, pulse.triggered_frame = now, frame
    end
  elseif frame == pulse.frame then
    -- A seed draw may be followed by the click that caused it. A trigger starts
    -- once per frame; repeated draws cannot keep extending the pulse.
    if trigger and pulse.triggered_frame ~= frame then
      pulse.start, pulse.triggered_frame = now, frame
    elseif rise ~= false and not pulse.on then
      pulse.start = now
    end
    pulse.on = true
  else
    if not on then
      pulse.start = nil
    elseif trigger or (rise ~= false and not pulse.on) then
      pulse.start = now
      if trigger then pulse.triggered_frame = frame end
    end
    pulse.on, pulse.last_now, pulse.frame = on, now, frame
  end

  if not on or not pulse.start or duration <= 0 then return nil end
  if now - pulse.start >= duration then pulse.start = nil end
  return pulse.start
end

function motion.pulse(tracker, key, on, now, frame, duration, trigger)
  local start = update_pulse(tracker, key, on, now, frame, duration, trigger)
  if not start then return 0 end
  return (pulse_value(start, now, duration))
end

-- Monotonic progress for sweeps and orbits, with the same onset rules as blooms.
local function event_progress(start, now, duration)
  if not start then return nil end
  return clamp((now - start) / duration, 0, 1)
end

function motion.event(tracker, key, on, now, frame, duration, trigger)
  local start = update_pulse(tracker, key, on, now, frame, duration, trigger)
  return event_progress(start, now, duration)
end

-- Only the explicit click starts feedback; hover and live state are irrelevant.
function motion.icon_event(tracker, key, clicked, now, frame, duration)
  return motion.event(tracker, key, true, now, frame, duration, clicked)
end

-- Toggle effects begin only when a click changes OFF to ON. Turning OFF cancels
-- an unfinished effect, and state changes that did not come from the button stay idle.
function motion.toggle_event(tracker, key, on, clicked, now, frame, duration)
  local next_on = on
  if clicked then next_on = not on end
  local start = update_pulse(tracker, key, next_on, now, frame, duration,
    clicked and not on, false)
  return event_progress(start, now, duration)
end

-- Stateful icon shapes ease toward ON after an activating click and snap OFF.
-- An already-ON state seen without its click also snaps into place without replaying.
function motion.toggle_value(tracker, key, on, clicked, now, frame, duration)
  local next_on = on
  if clicked then next_on = not on end

  if clicked and not on then
    motion.value(tracker, key, 0, now, frame, duration)
    return motion.value(tracker, key, 1, now, frame, duration)
  end

  local entry = tracker.entries[key]
  local slide = entry and entry.slide
  local continuing = next_on and slide and slide.target == 1 and slide.value ~= 1
  return motion.value(tracker, key, next_on and 1 or 0, now, frame,
    continuing and duration or 0)
end

-- Panel icons share the toggle rule: ease into the open state, then snap shut.
-- Closing elsewhere also updates the icon immediately without inventing a click.
function motion.icon_value(tracker, key, on, clicked, now, frame, duration)
  return motion.toggle_value(tracker, key, on, clicked, now, frame, duration)
end

return motion
