local peaks = require("peaks")
local detail = require("wave_detail")
local holders = require("holders")

local wave = {}

function wave.refresh_detail(state, sound_path)
  if not state.selected_id or not state.wave_cols then return end
  if state.waveform.sound_id ~= state.selected_id then return end
  -- Keep one high-resolution grid for the visible time range. Regrouping audio
  -- for every panel width changes peak boundaries while a resize is in flight.
  local cols = detail.columns(math.huge)
  local current = state.wave_detail
  if current.sound_id == state.selected_id and current.cols == cols
    and current.t0 == state.wave_view.t0 and current.t1 == state.wave_view.t1 then
    current.width = state.wave_cols
    return
  end
  -- A refused removal keeps the finished envelope but releases its file reader.
  -- Reopen here so detail does not depend on another envelope build completing.
  local channels, count, read_error, timing
  if detail.current() ~= state.selected_id
    and not detail.open(state.selected_id, sound_path(state.selected)) then
    read_error = "Waveform detail couldn't be opened."
  else
    channels, count, read_error, timing = detail.read(state.selected_id,
      state.wave_view.t0, state.wave_view.t1, cols)
  end
  if channels then
    state.wave_detail = { sound_id = state.selected_id, channels = channels, count = count,
      cols = cols, width = state.wave_cols, t0 = state.wave_view.t0, t1 = state.wave_view.t1,
      timing = timing }
  else
    -- Remember this failed request so the defer loop does not hammer the same
    -- host read every frame. The viewer rejects the empty detail and keeps the
    -- valid whole-file envelope on screen.
    state.wave_detail = { sound_id = state.selected_id, channels = {}, count = 0,
      cols = cols, width = state.wave_cols, t0 = state.wave_view.t0, t1 = state.wave_view.t1 }
    if read_error then state.status = read_error .. " Showing the overview instead." end
  end
end

function wave.refresh_browse_detail(state, sound_path, id, width)
  if not id or id ~= state.browse_id or not width or not state.browse then return end
  if state.browse_waveform.sound_id ~= id then return end
  local cols = detail.columns(math.huge)
  local cached = state.browse_detail
  if cached and cached.sound_id == id and cached.cols == cols then
    cached.width = width
    return
  end
  -- Read once per selection, releasing the file before removal can run.
  local reader = detail.new()
  local channels, count, err, timing
  if reader.open(id, sound_path(state.browse)) then
    channels, count, err, timing = reader.read(id, 0, 1, cols)
  else
    err = "Waveform detail couldn't be opened."
  end
  reader.close()
  state.browse_detail = { sound_id = id, channels = channels or {}, count = count or 0,
    cols = cols, width = width, t0 = 0, t1 = 1, timing = timing }
  if err then state.status = err .. " Showing the overview instead." end
end

-- Both views can consume the same completed envelope without another file read.
local function deliver(state, sound_path, id, channels)
  if not id then return end
  if id == state.selected_id then
    state.waveform = { sound_id = id, channels = channels }
    wave.refresh_detail(state, sound_path)
  end
  if id == state.browse_id then
    state.browse_waveform = { sound_id = id, channels = channels }
  end
end

-- A deliberate re-pick permits retry. Cached envelopes can appear immediately,
-- but a selection must never replace the other view's unfinished build.
function wave.selected(state, sound_path)
  holders.forget_wave("main")
  if not state.selected or peaks.pending() then return end
  peaks.request(state.selected_id, sound_path(state.selected))
  holders.mark_wave("main", state.selected_id)
  deliver(state, sound_path, peaks.advance())
end

function wave.step(state, sound_path)
  state.wave_loading = peaks.pending()
  deliver(state, sound_path, peaks.advance())
  if peaks.pending() then return end
  local id, sound, slot
  -- Already attempted failures are ineligible before choosing a view, so a
  -- missing reference cannot keep the Library behind it indefinitely.
  if state.selected and state.waveform.sound_id ~= state.selected_id
    and holders.wave_asked("main") ~= state.selected_id then
    id, sound, slot = state.selected_id, state.selected, "main"
  elseif state.browse and state.browse_waveform.sound_id ~= state.browse_id
    and holders.wave_asked("browse") ~= state.browse_id then
    id, sound, slot = state.browse_id, state.browse, "browse"
  end
  if id then
    holders.mark_wave(slot, id)
    peaks.request(id, sound_path(sound))
  end
end

return wave
