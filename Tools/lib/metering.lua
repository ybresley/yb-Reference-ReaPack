-- Coordinates live measurement without changing preview routing or project audio.
local session = require('core.meter_session')
local preferences = require('core.meter_preferences')
local warnings = require('core.meter_warnings')
local scale = require('core.meter_scale')
local meter_host = require('meter_host')
local metering = {}
local SECTION, KEY = 'yb-Reference', 'meter_preferences_v1'
local PRESET_KEY = 'meter_display_preset_v1'
local SESSION_KEYS = {auto_reset=true, seek_reset=true, loop_reset=true, keep_integrated=true, visible=true, view=true}
local module_path = debug.getinfo(1, 'S').source:sub(2)
local module_dir = module_path:match('^(.*)[/\\][^/\\]+$') or '.'
local root = module_dir:match('^(.*)[/\\][^/\\]+$') or '.'
local backend

local function measuring_enabled(state)
  -- Four-panel visibility belongs to the layout and does not stop a measurement
  -- run. Older layouts retain their separate meter-enable preference.
  return state.layout_prototype ~= nil or state.metering.prefs.visible
end

local function ensure(model)
  if model.attached then return true end
  if model.error then return false, model.error end
  backend = backend or meter_host.new(reaper, { crest_source = root .. '/Effects/yb-Reference_Meter.jsfx' })
  local ok, reason = backend:attach()
  model.attached, model.error = ok, ok and nil or reason
  if ok then
    -- Each controller session starts a fresh measurement, including a reused helper.
    session.reset(model)
    model.capture_mode, model.capture_epoch, model.measured_source = nil, nil, nil
    model.last_sequence, model.progress_at = nil, nil
  end
  return ok, reason
end

-- Live and recorded displays use the same bounded drawing buffers.
function metering.prepare_history_draw(model)
  model.history_points = model.history_points or reaper.new_array(session.HISTORY_LIMIT * 2)
  model.history_fill_points = model.history_fill_points or reaper.new_array((session.HISTORY_LIMIT + 2) * 2)
end

function metering.load()
  local prefs, err = preferences.decode(reaper.GetExtState(SECTION, KEY))
  local model = session.new()
  model.prefs = prefs or preferences.defaults()
  model.preference_error = err
  local saved = reaper.GetExtState(SECTION, PRESET_KEY)
  if saved ~= '' then
    model.saved_display_preset, model.display_preset_error = preferences.decode(saved)
  end
  model.attached, model.playing = false, false
  metering.prepare_history_draw(model)
  return model
end

local function save(model, prefs)
  local text, err = preferences.encode(prefs)
  if not text then return false, err end
  reaper.SetExtState(SECTION, KEY, text, true)
  model.prefs = prefs
  model.preferences_dirty = nil
  return true
end

function metering.save_display_preset(model)
  if model.preference_error then return false, model.preference_error end
  local text, err = preferences.encode(model.prefs)
  if not text then return false, err end
  reaper.SetExtState(SECTION, PRESET_KEY, text, true)
  model.saved_display_preset = preferences.decode(text)
  model.display_preset_error = nil
  return true
end

function metering.load_display_preset(model)
  if model.preference_error then return false, model.preference_error end
  if not model.saved_display_preset then
    return false, model.display_preset_error or 'Save a display preset first.'
  end
  local prefs = {}
  for key, value in pairs(model.saved_display_preset) do prefs[key] = value end
  for key in pairs(SESSION_KEYS) do prefs[key] = model.prefs[key] end
  return save(model, prefs)
end

function metering.reset_settings(model)
  local prefs = preferences.defaults()
  prefs.visible, prefs.view = model.prefs.visible, model.prefs.view
  local ok, err = save(model, prefs)
  if ok then model.preference_error = nil end
  return ok, err
end

function metering.reset_page(model, page)
  if model.preference_error then return false, model.preference_error end
  local prefs, err = preferences.reset_page(model.prefs, page)
  if not prefs then return false, err end
  return save(model, prefs)
end

function metering.set_preference(model, key, value, commit)
  if key == 'hold' then model.hold = value == true; return true end
  if model.preference_error then return false, model.preference_error end
  local changed, err = preferences.set(model.prefs, key, value)
  if err then return false, err end
  if commit == false then
    if changed then model.preferences_dirty = true end
    return changed
  end
  if not changed and not model.preferences_dirty then return false end
  local text, encode_error = preferences.encode(model.prefs)
  if not text then return false, encode_error end
  reaper.SetExtState(SECTION, KEY, text, true)
  model.preferences_dirty = nil
  return true
end

local function source(state, project, playing)
  local preview, reference = state.preview or {}, state.reference or {}
  if preview.playing then
    return tostring(project) .. ':preview:' .. tostring(preview.slot) .. ':' .. tostring(preview.sound_id), true, 1
  end
  return tostring(project) .. ':project', playing and not reference.latched, reference.latched and 2 or 0
end

local function reset_backend(model, mode)
  if not ensure(model) then return false, model.error end
  -- Reset measurements inside the existing helper. Adding or removing Monitor FX
  -- can block REAPER for seconds on some audio setups.
  local ok, reason = backend:configure(model.prefs, reaper.EnumProjects(-1))
  if ok then ok, reason = backend:capture(mode, true) end
  if not ok then model.error = reason; return false, reason end
  model.capture_epoch = nil
  model.last_sequence, model.progress_at = nil, nil
  return true
end

function metering.prepare_preview(state, slot, sound_id)
  local model = state.metering
  if not model or not measuring_enabled(state) then return true end
  local project = reaper.EnumProjects(-1)
  local key = tostring(project) .. ':preview:' .. tostring(slot) .. ':' .. tostring(sound_id)
  local fresh = not model.measured_source or model.prefs.auto_reset == 'On Play'
    or (model.prefs.auto_reset == 'New Reference' and model.measured_source ~= key)
  if fresh then
    if not reset_backend(model, 1) then return false, model.error end
    session.reset(model)
  else
    if not ensure(model) then return false, model.error end
    local ok, reason = backend:configure(model.prefs, project)
    if ok then ok, reason = backend:capture(1, false) end
    if not ok then model.error = reason; return false, reason end
  end
  model.source_key, model.measured_source = key, key
  model.playing, model.capture_mode = true, 1
  return true
end

function metering.transport_event(state, kind)
  local model = state.metering
  if not model or not measuring_enabled(state) then return true end
  local reset = kind == 'loop' and model.prefs.loop_reset == 'Start New Run'
  if reset then return metering.reset(state) end
  return true
end

function metering.reset(state)
  local model = state.metering
  if not model then return false end
  local ok, reason = reset_backend(model, model.capture_mode or 0)
  if ok then session.reset(model) end
  return ok, reason
end

function metering.clear_warnings(state)
  if state.metering then warnings.clear(state.metering.warnings) end
end

function metering.reconnect(state)
  local model = state.metering
  if not model then return false end
  if backend then
    -- A healthy reconnect reuses the sleeping helper. Replacement is reserved
    -- for an explicit recovery of a missing, incompatible or failed connection.
    local ok, reason
    if model.error and model.error ~= 'existing_instance' then
      ok, reason = backend:repair()
    else
      ok, reason = backend:close()
    end
    if not ok then model.error = reason; return false, reason end
  end
  backend = nil
  model.attached, model.error = false, nil
  model.source_key, model.capture_epoch, model.measured_source = nil, nil, nil
  local ok, reason = ensure(model)
  if ok or reason ~= 'existing_instance' then return ok, reason end
  -- Only an explicit Reconnect can reclaim helpers whose former owner is unknown.
  -- Automatic attachment must keep refusing them without changing Monitor FX.
  local choice = reaper.MB(
    'Meter effects from another yb-Reference session are still in Monitor FX.\n\n' ..
    'Close every other yb-Reference window before continuing. This will replace the ' ..
    'yb-Reference meter effects and start a new measurement.\n\n' ..
    'Continue only if this is the only yb-Reference window open.',
    'Reconnect Meters', 1)
  if choice ~= 1 then return false end
  ok, reason = backend:recover_leftovers()
  if not ok then model.error = reason; return false, reason end
  model.error = nil
  return ensure(model)
end

function metering.tick(state)
  local model = state.metering
  if not model then return end
  local now = reaper.time_precise()
  local dt = model.last_time and math.max(0, now - model.last_time) or 0
  model.last_time = now
  if not measuring_enabled(state) then
    if backend and model.attached then
      local ok, reason = backend:close()
      if not ok then model.error = reason end
      model.attached = false
    end
    model.playing = false
    return
  end
  if not ensure(model) then return end
  local project = reaper.EnumProjects(-1)
  local configured, configure_error = backend:configure(model.prefs, project)
  if not configured then model.error = configure_error; return end
  local project_playing = (reaper.GetPlayStateEx(project) & 1) ~= 0
  local key, playing, mode = source(state, project, project_playing)
  local changed = model.measured_source ~= nil and key ~= model.measured_source
  local started, stopped = playing and not model.playing, not playing and model.playing
  if stopped then
    -- A short preview can finish between drawing frames. Consume its last
    -- publication before marking playback stopped.
    local final = backend:poll()
    if final.pending_publication then return end
    if final.ready then
      final.playing = true
      session.update(model, final, dt)
      warnings.update(model.warnings, model.values, model.prefs, dt)
      session.animate(model, dt, scale.loudness(model.prefs))
    end
  end
  -- Project Play resets in the helper before sample one. Preview preparation
  -- requests its own reset before the routes start.
  if playing and changed and model.prefs.auto_reset == 'New Reference' then
    if not reset_backend(model, mode) then return end
    session.reset(model)
  elseif model.capture_mode ~= mode then
    local ok, reason = backend:capture(mode, false)
    if not ok then model.error = reason; return end
  end
  if started and model.prefs.auto_reset == 'On Play' then session.reset(model) end
  if playing then model.measured_source = key end
  model.source_key, model.playing, model.capture_mode = key, playing, mode
  local snapshot = backend:poll()
  snapshot.playing = playing
  if snapshot.ready then
    if playing and model.capture_epoch and snapshot.capture_epoch ~= model.capture_epoch then
      session.reset(model)
    end
    model.capture_epoch = snapshot.capture_epoch
    if model.last_sequence ~= snapshot.sequence then
      model.last_sequence, model.progress_at = snapshot.sequence, now
    elseif playing and model.progress_at and now - model.progress_at > 1.5 then
      snapshot.ready, snapshot.status = false, 'stalled'
    end
  end
  if snapshot.ready then model.error = nil
  elseif not snapshot.pending_publication then model.error = snapshot.status end
  session.update(model, snapshot, dt)
  warnings.update(model.warnings, model.values, model.prefs, dt)
  local floor = scale.loudness(model.prefs)
  session.animate(model, dt, floor)
end

function metering.shutdown()
  if not backend then return true end
  local ok, reason = backend:close()
  if ok then backend = nil end
  return ok, reason
end

return metering
