-- REAPER-facing spectrum coordination. The existing filter adapter alone owns
-- the shared helper and gmem attachment; this module never installs another FX.
local core = require('core.spectrum')
local filter = require('core.monitor_filter')
local helper = require('monitor_filter')
local spectrum = {}
local SECTION = 'yb-Reference'
local FILTER_KEY = 'monitor_filter_preferences_v1'
local SPECTRUM_KEY = 'spectrum_preferences_v2'
local LEGACY_SPECTRUM_KEY = 'spectrum_preferences_v1'
local FINAL_DRAIN_TIMEOUT = 0.5

function spectrum.load()
  local filter_text = reaper.GetExtState(SECTION, FILTER_KEY)
  local value, filter_error
  if filter_text == '' then value = filter.decode(helper.get_saved_settings())
  else value, filter_error = filter.decode_preferences(filter_text) end
  value = value or filter.defaults()
  value.preference_error = filter_error
  local spectrum_text = reaper.GetExtState(SECTION, SPECTRUM_KEY)
  -- Preserve the old record so older releases can still read their settings.
  if spectrum_text == '' then spectrum_text = reaper.GetExtState(SECTION, LEGACY_SPECTRUM_KEY) end
  local prefs, err = core.decode(spectrum_text)
  local model = core.new(prefs or core.defaults())
  model.preference_error = err
  if reaper.new_array then model.draw = {batch = reaper.new_array(2048)} end
  return value, model
end

function spectrum.save_filter(value)
  if value.preference_error then return nil, value.preference_error end
  local text, err = filter.encode_preferences(value)
  if not text then return nil, err end
  reaper.SetExtState(SECTION, FILTER_KEY, text, true)
  return true
end

function spectrum.save(model)
  if model.preference_error then return nil, model.preference_error end
  local text, err = core.encode(model.prefs)
  if not text then return nil, err end
  reaper.SetExtState(SECTION, SPECTRUM_KEY, text, true)
  return true
end

-- A stopped preview retains its identity, so a pause is not mistaken for a
-- source change. Starting project playback deliberately leaves that identity.
function spectrum.context(model, state, project_key, project_playing)
  local preview, reference = state.preview, state.reference
  local selection = tostring(state.selected_id or '')
  local base = tostring(project_key) .. ':' .. selection .. ':' .. tostring(reference.latched == true)
  local source
  if preview.playing then
    source = 'preview:' .. tostring(preview.slot) .. ':' .. tostring(preview.sound_id)
  elseif project_playing and not reference.latched then source = 'project'
  elseif model.context_base == base then source = model.context_source
  else source = reference.latched and 'reference:' .. selection or 'project' end
  source = source or 'project'
  model.context_base, model.context_source = base, source
  return base .. ':' .. source, preview.playing == true or (project_playing and not reference.latched)
end

-- Called by preview.lua after an old preview has been released but before the
-- replacement routes start. That gives the helper the correct capture epoch for
-- very short sounds without attributing a departing source to its successor.
function spectrum.prepare_preview(state, slot, sound_id)
  local model = state.spectrum
  local now = reaper.time_precise()
  local project = reaper.EnumProjects(-1)
  local project_key = project or ''
  local reference = state.reference
  local base = tostring(project_key) .. ':' .. tostring(state.selected_id or '')
    .. ':' .. tostring(reference.latched == true)
  local source = 'preview:' .. tostring(slot) .. ':' .. tostring(sound_id)
  model.context_base, model.context_source = base, source
  local source_key = base .. ':' .. source
  if model.draining and model.source_key == source_key then
    core.cancel_stop(model, now)
  end
  core.set_context(model, source_key, true, now)
  if not helper.configure_spectrum(core.helper_options(model)) then
    model.status = 'invalid'
    return false
  end
  if helper.publish_spectrum_now and not helper.publish_spectrum_now() then
    model.status = 'invalid'
    return false
  end
  return true
end

function spectrum.tick(state)
  local model = state.spectrum
  local now = reaper.time_precise()
  local project = reaper.EnumProjects(-1)
  -- History is session-local: the open project reference distinguishes tabs,
  -- including unsaved projects, without requiring a separate GUID lookup.
  local project_key = project or ''
  local project_playing = project and (reaper.GetPlayStateEx(project) & 1) == 1 or false
  local source, playing = spectrum.context(model, state, project_key, project_playing)
  if not model.context_ready or source ~= model.source_key then
    -- A new source cancels any pending final frame from the old one.
    core.set_context(model, source, playing, now)
    model.drain_deadline = nil
  elseif model.draining then
    if playing then
      core.cancel_stop(model, now)
      model.drain_deadline = nil
    end
  elseif model.playing and not playing then
    if core.begin_stop(model, now) then model.drain_deadline = now + FINAL_DRAIN_TIMEOUT end
  elseif not model.playing and playing then
    core.set_context(model, source, true, now)
  end
  helper.configure_spectrum(core.helper_options(model))
  local system = helper.tick(state.monitor_filter)
  if not system.available or system.range_error then
    state.monitor_filter.on, state.monitor_filter.selected_id = false, nil
  end
  state.monitor_filter.system = system
  local frame, status = helper.read_spectrum(now)
  core.update(model, frame, model.last_time and now - model.last_time or 0,
    {status = status, now = now})
  local drain_failed = status == 'unavailable' or status == 'stale' or status == 'invalid'
  if model.draining and ((frame and frame.final and frame.epoch == model.epoch
        and model.status == 'ready') or drain_failed
      or (model.drain_deadline and now >= model.drain_deadline)) then
    core.finish_stop(model)
    model.drain_deadline = nil
  end
  model.last_time = now
  return system
end

return spectrum
