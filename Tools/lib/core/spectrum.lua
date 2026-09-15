-- Preferences and display history, independent of playback and helper ownership.
local spectrum = {}
local maths = require("core.spectrum_math")
local json = require("vendor.json")

spectrum.OPTIONS = {
  resolution = { "responsive", "balanced", "detailed" },
  speed = { "fast", "balanced", "smooth" },
  smoothing = { "off", "1/24", "1/12", "1/6" },
  average = { "off", "1s", "3s", "infinite" },
  tilt = { 0, 3, 4.5 }, range = { 60, 90, 120 },
  visual = { "waveform", "spectrum" },
}
local FFT = { responsive = 2048, balanced = 4096, detailed = 8192 }
local SMOOTHING = { off = 0, ["1/24"] = 1 / 24, ["1/12"] = 1 / 12, ["1/6"] = 1 / 6 }
local HELPER_HISTORY = { off = 0, ["1s"] = 1, ["3s"] = 3, infinite = -1 }
local FALL = { fast = 0.4, balanced = 0.9, smooth = 1.8 }
local HISTORY_SECONDS = { ["1s"] = 1, ["3s"] = 3 }
local FLOOR = -180

local function finite(value)
  return type(value) == "number" and value == value and math.abs(value) < math.huge
end

function spectrum.defaults()
  return { resolution = "balanced", speed = "balanced", smoothing = "1/12",
    average = "off", tilt = 4.5, range = 90,
    visual = "spectrum", split = 0.45 }
end

local function valid_option(key, value)
  if key == "split" then return finite(value) and value >= 0.2 and value <= 0.8 end
  for _, option in ipairs(spectrum.OPTIONS[key] or {}) do
    if value == option then return true end
  end
  return false
end

local function validate_preferences(value)
  if type(value) ~= "table" then return nil, "Saved spectrum settings are invalid." end
  local result = spectrum.defaults()
  for key in pairs(result) do
    if value[key] ~= nil then
      if not valid_option(key, value[key]) then return nil, "Saved spectrum settings are invalid." end
      result[key] = value[key]
    end
  end
  return result
end

function spectrum.encode(prefs)
  local result, err = validate_preferences(prefs)
  if not result then return nil, err end
  return json.encode({ version = 2, preferences = result })
end

function spectrum.decode(text)
  if text == nil or text == "" then return spectrum.defaults() end
  if type(text) ~= "string" then return nil, "Saved spectrum settings are invalid." end
  local ok, data = pcall(json.decode, text)
  if not ok or type(data) ~= "table" then return nil, "Saved spectrum settings are invalid." end
  if data.version ~= 1 and data.version ~= 2 then
    return nil, "Saved spectrum settings use an unsupported version."
  end
  -- Validation copies only supported preferences, migrating version-one
  -- settings without carrying the retired dotted hold into the new display.
  return validate_preferences(data.preferences)
end

local function refresh_flags(state)
  state.ready = state.math.ready
  state.average_ready = state.prefs.average ~= "off" and state.math.average_ready
  state.has_history = state.history_signal and state.average_ready or false
  local live_signal = false
  if state.ready then
    for index = 1, state.count do
      if (state.live[index] or FLOOR) > -120 then live_signal = true; break end
    end
  end
  state.live_visible = state.ready and ((state.playing == true and state.fresh)
    or (state.stop ~= nil and live_signal))
end

function spectrum.new(prefs)
  local validated, err = validate_preferences(prefs or spectrum.defaults())
  if not validated then return nil, err end
  local state = { prefs = validated, math = maths.new(512, FLOOR), count = 512,
    live = {}, average = {}, fmin = 10, fmax = 22050,
    sample_rate = 48000, epoch = 1, fresh = false, status = "waiting",
    history_signal = false, has_signal = false,
    playing = false, draining = false,
    history_epoch = 1, history_idle_seconds = 0,
    stop = nil,
    context_ready = false, target = nil }
  refresh_flags(state)
  return state
end

function spectrum.reset_history(state)
  maths.reset_history(state.math)
  state.history_epoch = state.history_epoch + 1
  state.history_idle_seconds = 0
  state.history_signal = false
  if state.stop then
    state.stop.average, state.stop.average_ready = {}, false
  end
  refresh_flags(state)
end

local function fresh_window(state, clear_history)
  if clear_history then spectrum.reset_history(state) end
  state.epoch = state.epoch + 1
  state.math.ready, state.target, state.fresh, state.has_signal = false, nil, false, false
  state.status = "waiting"
end

local function copy(source, destination, count)
  for index = 1, count do destination[index] = source[index] end
end

local function stopped_elapsed(state, dt, now)
  local stop = state.stop
  if not stop then return 0 end
  if finite(now) and finite(stop.started_at) then
    stop.elapsed = math.max(stop.elapsed, now - stop.started_at)
  else
    stop.elapsed = stop.elapsed + math.max(0, finite(dt) and dt or 0)
  end
  return stop.elapsed
end

local function refresh_stopped_display(state, elapsed)
  local stop = state.stop
  if not stop then return end
  state.math.average_ready = stop.average_ready and state.prefs.average ~= "off"
  maths.decay_power_trace(stop.live, state.live, state.count, FLOOR, elapsed,
    maths.power_release_seconds(20, FALL[state.prefs.speed]))
  local average_seconds = HISTORY_SECONDS[state.prefs.average]
  if average_seconds and stop.average_ready then
    maths.decay_power_trace(stop.average, state.average, state.count, FLOOR, elapsed,
      average_seconds / math.log(100))
    state.math.average_ready = true
  elseif state.prefs.average == "infinite" and stop.average_ready then
    copy(stop.average, state.average, state.count)
    state.math.average_ready = true
  end
  local history_maximum = FLOOR
  if stop.average_ready and state.prefs.average ~= "off" then
    for index = 1, state.count do
      history_maximum = math.max(history_maximum, state.average[index] or FLOOR)
    end
  end
  state.history_signal = history_maximum > -120
  state.math.ready = true
end

local function begin_stopped_display(state, now)
  local stop = { started_at = finite(now) and now or nil, elapsed = 0,
    live = {}, average = {}, average_ready = state.math.average_ready }
  copy(state.live, stop.live, state.count)
  copy(state.average, stop.average, state.count)
  state.stop = stop
end

-- A loop is still the same source in a playing state. The caller must not
-- manufacture stop events for timeline position wrapping back to the start.
function spectrum.set_context(state, source_key, playing, now)
  playing = playing == true
  local changed = state.context_ready and source_key ~= state.source_key
  local stopped = state.context_ready and state.playing and not playing
  local resumed = state.context_ready and not state.playing and playing
  if changed then
    state.draining = false
    state.stop = nil
    fresh_window(state, true)
  elseif stopped then
    if not state.stop then begin_stopped_display(state, now) end
  elseif resumed then
    state.draining = false
    if state.stop then
      stopped_elapsed(state, 0, now)
      state.history_idle_seconds = state.history_idle_seconds + state.stop.elapsed
      state.stop = nil
    end
    fresh_window(state, false)
  end
  state.source_key, state.playing, state.context_ready = source_key, playing, true
  refresh_flags(state)
end

function spectrum.helper_options(state)
  return { fft_size = FFT[state.prefs.resolution],
    smoothing_octaves = SMOOTHING[state.prefs.smoothing], epoch = state.epoch,
    capture_state = state.draining and 2 or (state.playing and 1 or 0),
    average_seconds = HELPER_HISTORY[state.prefs.average],
    history_epoch = state.history_epoch,
    -- The helper reconciles stopped time once, immediately before capture
    -- resumes. During the stop the fixed Lua snapshot owns visual decay.
    idle_seconds = state.history_idle_seconds }
end

function spectrum.begin_stop(state, now)
  if not state.context_ready or not state.playing then return false end
  begin_stopped_display(state, now)
  state.draining = true
  refresh_flags(state)
  return true
end

function spectrum.cancel_stop(state, now)
  if not state.draining then return false end
  state.draining = false
  if state.stop then
    stopped_elapsed(state, 0, now)
    state.history_idle_seconds = state.history_idle_seconds + state.stop.elapsed
    state.stop = nil
  end
  -- The helper may already have consumed its one finalisation request. Resume
  -- with a new capture epoch while retaining whichever history stop left behind.
  fresh_window(state, false)
  refresh_flags(state)
  return true
end

function spectrum.finish_stop(state)
  if not state.draining then return false end
  -- Advance capture identity without discarding the fixed final display. The
  -- old final publication may remain in shared memory until the device returns.
  state.epoch = state.epoch + 1
  state.fresh, state.target = false, nil
  state.playing, state.draining = false, false
  refresh_flags(state)
  return true
end

function spectrum.set_preference(state, key, value)
  if not valid_option(key, value) then return nil, "Choose a valid spectrum setting." end
  if state.prefs[key] == value then return true end
  state.prefs[key] = value
  -- Resolution changes keep the existing 512 logarithmic display bands while
  -- the helper gathers its first new FFT. Their frequency positions do not
  -- change, so blanking the live trace and history only creates a false jump.
  if key == "smoothing" then
    -- The helper can re-smooth its latest unsmoothed bands immediately. Keep
    -- Live visible during that handover, but discard histories measured with
    -- the previous smoothing width because they cannot be reversed accurately.
    spectrum.reset_history(state)
  elseif key == "average" then
    maths.reset_average(state.math)
    if state.stop then state.stop.average_ready, state.stop.average = false, {} end
  end
  refresh_flags(state)
  return true
end

local function valid_frame(frame)
  if type(frame) ~= "table" or not finite(frame.count) or frame.count < 1
    or frame.count > 512 or frame.count % 1 ~= 0 or type(frame.raw) ~= "table"
    or not finite(frame.fmin) or not finite(frame.fmax) or frame.fmin <= 0
    or frame.fmax <= frame.fmin or not finite(frame.sample_rate)
    or frame.sample_rate <= 0 or frame.fmax > frame.sample_rate * 0.5 then return false end
  for index = 1, frame.count do
    if not finite(frame.raw[index]) or frame.raw[index] < -240 or frame.raw[index] > 120 then return false end
  end
  return true
end

local function valid_history(frame, key)
  local values = frame[key]
  if type(values) ~= "table" then return false end
  for index = 1, frame.count do
    if not finite(values[index]) or values[index] < -240 or values[index] > 120 then
      return false
    end
  end
  return true
end

function spectrum.update(state, frame, dt, context)
  context = context or {}
  local elapsed_dt = finite(dt) and math.max(0, dt) or 0
  dt = math.min(0.5, elapsed_dt)
  if context.source_key ~= nil or context.playing ~= nil then
    spectrum.set_context(state, context.source_key or state.source_key,
      context.playing == nil and state.playing or context.playing, context.now)
  end
  local status = context.status
  if frame then
    if not valid_frame(frame) or not valid_history(frame, "average")
        or type(frame.average_ready) ~= "boolean" then
      status = "invalid"
    elseif frame.epoch ~= state.epoch then
      state.fresh, state.target, state.has_signal = false, nil, false
      status = "waiting"
    else
      if frame.count ~= state.count or frame.fmin ~= state.fmin
        or frame.fmax ~= state.fmax or frame.sample_rate ~= state.sample_rate then
        state.math = maths.new(frame.count, FLOOR)
        -- The helper has already reset and supplied the first history for its
        -- new geometry. Do not advance history_epoch again and discard it.
        state.history_signal = false
        state.live, state.average = {}, {}
      end
      state.count, state.fmin, state.fmax = frame.count, frame.fmin, frame.fmax
      state.sample_rate, state.sequence = frame.sample_rate, frame.sequence
      state.target = state.target or {}
      local maximum = FLOOR
      for index = 1, frame.count do
        state.target[index] = frame.raw[index]
        maximum = math.max(maximum, frame.raw[index])
      end
      state.has_signal = maximum > -120
      state.fresh, status = true, "ready"

      if state.stop and frame.final and frame.sequence ~= state.stop.final_sequence then
        state.stop.final_sequence = frame.sequence
        for index = 1, frame.count do
          state.stop.live[index] = math.max(state.stop.live[index] or FLOOR,
            frame.raw[index])
          state.stop.average[index] = frame.average[index]
        end
        state.stop.average_ready = frame.average_ready == true
      end
    end
  end
  if status == "stale" or status == "unavailable" or status == "invalid" then
    state.fresh, state.target, state.has_signal = false, nil, false
  end
  state.status = status or state.status
  if state.stop then
    refresh_stopped_display(state, stopped_elapsed(state, elapsed_dt, context.now))
  elseif state.playing and state.fresh and state.target then
    maths.update(state.math, state.target, dt, {
      motion_mode = "power", attack_seconds = 0.012,
      release_seconds = maths.power_release_seconds(20, FALL[state.prefs.speed]),
      average_seconds = nil, peak_hold_seconds = nil,
    })
    if frame then
      local history_maximum = FLOOR
      for index = 1, state.count do
        state.average[index] = frame.average[index]
        history_maximum = math.max(history_maximum, frame.average[index])
      end
      state.math.average_ready = frame.average_ready == true
      state.history_signal = history_maximum > -120
    end
  end
  for index = 1, state.count do
    if not state.stop then state.live[index] = state.math.live[index] end
  end
  refresh_flags(state)
  return state
end

return spectrum
