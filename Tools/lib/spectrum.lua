-- REAPER-facing spectrum coordination. The existing filter adapter alone owns
-- the shared helper and gmem attachment; this module never installs another FX.
local core = require('core.spectrum')
local filter = require('core.monitor_filter')
local helper = require('monitor_filter')
local stereo_core = require('core.stereo')
local stereo_raster = require('core.stereo_raster')
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
  local channels = state.analysis_preview_partial and state.preview_analysis_profile or state.analysis_output_profile or state.analysis_channels
  if channels then
    options.channel_count = channels.count
    options.outputs = channels.outputs
    options.channel_signature = channels.signature
    options.pair_left = channels.pair_left
    options.pair_right = channels.pair_right
    -- An available output set can move a surviving pair, or lose one side.
    if channels.pair_available==false then
      options.stereo_enabled = false
      options.pair_left, options.pair_right = 1, math.min(2,channels.count)
    elseif state.analysis_preview_partial and channels.pair_available~=true then
      local selected = state.analysis_output_profile or state.analysis_channels
      local pair_available = selected and selected.pair_left <= channels.count and selected.pair_right <= channels.count
      if pair_available then
        options.pair_left, options.pair_right = selected.pair_left, selected.pair_right
      else
        options.stereo_enabled = false
        options.pair_left, options.pair_right = 1, math.min(2,channels.count)
      end
    end
  else
    options.channel_count, options.channel_signature = 2, ''
    options.pair_left, options.pair_right = 1, 2
  end
  if state.analysis_channel_blocked then
    options.capture_state, options.stereo_enabled = 0, false
  end
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
  if reaper.GetExtState(SECTION, FILTER_KEY) ~= text then
    return nil, "Couldn't save the filter range."
  end
  return true
end

function spectrum.save(model)
  if model.preference_error then return nil, model.preference_error end
  local text, err = core.encode(model.prefs)
  if not text then return nil, err end
  reaper.SetExtState(SECTION, SPECTRUM_KEY, text, true)
  return true
end

local function channel_source(state, source)
  local channels = state.analysis_output_profile or state.analysis_channels
  if not channels then return source end
  return source .. ':channels:' .. tostring(channels.count) .. ':' .. tostring(channels.signature)
    .. (state.analysis_channel_blocked and not state.analysis_channel_route_checking and ':blocked' or '')
end

local function stereo_source(state, source)
  local channels = state.analysis_output_profile or state.analysis_channels
  if channels and channels.pair_signature then return source..':pair:'..channels.pair_signature end
  return source .. ':pair:' .. tostring(channels and channels.pair_left or 1)
    .. ':' .. tostring(channels and channels.pair_right or 2)
end

local function preview_source(state, slot, sound_id)
  local kind = state.analysis_preview_mixed and 'preview-mixed:' or 'preview:'
  return kind .. tostring(slot) .. ':' .. tostring(sound_id)
end

-- A stopped preview retains its identity, so a pause is not mistaken for a
-- source change. Starting project playback deliberately leaves that identity.
function spectrum.context(model, state, project_key, project_playing)
  local preview, reference = state.preview, state.reference
  local selection = tostring(state.selected_id or '')
  -- A Library audition or unlatched project playback keeps sounding when the
  -- Reference View selection changes, so it keeps the selection it started with.
  -- A stopped, paused or finished Library audition keeps its identity too, so
  -- the final measurement and Stereo Freeze survive until another source starts.
  local retained=tostring(model.context_source or '')
  local audition_slot=retained:match('^preview:([^:]+):')
    or retained:match('^preview%-mixed:([^:]+):')
  local stopped_audition = not preview.playing and not project_playing
    and model.held_selection ~= nil and audition_slot~=nil and audition_slot~='main'
  if (preview.playing and preview.slot ~= 'main') or stopped_audition
      or (not preview.playing and project_playing and not reference.latched) then
    model.held_selection = model.held_selection or selection
    selection = model.held_selection
  else
    model.held_selection = nil
  end
  local base = tostring(project_key) .. ':' .. selection .. ':' .. tostring(reference.latched == true)
  local source
  if preview.playing then
    source = preview_source(state, preview.slot, preview.sound_id)
  elseif (project_playing or state.analysis_live_input) and not reference.latched then source = 'project'
  elseif model.context_base == base then source = model.context_source
  else source = reference.latched and 'reference:' .. selection or 'project' end
  source = source or 'project'
  model.context_base, model.context_source = base, source
  return channel_source(state, base .. ':' .. source), not state.analysis_channel_blocked
    and (preview.playing == true or ((project_playing or state.analysis_live_input == true) and not reference.latched))
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
  local source = preview_source(state, slot, sound_id)
  model.context_base, model.context_source = base, source
  -- The new preview starts from the current selection, as base does.
  model.held_selection = nil
  local source_key = channel_source(state, base .. ':' .. source)
  if resuming and model.draining and model.source_key == source_key then
    core.cancel_stop(model, now)
  end
  -- Play starts a new measurement even for the same sound; Resume keeps it.
  core.set_context(model, source_key, not state.analysis_channel_blocked, now, not resuming)
  model.drain_deadline,model.route_capture_interrupted = nil,nil
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

local function tick_helper(state)
  local system = helper.tick(state.monitor_filter)
  if not system.available or system.range_error then
    state.monitor_filter.on, state.monitor_filter.selected_id = false, nil
  end
  state.monitor_filter.system = system
  return system
end

local function hold_for_route_check(state, model, source, active, now)
  if source ~= model.source_key then
    core.set_context(model, source, false, now, model.source_key ~= nil)
    model.route_capture_interrupted = nil
  end
  if model.playing or active then model.route_capture_interrupted = true end
  if model.playing and not model.draining then core.begin_stop(model, now) end
  if model.draining then core.finish_stop(model) end
  model.drain_deadline = nil
  local options = helper_options(state, model)
  options.capture_state, options.stereo_enabled = 0, false
  helper.configure_spectrum(options)
  local system = tick_helper(state)
  core.update(model, nil, model.last_time and now - model.last_time or 0,
    {status = 'waiting', now = now})
  model.last_time = now
  if active then model.live_visible = false end
  model.preview_capture_active = false
  local stereo = state.stereo
  if stereo then
    stereo.preview_capture_active = false
    stereo_core.update(stereo, nil, {source_key=stereo_source(state, source), epoch=model.epoch,
      measurement=model.measurement, session=stereo.session, status='waiting', now=now, playing=false})
  end
  return system
end

function spectrum.tick(state)
  local model = state.spectrum
  local now = reaper.time_precise()
  local project = reaper.EnumProjects(-1)
  -- Open-project and source identities remain observable while audio is closed.
  local project_key = project or ''
  local project_playing = project and (reaper.GetPlayStateEx(project) & 5) ~= 0 or false
  local source, playing = spectrum.context(model, state, project_key, project_playing)
  if state.stereo then
    local channels = state.analysis_output_profile or state.analysis_channels
    local captured = state.preview_analysis_profile or state.analysis_output_profile
    state.stereo.pair_unavailable = captured and (captured.pair_available==false
      or state.analysis_preview_partial==true and captured.pair_available==nil and channels
        and (channels.pair_left > captured.count or channels.pair_right > captured.count)) or false
  end
  if state.analysis_audio_suspended then
    if not model.context_ready or source ~= model.source_key then
      core.set_context(model, source, playing, now)
      model.drain_deadline,model.route_capture_interrupted = nil,nil
    end
    local stereo=state.stereo
    local pair_source=stereo_source(state,source)
    if stereo and stereo.source_key~=pair_source then
      stereo_core.update(stereo,nil,{source_key=pair_source,epoch=model.epoch,
        measurement=model.measurement,session=stereo.session,status='waiting',
        expecting_capture=false,now=now,playing=playing})
    end
    model.audio_suspended_at=model.audio_suspended_at or now
    model.audio_suspended,model.last_time=true,now
    model.preview_capture_active=false
    if state.stereo then
      state.stereo.preview_capture_active=false
    end
    -- Keep helper ownership serviced, but do not read old audio or turn a
    -- deliberately closed device into a missing-helper recovery action.
    local system=helper.tick(state.monitor_filter)
    state.monitor_filter.system=system
    return system
  end
  if model.audio_suspended then
    local elapsed=math.max(0,now-(model.audio_suspended_at or now))
    -- Device closure is a pause in display time, not a new source or a
    -- missed-publication timeout. User Freeze already owns its own clock.
    if model.stop and model.stop.started_at then model.stop.started_at=model.stop.started_at+elapsed end
    if model.capture_failure_since then model.capture_failure_since=model.capture_failure_since+elapsed end
    if model.drain_deadline then model.drain_deadline=model.drain_deadline+elapsed end
    local stereo=state.stereo
    if stereo then
      if not stereo.frozen then
        stereo_core.shift_time(stereo,elapsed)
        stereo_raster.shift_time(stereo.raster,elapsed)
      end
      if stereo.capture_failure_since then stereo.capture_failure_since=stereo.capture_failure_since+elapsed end
    end
    model.last_time=now
    model.audio_suspended_at=nil
    model.audio_suspended=nil
  end
  local checking=state.analysis_channel_route_checking==true
  local active=project_playing or state.analysis_live_input or state.preview.playing
  local still_stopped=model.route_capture_interrupted and not state.analysis_channel_blocked
    and not active and source==model.source_key
  if checking or still_stopped then
    return hold_for_route_check(state, model, source, active, now)
  end
  if model.route_capture_interrupted or not model.context_ready or source ~= model.source_key then
    -- A new source cancels any pending final frame from the old one.
    core.set_context(model, source, playing, now, model.route_capture_interrupted)
    model.drain_deadline,model.route_capture_interrupted = nil,nil
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
  local options = helper_options(state, model)
  helper.configure_spectrum(options)
  local system = tick_helper(state)
  if model.input_mapping_status ~= system.analysis_input_status then
    model.input_mapping_status = system.analysis_input_status
    -- Discard captured audio on both failure and recovery. A repaired pin map
    -- must not revive averages or scope packets from the wrong channels.
    core.set_context(model, source, playing, now, true)
    model.drain_deadline = nil
    helper.configure_spectrum(helper_options(state, model))
    helper.publish_spectrum_now()
  end
  local frame,status=helper.read_spectrum(now)
  if state.analysis_channel_blocked or system.analysis_input_status then
    frame,status=nil,'invalid'
  end
  local expecting = options.capture_state == 1 and system.phase == 'ready'
    and not system.analysis_input_status
    and not state.analysis_channel_blocked
  local expecting_stereo = expecting and options.stereo_enabled
  -- The filter limit gives a conservative sample-rate estimate for the first
  -- complete FFT, including on unusually low-rate devices.
  local sample_rate = (system.max_filter_hz or 20000) / 0.49
  local first_capture_delay = math.max(2, 1 + options.fft_size / math.max(1000, sample_rate))
  core.update(model, frame, model.last_time and now - model.last_time or 0,
    {status = status, now = now, expecting_capture=expecting, first_capture_delay=first_capture_delay})
  model.preview_capture_active = state.analysis_preview_partial == true and frame ~= nil and model.status == 'ready'
  if state.stereo then
    state.stereo.preview_capture_active = model.preview_capture_active
  end
  local stereo_backlog = false
  if state.stereo then
    local pair_source = stereo_source(state, source)
    local stereo_context = {source_key = pair_source, playing = playing, epoch = model.epoch,
      measurement = model.measurement,
      session = helper.session(), now = now,
      expecting_capture = expecting_stereo,
      first_capture_delay = first_capture_delay}
    -- Process immediately: the adapter reuses its staging arrays. Older
    -- captures need more catch-up work, but each UI tick has a fixed limit.
    for packet = 1, 8 do
      local stereo_frame, stereo_status
      if state.stereo.pair_unavailable then stereo_frame, stereo_status = nil, 'invalid'
      else stereo_frame, stereo_status = helper.read_stereo(now) end
      if state.analysis_channel_blocked or system.analysis_input_status then
        stereo_frame, stereo_status = nil, 'invalid'
      end
      stereo_context.status = stereo_status
      stereo_core.update(state.stereo, stereo_frame, stereo_context)
      if not stereo_frame then
        -- Packets queued behind a skipped one still belong to this stop.
        stereo_backlog = stereo_backlog or stereo_status == 'skipped'
        break
      end
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
