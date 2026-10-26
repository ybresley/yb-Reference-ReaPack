-- REAPER-facing spectrum coordination. The existing filter adapter alone owns
-- the shared helper and gmem attachment; this module never installs another FX.
local core = require('core.spectrum')
local filter = require('core.monitor_filter')
local helper = require('monitor_filter')
local stereo_core = require('core.stereo')
local layout_prototype = require('core.layout_prototype')
local spectrum = {}
local SECTION = 'yb-Reference'
local FILTER_KEY = 'monitor_filter_preferences_v1'
local SPECTRUM_KEY = 'spectrum_preferences_v2'
local LEGACY_SPECTRUM_KEY = 'spectrum_preferences_v1'
local FINAL_DRAIN_TIMEOUT = 0.5

local function stereo_enabled(state)
  local prototype = layout_prototype.current(state.layout_prototype)
  local panels = prototype and prototype.enabled
    or state.reference_panels and state.reference_panels.enabled
  if type(panels) ~= 'table' then return false end
  for i = 1, #panels do
    if panels[i] == 'stereo' then return true end
  end
  return false
end

local function helper_options(state, model)
  local options = core.helper_options(model)
  options.stereo_enabled = stereo_enabled(state)
  return options
end

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
function spectrum.prepare_preview(state, slot, sound_id, resuming)
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
  if resuming and model.draining and model.source_key == source_key then
    core.cancel_stop(model, now)
  end
  -- Play starts a new measurement even for the same sound; Resume keeps it.
  core.set_context(model, source_key, true, now, not resuming)
  model.drain_deadline = nil
  if not helper.configure_spectrum(helper_options(state, model)) then
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
  helper.configure_spectrum(helper_options(state, model))
  local system = helper.tick(state.monitor_filter)
  if not system.available or system.range_error then
    state.monitor_filter.on, state.monitor_filter.selected_id = false, nil
  end
  state.monitor_filter.system = system
  local frame, status = helper.read_spectrum(now)
  core.update(model, frame, model.last_time and now - model.last_time or 0,
    {status = status, now = now})
  local stereo_backlog = false
  if state.stereo then
    local stereo_context = {source_key = source, playing = playing, epoch = model.epoch,
      session = helper.session(), now = now}
    -- Process immediately: the adapter reuses its staging arrays. Older
    -- captures need more catch-up work, but each UI tick has a fixed limit.
    for packet = 1, 8 do
      local stereo_frame, stereo_status = helper.read_stereo(now)
      stereo_context.status = stereo_status
      stereo_core.update(state.stereo, stereo_frame, stereo_context)
      if not stereo_frame then break end
      stereo_backlog = not stereo_frame.final
      local age = math.max(0, now - (stereo_frame.at or now))
      if (packet >= 3 and age <= 0.35) or (packet >= 5 and age <= 1) then
        break
      end
    end
  end
  local drain_failed = status == 'unavailable' or status == 'stale' or status == 'invalid'
  if model.draining and ((frame and frame.final and frame.epoch == model.epoch
        and model.status == 'ready' and not stereo_backlog) or drain_failed
      or (model.drain_deadline and now >= model.drain_deadline)) then
    core.finish_stop(model)
    model.drain_deadline = nil
  end
  model.last_time = now
  return system
end

return spectrum
