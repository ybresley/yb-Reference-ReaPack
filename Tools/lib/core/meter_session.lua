-- Display state for audio measurements. The adapter owns analysis and resets
-- this state for an explicit reset or a different source.
local session = {}
local warnings = require('core.meter_warnings')
local readings = require('core.meter_readings')

-- One minute at the helper's maximum 100 Hz, plus the left-edge predecessor.
local HISTORY_LIMIT = 6001
session.HISTORY_LIMIT = HISTORY_LIMIT
local HISTORY_STEP = 0.1
local MAX_FRAME_DT = 0.25
local VIEW_LEAD_LIMIT = 0.05
local PEAK_HOLD_SECONDS = 1.5
local PEAK_HOLD_FALL_DB_PER_SECOND = 20
local PEAK_FALL_RATES = { Fast=40, Normal=20, Slow=10 }
local PEAK_HOLD_FLOOR = -100
local SILENCE_FALL_DB_PER_SECOND = 20
local LIVE_FIELDS = { m=true, s=true, rms_l=true, rms_r=true, live_peak_l=true, live_peak_r=true }
-- Visual movement bridges audio publications without changing measured readings,
-- stored history or peak warnings.
local RISE_SECONDS, FALL_SECONDS = 0.045, 0.075
local MOVING_FIELDS = { 'm', 's', 'i', 'rms_l', 'rms_r', 'live_peak_l', 'live_peak_r', 'lra_low', 'lra_high' }
local PEAK_FIELDS = {
  ['Sample Peak']={peak='peak_',live='live_peak_',age='peak_age_'},
  ['True Peak']={peak='true_peak_',live='live_true_peak_',age='true_peak_age_'},
}

local function reading(value, crest)
  if type(value) ~= 'number' or value ~= value
      or value == math.huge or value == -math.huge
      or value == -100 or value == -150
      or (crest and value < 0) then
    return nil
  end
  return value
end

-- Pair correlations for the Surround Field, kept only when they match the
-- channel count. The meter adapter has already range-checked each value.
-- An older helper sends none, and the field draws without phase.
local function pair_values(raw, count)
  if type(raw)~='table' or count<2 or #raw~=count*(count-1)//2 then return nil end
  return raw
end

local function channel_values(snapshot, fields, warm)
  local channels={}
  local raw_channels=snapshot.channels
  if type(raw_channels)~='table' then
    raw_channels={}
    for _,side in ipairs({'l','r'}) do
      local raw={}
      for _,key in ipairs({'rms','peak','live_peak','peak_age','true_peak','live_true_peak','true_peak_age','crest','field_rms'}) do
        raw[key]=snapshot[key..'_'..side]
      end
      raw_channels[#raw_channels+1]=raw
    end
  end
  local peak_key,live_key,age_key=fields.peak:sub(1,-2),fields.live:sub(1,-2),fields.age:sub(1,-2)
  for index,raw in ipairs(raw_channels) do
    channels[index]={
      rms=warm and reading(raw.rms) or nil,
      field_rms=reading(raw.field_rms or raw.rms),
      peak=warm and reading(raw[peak_key]) or nil,
      warning_peak=reading(raw[peak_key]), live_peak=reading(raw[live_key]),
      peak_age=raw[age_key], crest=warm and reading(raw.crest,true) or nil,
    }
  end
  return channels
end

local function higher(current, value)
  if value == nil then return current end
  return current == nil and value or math.max(current, value)
end

function session.new()
  return session.reset({ hold = false })
end

function session.reset(state)
  state = state or {}
  local hold = state.hold == true
  state.hold = hold
  state.warnings = warnings.new()
  state.valid = false
  state.status = nil
  state.values = nil
  state.field_channels = {}
  state.display = {}
  state.elapsed = 0
  state.view_elapsed = 0
  state.m_max = nil
  state.s_max = nil
  state.tp_max = nil
  state.peak_hold = { l = nil, r = nil }
  state.peak_hold_remaining = { l = 0, r = 0 }
  state.loudness_peak = {}
  state.loudness_peak_remaining = { m = 0, s = 0 }
  state.loudness_peak_previous = {}
  state.loudness_peak_publication = nil
  state.history = {}
  state.history_count = 0
  state.history_head = 1
  state.last_history_t = 0
  state.sequence = nil
  state.peak_measurement, state.peak_snapshot = nil, nil
  state.peak_active = false
  state.peak_warm = false
  return state
end

local function update_peak_hold(state, channel, peak, dt, fresh_publication, peak_age)
  local prefs = state.prefs or {}
  local hold_seconds = prefs.lr_hold or PEAK_HOLD_SECONDS
  local fall_rate = PEAK_FALL_RATES[prefs.peak_fall] or PEAK_HOLD_FALL_DB_PER_SECOND
  local held = state.peak_hold[channel]
  if held ~= nil then
    state.peak_hold_remaining[channel] = math.min(state.peak_hold_remaining[channel], hold_seconds)
  end
  if peak ~= nil and (held == nil or peak > held
      or (peak == held and fresh_publication)) then
    state.peak_hold[channel] = peak
    -- A retained peak is not a fresh transient. Its sample age prevents the
    -- 400 ms measurement window from extending the visual hold.
    state.peak_hold_remaining[channel] = math.max(0, hold_seconds - (peak_age or 0))
    return
  end
  if held == nil then return end

  local remaining = state.peak_hold_remaining[channel]
  state.peak_hold_remaining[channel] = math.max(0, remaining - dt)
  local fall_time = math.max(0, dt - remaining)
  if fall_time <= 1e-9 then return end

  -- No current peak means silence. The visual marker leaves the scale rather
  -- than becoming a permanent maximum after its hold time expires.
  local floor = peak or PEAK_HOLD_FLOOR
  held = math.max(floor, held - fall_time * fall_rate)
  state.peak_hold[channel] = held > PEAK_HOLD_FLOOR and held or nil
end

-- Loudness markers stay at their captured level and expire in place. After
-- expiry a falling bar cannot immediately recreate a lower marker.
local function update_loudness_peak(state, key, value, dt, fresh)
  local hold_seconds = (state.prefs or {}).ms_hold or PEAK_HOLD_SECONDS
  if hold_seconds == -1 then
    if fresh then state.loudness_peak[key] = higher(state.loudness_peak[key],value) end
    return
  end
  if hold_seconds == 0 then
    state.loudness_peak[key],state.loudness_peak_remaining[key] = nil,0
    state.loudness_peak_previous[key] = value
    return
  end
  local held = state.loudness_peak[key]
  if held ~= nil then
    state.loudness_peak_remaining[key] = math.min(state.loudness_peak_remaining[key], hold_seconds)
  end
  local previous = state.loudness_peak_previous[key]
  if fresh then state.loudness_peak_previous[key] = value end
  if fresh and value and ((held and value >= held)
      or (not held and (not previous or value > previous))) then
    state.loudness_peak[key] = value
    state.loudness_peak_remaining[key] = hold_seconds
    return
  end
  local remaining = math.max(0, state.loudness_peak_remaining[key] - dt)
  state.loudness_peak_remaining[key] = remaining
  if remaining <= 1e-9 then state.loudness_peak[key] = nil end
end

local function append_history(state, t, m, s, i)
  local index = (state.history_head + state.history_count - 1) % HISTORY_LIMIT + 1
  local point = state.history[index] or {}
  point.t, point.m, point.s, point.i = t, m, s, i
  state.history[index] = point
  if state.history_count < HISTORY_LIMIT then
    state.history_count = state.history_count + 1
  else
    state.history_head = state.history_head % HISTORY_LIMIT + 1
  end
  state.last_history_t = t
end

function session.history_at(state, index)
  if type(index) ~= 'number' or index % 1 ~= 0
      or index < 1 or index > state.history_count then
    return nil
  end
  local slot = (state.history_head + index - 2) % HISTORY_LIMIT + 1
  return state.history[slot]
end

local function advance_view(state, dt)
  if state.hold then return end
  -- Audio readings arrive in 10 ms steps. Advance the viewport each draw,
  -- while keeping it close to the measured time and never moving it back.
  local next_view = math.max(state.view_elapsed + dt, state.elapsed)
  state.view_elapsed = math.max(state.view_elapsed,
    math.min(next_view, state.elapsed + VIEW_LEAD_LIMIT))
end

function session.update(state, snapshot, dt)
  snapshot = snapshot or {}
  state.status = snapshot.status
  dt = type(dt) == 'number' and dt or 0
  if dt ~= dt or dt < 0 or dt == math.huge then dt = 0 end
  local peak_dt = dt
  dt = math.min(dt, MAX_FRAME_DT)
  if snapshot.ready == true then
    local supported = snapshot.sample_rate_supported ~= false
    if state.sample_rate_supported ~= nil and state.sample_rate_supported ~= supported then
      -- A frozen reading must not survive a change in available measurements.
      session.reset(state)
    end
    state.sample_rate_supported = supported
    state.true_peak_available = snapshot.true_peak_available ~= false
    if snapshot.loudness_available ~= nil then state.loudness_available = snapshot.loudness_available end
  end
  local peak_mode = readings.peak_measurement(state)
  local peak_fields = PEAK_FIELDS[peak_mode]
  if state.peak_measurement ~= peak_mode then
    -- A hold from one measurement type must not be relabelled as the other.
    state.peak_hold = {l=nil,r=nil}
    state.peak_hold_remaining = {l=0,r=0}
    state.display.live_peak_l, state.display.live_peak_r = nil, nil
    state.display.channels=nil
    state.peak_measurement = peak_mode
    if (state.hold or snapshot.pending_publication) and state.values and state.peak_active and state.peak_snapshot then
      local retained = state.peak_snapshot
      state.values.peak_measurement=peak_mode
      state.values.channels=channel_values(retained,peak_fields,state.peak_warm)
      for index,channel in ipairs(state.values.channels) do
        update_peak_hold(state,index,channel.warning_peak,0,true,channel.peak_age)
      end
      for _,ch in ipairs({'l','r'}) do
        state.values['peak_'..ch] = state.peak_warm and reading(retained[peak_fields.peak..ch]) or nil
        state.values['warning_peak_'..ch] = reading(retained[peak_fields.peak..ch])
        state.values['live_peak_'..ch] = reading(retained[peak_fields.live..ch])
        state.display['live_peak_'..ch] = state.values['live_peak_'..ch]
        update_peak_hold(state,ch,reading(retained[peak_fields.peak..ch]),0,true,retained[peak_fields.age..ch])
      end
    end
  end
  if snapshot.pending_publication then
    -- A read crossing an audio publication must not pause the display clock.
    if snapshot.playing == true and state.valid then advance_view(state, dt) end
    return state
  end
  if snapshot.ready ~= true then
    state.valid = false
    state.values = nil
    state.field_channels = {}
    state.peak_snapshot, state.peak_active = nil, false
    if (state.prefs or {}).ms_hold ~= -1 then
      state.loudness_peak.m, state.loudness_peak.s = nil, nil
      state.loudness_peak_remaining.m, state.loudness_peak_remaining.s = 0, 0
      state.loudness_peak_previous.m, state.loudness_peak_previous.s = nil, nil
    end
    return state
  end

  if snapshot.playing ~= true then
    state.field_channels={}
    if not state.hold and state.values then
      -- Integrated and session statistics remain while live readings fall away.
      for key in pairs(LIVE_FIELDS) do state.values[key] = nil end
      state.values.peak_l, state.values.peak_r = nil, nil
      state.values.warning_peak_l, state.values.warning_peak_r = nil, nil
      for index,channel in ipairs(state.values.channels or {}) do
        channel.rms,channel.field_rms,channel.peak,channel.warning_peak,channel.live_peak=nil,nil,nil,nil,nil
        update_peak_hold(state,index,nil,peak_dt,false)
      end
      state.peak_active = false
      update_peak_hold(state, 'l', nil, peak_dt, false)
      update_peak_hold(state, 'r', nil, peak_dt, false)
      update_loudness_peak(state, 'm', nil, peak_dt, false)
      update_loudness_peak(state, 's', nil, peak_dt, false)
    end
    return state
  end

  -- The helper retains run maxima even when the interface misses publications.
  -- The audio clock keeps measurement time accurate even when redraws are delayed.
  local audio_seconds = reading(snapshot.lra_seconds)
  if audio_seconds and audio_seconds >= 0 then
    state.elapsed = math.max(state.elapsed, audio_seconds)
  else
    state.elapsed = state.elapsed + dt
  end
  advance_view(state, dt)
  local fresh_publication = snapshot.sequence == nil
    or snapshot.sequence ~= state.sequence
  state.sequence = snapshot.sequence
  -- The surround field owns its own Freeze control. Keep its input current even
  -- while the Loudness display retains an earlier measurement.
  local warm_m = state.sample_rate_supported == false or state.elapsed + 1e-9 >= 0.4
  state.field_channels=channel_values(snapshot,peak_fields,warm_m)
  state.field_channels.correlations=pair_values(snapshot.correlations,#state.field_channels)
  if state.hold then return state end
  state.peak_snapshot, state.peak_active = snapshot, true

  state.peak_warm = warm_m
  local loudness_available=snapshot.loudness_available~=false and state.loudness_available~=false
  state.loudness_available=loudness_available
  local short_term = loudness_available and reading(snapshot.s) or nil
  local lra_low, lra_high = reading(snapshot.lra_low), reading(snapshot.lra_high)
  local lra_ready = loudness_available and snapshot.lra_valid == 1 and lra_low and lra_high and lra_high >= lra_low
  local values = {
    peak_measurement = peak_mode,
    m = loudness_available and reading(snapshot.m) or nil,
    s = short_term,
    lra = lra_ready and lra_high - lra_low or nil,
    lra_low = lra_ready and lra_low or nil,
    lra_high = lra_ready and lra_high or nil,
    i = loudness_available and warm_m and reading(snapshot.i) or nil,
    tp_max = state.true_peak_available ~= false and reading(snapshot.tp_max) or nil,
    rms_l = warm_m and reading(snapshot.rms_l) or nil,
    rms_r = warm_m and reading(snapshot.rms_r) or nil,
    peak_l = warm_m and reading(snapshot[peak_fields.peak..'l']) or nil,
    peak_r = warm_m and reading(snapshot[peak_fields.peak..'r']) or nil,
    -- Clip detection must see short transients before numeric readouts warm up.
    warning_peak_l = reading(snapshot[peak_fields.peak..'l']),
    warning_peak_r = reading(snapshot[peak_fields.peak..'r']),
    live_peak_l = reading(snapshot[peak_fields.live..'l']),
    live_peak_r = reading(snapshot[peak_fields.live..'r']),
    crest = state.sample_rate_supported ~= false and reading(snapshot.crest, true) or nil,
    crest_l = state.sample_rate_supported ~= false and warm_m and reading(snapshot.crest_l, true) or nil,
    crest_r = state.sample_rate_supported ~= false and warm_m and reading(snapshot.crest_r, true) or nil,
  }
  values.channels=state.field_channels
  for index,channel in ipairs(values.channels) do
    update_peak_hold(state,index,channel.warning_peak,peak_dt,fresh_publication,channel.peak_age)
  end
  state.values = values
  state.valid = true
  state.m_max = loudness_available and higher(state.m_max, reading(snapshot.m_max)) or nil
  state.m_max = higher(state.m_max, values.m)
  state.s_max = loudness_available and higher(state.s_max, reading(snapshot.s_max)) or nil
  state.s_max = higher(state.s_max, values.s)
  state.tp_max = higher(state.tp_max, values.tp_max)
  local publication = snapshot.lra_seconds or snapshot.sequence
  local fresh_loudness = publication == nil or publication ~= state.loudness_peak_publication
  state.loudness_peak_publication = publication
  update_loudness_peak(state, 'm', values.m, peak_dt, fresh_loudness)
  update_loudness_peak(state, 's', values.s, peak_dt, fresh_loudness)
  update_peak_hold(state, 'l', reading(snapshot[peak_fields.peak..'l']), peak_dt, fresh_publication, snapshot[peak_fields.age..'l'])
  update_peak_hold(state, 'r', reading(snapshot[peak_fields.peak..'r']), peak_dt, fresh_publication, snapshot[peak_fields.age..'r'])

  if not loudness_available then
    state.history,state.history_count,state.history_head={},0,1
    state.loudness_peak,state.loudness_peak_remaining={}, {m=0,s=0}
    state.last_history_t=state.elapsed
  elseif type(snapshot.history) == 'table' then
    -- The helper records each measured window. Missing windows remain a gap.
    for _, point in ipairs(snapshot.history) do
      if type(point.t) == 'number' and point.t > state.last_history_t + 1e-9 then
        append_history(state, point.t, reading(point.m), reading(point.s), reading(point.i))
      end
    end
  else
    -- Older standalone session callers only provide a current reading.
    local history_step = audio_seconds and 0.01 or HISTORY_STEP
    if state.elapsed - state.last_history_t + 1e-9 >= history_step then
      append_history(state, state.elapsed, values.m, values.s, values.i)
    end
  end
  return state
end

function session.animate(state, dt, loudness_floor)
  local display = state.display
  if not state.valid or not state.values then
    for _, key in ipairs(MOVING_FIELDS) do display[key] = nil end
    display.channels={}
    return display
  end
  if state.hold then return display end
  dt = type(dt) == 'number' and dt or 0
  if dt ~= dt or dt < 0 then dt = 0 end
  local rise = 1 - math.exp(-dt / RISE_SECONDS)
  local fall = 1 - math.exp(-dt / FALL_SECONDS)
  loudness_floor = loudness_floor or -48
  for _, key in ipairs(MOVING_FIELDS) do
    local target, current = state.values[key], display[key]
    local starting_loudness = current == nil and target ~= nil
      and (key == 'm' or key == 's' or key == 'i')
    if starting_loudness then
      current = math.min(loudness_floor, target)
    end
    if target == nil and current ~= nil and LIVE_FIELDS[key] then
      local falling = current - SILENCE_FALL_DB_PER_SECOND * dt
      display[key] = falling > PEAK_HOLD_FLOOR and falling or nil
    elseif target == nil or current == nil or (dt >= MAX_FRAME_DT and not starting_loudness) then
      display[key] = target
    else
      local rising = target > current
      -- The audio peak already has a sample-rate release envelope. Filtering it
      -- again delays its fall behind the signal without adding redraws.
      local amount = key:sub(1, 10) == 'live_peak_' and 1 or (rising and rise or fall)
      -- Equal endpoint timing preserves their order while the bracket moves.
      if key == 'lra_low' or key == 'lra_high' then amount = 1 - math.exp(-dt / 0.12) end
      display[key] = current + (target - current) * amount
    end
  end
  display.channels=display.channels or {}
  for index,channel in ipairs(state.values.channels or {}) do
    local drawn=display.channels[index] or {}
    for _,key in ipairs({'rms','live_peak'}) do
      local target,current=channel[key],drawn[key]
      if target==nil and current~=nil then
        local falling=current-SILENCE_FALL_DB_PER_SECOND*dt
        drawn[key]=falling>PEAK_HOLD_FLOOR and falling or nil
      elseif target==nil or current==nil or dt>=MAX_FRAME_DT then drawn[key]=target
      else
        local amount=key=='live_peak' and 1 or (target>current and rise or fall)
        drawn[key]=current+(target-current)*amount
      end
    end
    display.channels[index]=drawn
  end
  for index=#(state.values.channels or {})+1,#display.channels do display.channels[index]=nil end
  return display
end

function session.format(value)
  if value == -math.huge then return '−∞' end
  value = reading(value)
  if value == nil then return '—' end
  if value == 0 then return '0.0' end
  return string.format('%+.1f', value)
end

return session
