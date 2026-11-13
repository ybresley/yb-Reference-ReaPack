-- Timing for the Reference Card release demonstrations. Pure: no reaper.*.
--
-- The overview is a short tour of the card's controls: Play, seek, trim, Stop.
-- The resizing topic drags the window's bottom edge up
-- through each way the card folds, pausing at each, then back down. Which
-- folds exist comes from the production plan (core/card_plan.lua), measured by
-- the caller through fold_stages; this module only orders and times them.
local demo = {}

-- The sample reference: the measured passage the waveform, spectrum and stereo
-- data share.
demo.LENGTH = 4

-- Overview: a short tour of the card's own controls. The pointer presses Play,
-- clicks the waveform to seek, drags the trim bar out and back, then presses
-- Stop. Each click changes the card's state the way the entry script would
-- after that click; the card itself draws every result.
--
-- The tour is a list of pointer moves, each starting after a dwell, so the
-- timeline below is the only place its seconds live.
local SETTLE = .3          -- arrived, then clicked
local steps, cursor = {}, 0
local function dwell(seconds) cursor = cursor + seconds end
local function move(from, to, seconds)
  steps[#steps + 1] = {from = from, to = to, start = cursor, duration = seconds}
  cursor = cursor + seconds
end

dwell(.6)
move('home', 'play', .8)
dwell(SETTLE)
local PLAY_CLICK = cursor
dwell(1.4)
move('play', 'seek', .9)
dwell(SETTLE)
local SEEK_CLICK = cursor
dwell(.8)
move('seek', 'trim', 1.0)
dwell(SETTLE)
local TRIM_PRESS = cursor
move('trim', 'trim_far', 1.1)
dwell(.5)
move('trim_far', 'trim', .9)
local TRIM_RELEASE = cursor
dwell(.3)
move('trim', 'stop', .9)
dwell(SETTLE)
local STOP_CLICK = cursor
dwell(.8)
move('stop', 'home', .9)
dwell(.8)
local OVERVIEW = cursor

-- A seek lands on SEEK_TO seconds into the reference.
local SEEK_TO = .6
demo.SEEK_FRACTION = SEEK_TO / demo.LENGTH

-- The trim bar's 0 dB sits at its middle; the drag stops at TRIM_FAR_T of the
-- bar's width. ui/widgets.lua's taper turns that place into the bar's value.
demo.TRIM_HOME_T, demo.TRIM_FAR_T = .5, .36

-- Where along the bar the pointer is for a drag that is `drag` (0 to 1) of the
-- way from 0 dB to the far stop.
function demo.trim_t(drag) return demo.TRIM_HOME_T + (demo.TRIM_FAR_T - demo.TRIM_HOME_T) * drag end

-- The audio clock gains this much from Play to Stop. The clock never runs
-- backwards, so a seek is a forward jump that lands on the same place in the
-- reference, and each loop starts a whole number of plays after the last.
local SEEK_JUMP = (SEEK_TO - (SEEK_CLICK - PLAY_CLICK) % demo.LENGTH) % demo.LENGTH
local PLAYED = STOP_CLICK - PLAY_CLICK + SEEK_JUMP
local AUDIO_PER_LOOP = math.ceil(PLAYED / demo.LENGTH) * demo.LENGTH
demo.PLAY_CLICK, demo.SEEK_CLICK, demo.STOP_CLICK = PLAY_CLICK, SEEK_CLICK, STOP_CLICK

-- Resizing: each fold is reached in MOVE seconds and held for HOLD.
local MOVE, HOLD = .55, .45
local PRESS = 1.4          -- the pointer has reached the edge and pressed
local AFTER_STAGES = .4    -- released at the smallest size
local GROW = 1.4           -- dragged straight back down
local AFTER_GROW = .4
local RETURN = .8
local REST = .3

-- With Interface Animations off a demo still plays its steps, but each move
-- lands at once instead of gliding there.
local function ease(value, still)
  value = math.max(0, math.min(1, value))
  if still then return value > 0 and 1 or 0 end
  return value * value * (3 - 2 * value)
end

local function travel(out, from, to, phase, start, duration)
  out.from, out.to = from, to
  out.progress = from == to and 1 or ease((phase - start) / duration, out.still)
end

local function clean(elapsed)
  local time = tonumber(elapsed) or 0
  if time ~= time or math.abs(time) == math.huge then time = 0 end
  return math.max(0, time)
end

-- The resizing loop's length for `stages` folds (the first is the starting size).
function demo.resize_duration(stages)
  assert(type(stages) == 'number' and stages >= 1, 'The resize demonstration needs its fold stages.')
  return PRESS + (stages - 1) * (MOVE + HOLD) + AFTER_STAGES + GROW + AFTER_GROW + RETURN + REST
end

function demo.duration(topic, stages)
  if topic == 'card_overview' then return OVERVIEW end
  if topic == 'card_resize' then return demo.resize_duration(stages) end
  error('Unknown Reference Card demo topic.')
end

local function overview(out, elapsed, phase)
  local loop = math.floor(elapsed / OVERVIEW)
  -- The first loop starts a whole loop in, so it opens like every later one.
  local base = (loop + 1) * AUDIO_PER_LOOP
  if phase < PLAY_CLICK then
    -- Stopped, with the clock held where the last loop's Stop left it.
    out.audio = base - AUDIO_PER_LOOP + PLAYED
    out.playing = false
  elseif phase < STOP_CLICK then
    out.audio = base + phase - PLAY_CLICK + (phase >= SEEK_CLICK and SEEK_JUMP or 0)
    out.playing = true
  else
    out.audio = base + PLAYED
    out.playing = false
  end
  -- Play's bloom restarts on every start.
  out.plays = loop + (phase >= PLAY_CLICK and 1 or 0)

  local at = 'home'
  out.from, out.to, out.progress = at, at, 1
  for _, step in ipairs(steps) do
    if phase < step.start then break end
    if phase < step.start + step.duration then
      travel(out, step.from, step.to, phase, step.start, step.duration)
      break
    end
    at = step.to
    out.from, out.to, out.progress = at, at, 1
  end

  -- How far along the trim drag the bar is: out to the far stop and back.
  local drag = 0
  if out.from == 'trim' and out.to == 'trim_far' then drag = out.progress
  elseif out.from == 'trim_far' and out.to == 'trim' then drag = 1 - out.progress
  elseif phase >= TRIM_PRESS and phase < TRIM_RELEASE then drag = 1 end
  out.trim_drag = drag

  for _, at_click in ipairs({PLAY_CLICK, SEEK_CLICK, TRIM_PRESS, STOP_CLICK}) do
    if phase >= at_click and phase < at_click + .25 then out.pulse = (phase - at_click) / .25 end
  end
  return out
end

-- height_from and height_to are stage numbers (1 is the starting size, `stages`
-- the smallest); height_progress runs between them.
local function resize(out, phase, stages)
  local function height(from, to, start, duration)
    out.height_from, out.height_to = from, to
    out.height_progress = from == to and 1 or ease((phase - start) / duration, out.still)
  end
  local released = PRESS + (stages - 1) * (MOVE + HOLD)
  local grow_at = released + AFTER_STAGES
  local grown = grow_at + GROW
  local leave = grown + AFTER_GROW
  if phase < .3 then travel(out, 'home', 'home', phase, 0, 1)
  elseif phase < 1.1 then travel(out, 'home', 'edge', phase, .3, .8)
  elseif phase < leave then travel(out, 'edge', 'edge', phase, 1.1, 1)
  elseif phase < leave + RETURN then travel(out, 'edge', 'home', phase, leave, RETURN)
  else travel(out, 'home', 'home', phase, leave + RETURN, 1) end
  -- The resize cursor shows from arriving at the edge until leaving it.
  out.resize_axis = phase >= 1.1 and phase < leave and 'y' or nil
  out.resizing = phase >= PRESS and phase < released or phase >= grow_at and phase < grown

  if phase < PRESS then height(1, 1, 0, 1)
  elseif phase < released then
    local step = math.min(stages - 1, math.floor((phase - PRESS) / (MOVE + HOLD)))
    local start = PRESS + step * (MOVE + HOLD)
    height(step + 1, step + 2, start, MOVE)
  elseif phase < grow_at then height(stages, stages, released, 1)
  elseif phase < grown then height(stages, 1, grow_at, GROW)
  else height(1, 1, grown, 1) end

  for _, at in ipairs({PRESS, released, grow_at, grown}) do
    if phase >= at and phase < at + .25 then out.pulse = (phase - at) / .25 end
  end
  return out
end

-- Fills `out` (reused) with the scene at `elapsed` seconds since the topic was
-- selected. `stages` is the number of fold stages for card_resize.
function demo.sample(topic, elapsed, out, still, stages)
  out = out or {}
  for key in pairs(out) do out[key] = nil end
  out.still = still or nil
  local time = clean(elapsed)
  local duration = demo.duration(topic, stages)
  local phase = time % duration
  out.phase = phase
  if topic == 'card_overview' then return overview(out, time, phase) end
  return resize(out, phase, stages)
end

-- One fold stage's identity: whether the details line shows, how many rows of
-- readings, and whether there is a waveform.
local function stage_key(plan)
  return (plan.facts and 1 or 0) + 2 * (plan.readings or 0) + ((plan.wave or 0) > 0 and 8 or 0)
end

-- Walks the window's content height from `high` down to `low` in whole pixels
-- and records each run of heights that gives the card the same folds. `fit(h)`
-- returns the production plan for height h. Fills `out` with
-- { {key, high, low, plan = {facts, readings, wave}}, ... }, tallest first.
function demo.fold_stages(fit, high, low, out)
  out = out or {}
  for i = #out, 1, -1 do out[i] = nil end
  high, low = math.floor(high), math.ceil(low)
  for h = high, low, -1 do
    local plan = fit(h)
    local key = stage_key(plan)
    local last = out[#out]
    if last and last.key == key then
      last.low = h
    else
      out[#out + 1] = { key = key, high = h, low = h,
        plan = { facts = plan.facts, readings = plan.readings, wave = plan.wave } }
    end
  end
  return out
end

-- The height the demonstration pauses at in each stage: the start at its full
-- height, the smallest at the window's floor, the rest midway through their
-- range. Fills `out` with one height per stage.
function demo.fold_holds(stages, out)
  out = out or {}
  for i = #out, 1, -1 do out[i] = nil end
  for i, stage in ipairs(stages) do
    if i == 1 then out[i] = stage.high
    elseif i == #stages then out[i] = stage.low
    else out[i] = math.floor((stage.high + stage.low) / 2 + .5) end
  end
  return out
end

return demo
