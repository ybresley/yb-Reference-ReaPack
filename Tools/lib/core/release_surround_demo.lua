-- Timed story and measured readings for the Surround examples. Targets name
-- controls, not screen pixels; the renderer resolves them each frame.
local demo = {}

local alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local decode = {}
for i = 1, #alphabet do decode[alphabet:byte(i)] = i - 1 end

local LEVEL_MIN, LEVEL_STEP, SILENT_PAIR = -150, .05, 4095
local CHANNELS, PAIRS = 6, 5
local FRAME_CODES = CHANNELS * 4 + PAIRS + 3

-- The Overview and Phase loops play the passage from its start, so the
-- example's audio time is the loop phase. Speaker Setup shows Settings and
-- plays no audio; its length comes from the beats below.
local durations = {surround_overview=6.9, surround_phase=6}

-- Speaker Setup, in seconds. An eight-channel master recommends 7.1; the
-- Speaker Arrangement list then offers every layout of up to eight channels,
-- so the same project can switch to 5.1 and to Quad (the real control allows
-- fewer channels than the master has).
demo.SETUP_CLICK = 1.9          -- Use Recommendation is clicked
demo.SETUP_PAUSE = .35          -- the pointer rests on a control before clicking it
demo.SETUP_MOVE = .8            -- between controls
demo.SETUP_OPEN = .4            -- the opened list is read before the pointer enters it
demo.SETUP_REACH = .9           -- the list scrolls while the pointer goes to the item
demo.SETUP_RESULT = 1.2         -- a new arrangement stays in view before the next change
demo.SETUP_END = 1.9            -- the last arrangement stays in view after the pointer is home
demo.SETUP_PICKS = {'5.1', 'quad'}
demo.SETUP_START = '7.1'

-- Pointer moves (from, to, start, end) and clicks (time, kind), built once.
local setup_moves, setup_clicks, setup_picks = {}, {}, {}
do
  local function move(from, to, start, finish)
    setup_moves[#setup_moves + 1] = {from=from, to=to, start=start, finish=finish}
  end
  local function click(time, kind) setup_clicks[#setup_clicks + 1] = {time=time, kind=kind} end
  move('home', 'recommendation', .5, demo.SETUP_CLICK - demo.SETUP_PAUSE)
  click(demo.SETUP_CLICK, 'recommendation')
  local at, place = demo.SETUP_CLICK + .4, 'recommendation'
  for _, id in ipairs(demo.SETUP_PICKS) do
    local arrive = at + demo.SETUP_MOVE
    move(place, 'combo', at, arrive)
    local opened = arrive + demo.SETUP_PAUSE
    click(opened, 'open')
    local reach = opened + demo.SETUP_OPEN
    local reached = reach + demo.SETUP_REACH
    move('combo', 'item', reach, reached)
    local picked = reached + demo.SETUP_PAUSE
    click(picked, 'pick')
    setup_picks[#setup_picks + 1] = {id=id, opened=opened, reach=reach, reached=reached, picked=picked}
    at, place = picked + demo.SETUP_RESULT, 'item'
  end
  move(place, 'home', at, at + demo.SETUP_MOVE)
  durations.surround_speakers = at + demo.SETUP_MOVE + demo.SETUP_END
end

demo.SIDE_ARRIVAL = 1.1
demo.SIDE_DEPARTURE = 4.9

local function level(code)
  -- Code 0 is the helper's silence marker, which the meter reads as no value.
  return code > 0 and LEVEL_MIN + code * LEVEL_STEP or nil
end

-- Decoded once per example: plain numbers the meter session reads every frame.
function demo.decode(signal)
  assert(type(signal) == 'table' and type(signal.frames) == 'table' and #signal.frames > 0
    and type(signal.step) == 'number' and signal.step > 0,
    'The surround demonstration needs measured frames.')
  local frames = {}
  for index, encoded in ipairs(signal.frames) do
    assert(type(encoded) == 'string' and #encoded == FRAME_CODES * 2,
      'The surround demonstration has an invalid frame.')
    local values = {}
    for k = 1, FRAME_CODES do
      local a, b = encoded:byte(k * 2 - 1, k * 2)
      assert(decode[a] and decode[b], 'The surround demonstration has an invalid reading.')
      values[k] = decode[a] * 64 + decode[b]
    end
    local frame = {t=index * signal.step, rms={}, peak={}, live={}, age={}, pairs={}}
    for c = 1, CHANNELS do
      frame.rms[c] = level(values[c])
      frame.peak[c] = level(values[CHANNELS + c])
      frame.live[c] = level(values[CHANNELS * 2 + c])
      frame.age[c] = values[CHANNELS * 3 + c] / 1000
    end
    for p = 1, PAIRS do
      local code = values[CHANNELS * 4 + p]
      frame.pairs[p] = code ~= SILENT_PAIR and code / 1000 - 1 or false
    end
    local tail = CHANNELS * 4 + PAIRS
    frame.m, frame.s, frame.i = level(values[tail + 1]), level(values[tail + 2]), level(values[tail + 3])
    frames[index] = frame
  end
  return {frames=frames, step=signal.step, pairs=signal.pairs,
    inverted_channel=signal.inverted_channel, count=CHANNELS}
end

-- The latest published frame at an audio time. Publication starts promptly.
function demo.frame_index(source, time)
  local index = math.floor(math.max(0, time) / source.step + 1e-9)
  return math.max(1, math.min(#source.frames, index))
end

-- Pair numbering shared with the meter helper: (1,2), (1,3) ... (1,n), (2,3) ...
local function pair_index(a, b, count)
  if a > b then a, b = b, a end
  return (a - 1) * count - (a - 1) * a // 2 + (b - a)
end

-- One helper publication in the shape the meter session reads. Pairs the
-- field does not draw are unmeasured, as the helper leaves them.
function demo.snapshot(source, index, sequence, inverted, loudness_available)
  local frame = source.frames[index]
  local count = source.count
  local seconds, m, s, i = frame.t, frame.m, frame.s, frame.i
  local snapshot = {ready=true, playing=true, sequence=sequence, lra_seconds=seconds,
    loudness_available=loudness_available, lra_valid=0, channels={}, correlations={}}
  if loudness_available then snapshot.m, snapshot.s, snapshot.i = m, s, i end
  for c = 1, count do
    snapshot.channels[c] = {rms=frame.rms[c] or -150, field_rms=frame.rms[c] or -150,
      peak=frame.peak[c] or -150, live_peak=frame.live[c] or -150, peak_age=frame.age[c]}
  end
  for p = 1, count * (count - 1) // 2 do snapshot.correlations[p] = false end
  for p, pair in ipairs(source.pairs) do
    local value = frame.pairs[p]
    -- The Phase topic plays the passage with one speaker's polarity inverted.
    if value and inverted and (pair[1] == source.inverted_channel or pair[2] == source.inverted_channel) then
      value = -value
    end
    snapshot.correlations[pair_index(pair[1], pair[2], count)] = value
  end
  return snapshot
end

function demo.duration(topic)
  return durations[topic] or durations.surround_overview
end

-- With Interface Animations off a demo still plays its steps, but each move
-- lands at once instead of gliding there.
local function ease(value, still)
  value = math.max(0, math.min(1, value))
  if still then return value > 0 and 1 or 0 end
  return value * value * (3 - 2 * value)
end

local function travel(out, from, to, phase, start, length)
  out.from, out.to = from, to
  out.progress = from == to and 1 or ease((phase - start) / length, out.still)
end

function demo.sample(topic, elapsed, out, still)
  out = out or {}
  for key in pairs(out) do out[key] = nil end
  out.still = still or nil
  elapsed = math.max(0, tonumber(elapsed) or 0)
  local duration = demo.duration(topic)
  local phase = elapsed % duration
  out.phase, out.cycle, out.time = phase, math.floor(elapsed / duration), phase
  out.assigned, out.inverted = true, false
  if topic == 'surround_speakers' then
    out.from, out.to, out.progress = 'home', 'home', 1
    for _, step in ipairs(setup_moves) do
      if phase >= step.start then
        if phase < step.finish then travel(out, step.from, step.to, phase, step.start, step.finish - step.start)
        else out.from, out.to, out.progress = step.to, step.to, 1 end
      end
    end
    out.arrangement = phase < demo.SETUP_CLICK and 'unassigned' or demo.SETUP_START
    out.assigned = phase >= demo.SETUP_CLICK
    for _, pick in ipairs(setup_picks) do
      if phase >= pick.picked then out.arrangement = pick.id end
    end
    for _, pick in ipairs(setup_picks) do
      if phase >= pick.opened and phase < pick.picked then
        out.menu, out.menu_item = true, pick.id
        out.scroll = ease((phase - pick.reach) / demo.SETUP_REACH, out.still)
      end
    end
    for _, press in ipairs(setup_clicks) do
      if phase >= press.time and phase < press.time + .3 then out.pulse = (phase - press.time) / .3 end
    end
  elseif topic == 'surround_phase' then
    local arrive, leave = demo.SIDE_ARRIVAL, demo.SIDE_DEPARTURE
    out.inverted = true
    if phase < .3 then travel(out, 'home', 'home', phase, 0, 1)
    elseif phase < arrive then travel(out, 'home', 'side', phase, .3, arrive - .3)
    elseif phase < leave then travel(out, 'side', 'side', phase, 0, 1)
    elseif phase < leave + .7 then travel(out, 'side', 'home', phase, leave, .7)
    else travel(out, 'home', 'home', phase, 0, 1) end
    -- The pointer rests on the side; the renderer applies the real tip delay.
    if phase >= arrive and phase < leave then out.resting = phase - arrive end
  end
  return out
end

return demo
