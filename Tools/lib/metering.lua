-- Coordinates live measurement without changing preview routing or project audio.
local session = require('core.meter_session')
local preferences = require('core.meter_preferences')
local warnings = require('core.meter_warnings')
local scale = require('core.meter_scale')
local meter_host = require('meter_host')
local recording_active = require('reaper_api').recording_active
local metering = {}
local SECTION, KEY = 'yb-Reference', 'meter_preferences_v1'
local PRESET_KEY = 'meter_display_preset_v1'
local SESSION_KEYS = {auto_reset=true, seek_reset=true, loop_reset=true, keep_integrated=true, visible=true, view=true}
local module_path = debug.getinfo(1, 'S').source:sub(2)
local module_dir = module_path:match('^(.*)[/\\][^/\\]+$') or '.'
local root = module_dir:match('^(.*)[/\\][^/\\]+$') or '.'
local backend
local ATTACH_RETRY_SECONDS = 1
local RETRY_ATTACH = {no_master=true,configuration_failed=true,bypassed=true,offline=true,waiting=true,
  input_mapping_changed=true,input_mapping_unverified=true}
local INSTALL_FAILURE={crest_install_conflict=true,crest_install_failed=true,
  crest_source_unreadable=true,crest_restore_failed=true}
local STARTUP_TIMEOUT = 3
local UPDATE_TIMEOUT = 1.5

local function measuring_enabled(state)
  -- Four-panel visibility belongs to the layout and does not stop a measurement
  -- run. Older layouts retain their separate meter-enable preference.
  return state.layout_prototype ~= nil or state.metering.prefs.visible
end

local function ensure(model)
  if model.attached then return true end
  local recording_wait = model.error == 'recording'
  local retry = model.error ~= nil and model.error ~= 'initializing'
  if retry and not recording_wait and (not RETRY_ATTACH[model.error]
      or not backend or not backend.retry_attach) then
    return false, model.error
  end
  local now = reaper.time_precise()
  if recording_wait then model.startup_at = nil end
  if not retry then
    model.startup_at = model.startup_at or now
    if now - model.startup_at >= STARTUP_TIMEOUT then
      model.error = 'startup_failed'
      return false, model.error
    end
  end
  if retry and model.next_attach_retry and now < model.next_attach_retry then
    return false, model.error
  end
  backend = backend or meter_host.new(reaper, { crest_source = root .. '/Effects/yb-Reference_Meter.jsfx' })
  -- A transient connection failure may recheck the saved helper, but retries
  -- never install, remove, enable or replace an effect in Monitor FX.
  local ok, reason
  if recording_wait then ok, reason = backend:attach()
  elseif retry then ok, reason = backend:retry_attach()
  else ok, reason = backend:attach() end
  model.attached, model.error = ok, ok and nil or reason
  model.next_attach_retry = not ok and now + ATTACH_RETRY_SECONDS or nil
  if ok then
    model.startup_at = nil
    -- Each controller session starts a fresh measurement, including a reused helper.
    session.reset(model)
    model.capture_mode, model.capture_epoch, model.measured_source = nil, nil, nil
    model.last_sequence, model.progress_at, model.stall_retry_deadline = nil, nil, nil
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
  if reaper.GetExtState(SECTION, KEY) ~= text then return false, "Couldn't save Loudness settings." end
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
  model.preference_reset_error = err
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
  if not text then
    -- Not left pending: a closed settings panel resends a pending value every
    -- frame, which would raise this failure again on every frame.
    model.preferences_dirty = nil
    return false, encode_error
  end
  reaper.SetExtState(SECTION, KEY, text, true)
  model.preferences_dirty = nil
  return true
end

local function preview_key(project, slot, sound_id, mixed)
  return tostring(project) .. ':preview:' .. tostring(slot) .. ':' .. tostring(sound_id)
    .. (mixed and ':mixed' or '')
end

local function source(state, project, playing)
  local preview, reference = state.preview or {}, state.reference or {}
  if preview.playing then
    return preview_key(project, preview.slot, preview.sound_id, state.analysis_preview_mixed), true, 1
  end
  local live = state.analysis_live_input == true
  local mode = 0
  if live and not playing then
    mode = backend and backend.supports_stopped_monitoring and backend:supports_stopped_monitoring() and 3 or 1
  end
  local key = tostring(project) .. ':project'
  if reference.latched then return key, false, 2 end
  return key, playing or live, mode
end

local function mix_changed(model, mixed)
  return model.measured_source ~= nil and (model.measured_preview_mixed == true) ~= mixed
end

local function apply_channel_profile(state)
  local model=state.metering
  local profile=state.analysis_output_profile or state.analysis_channels
  local capture=state.preview_analysis_profile or profile
  local signature=capture and capture.signature or 'stereo'
  if model.channel_signature and model.channel_signature~=signature then
    session.reset(model)
    model.capture_epoch,model.last_sequence,model.progress_at=nil,nil,nil
  end
  model.channel_profile,model.channel_signature=profile,signature
  model.capture_profile=capture
  model.preview_capture_active=state.analysis_preview_partial==true
  model.measured_channel_count=capture and capture.count
  model.loudness_available=not capture or capture.known~=false
end

local function channel_capture_blocked(state)
  local model=state.metering
  if state.analysis_channel_blocked then
    if not model.channel_blocked then
      if backend and model.attached then
        local ok,reason=backend:close()
        if not ok then model.error=reason; return true end
      end
      session.reset(model)
      model.attached,model.playing=false,false
    end
    model.channel_blocked,model.error=true,'channel_profile_required'
    return true
  end
  if model.channel_blocked then model.channel_blocked,model.error=nil,nil end
  return false
end

local function reset_backend(model, mode)
  if not ensure(model) then return false, model.error end
  -- Reset measurements inside the existing helper. Adding or removing Monitor FX
  -- can block REAPER for seconds on some audio setups.
  local ok, reason = backend:configure(model.prefs, reaper.EnumProjects(-1),model.capture_profile)
  if ok then ok, reason = backend:capture(mode, true) end
  if not ok then model.error = reason; return false, reason end
  model.capture_epoch = nil
  model.last_sequence, model.progress_at, model.stall_retry_deadline = nil, nil, nil
  return true
end

local function hold_for_route_check(model, project, active, dt)
  local park = active == true or model.playing == true
    or model.route_hold_project ~= nil and model.route_hold_project == project
  if model.attached then
    local ok, reason = backend:hold_capture(park)
    if not ok then model.error = reason end
  end
  if park then
    model.route_hold_project, model.capture_mode = project, nil
  end
  if model.playing then
    -- Retire the last checked live values without dropping completed history.
    session.update(model, {ready=model.valid, playing=false, status='waiting'}, dt)
    session.animate(model, dt, scale.loudness(model.prefs))
    model.playing = false
  end
  model.startup_at, model.stop_pending_at, model.progress_at, model.stall_retry_deadline = nil, nil, nil, nil
end

local function check_progress(model, snapshot, mode, now)
  if snapshot.ready and model.last_sequence ~= snapshot.sequence then
    model.last_sequence, model.progress_at, model.stall_retry_deadline = snapshot.sequence, now, nil
  end
  if not snapshot.playing then model.progress_at = nil end
  if not (snapshot.ready or snapshot.pending_publication or snapshot.status == 'waiting') then return end
  if snapshot.playing and not model.stall_retry_deadline then
    model.progress_at = model.progress_at or now
    if now - model.progress_at > UPDATE_TIMEOUT then
      -- Recheck the same saved identity and renew its command without touching
      -- Monitor FX or losing its run. Only a new audio publication proves recovery.
      local connected = backend:retry_attach() and backend:capture(mode, false)
      model.stall_retry_deadline = connected and now + UPDATE_TIMEOUT or now
    end
  end
  if model.stall_retry_deadline then
    snapshot.ready, snapshot.pending_publication = false, false
    snapshot.status = snapshot.playing and now >= model.stall_retry_deadline and 'stalled' or 'waiting'
    if not snapshot.playing then model.stall_retry_deadline = nil end
  end
end

function metering.prepare_preview(state, slot, sound_id)
  local model = state.metering
  if not model or not measuring_enabled(state) then return true end
  apply_channel_profile(state)
  if channel_capture_blocked(state) then return true end
  local project = reaper.EnumProjects(-1)
  local mixed = state.analysis_preview_mixed == true
  local key = preview_key(project, slot, sound_id, mixed)
  local fresh = model.force_source_reset or model.route_hold_project or not model.measured_source
    or mix_changed(model, mixed)
    or model.prefs.auto_reset == 'On Play'
    or (model.prefs.auto_reset == 'New Reference' and model.measured_source ~= key)
  if fresh then
    if not reset_backend(model, 1) then return false, model.error end
    model.force_source_reset,model.route_hold_project=nil,nil
    session.reset(model)
  else
    if not ensure(model) then return false, model.error end
    local ok, reason = backend:configure(model.prefs, project,model.capture_profile)
    if ok then ok, reason = backend:capture(1, false) end
    if not ok then model.error = reason; return false, reason end
  end
  model.source_key, model.measured_source = key, key
  model.measured_preview_mixed = mixed
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
  if model.recording_reconnect and not recording_active(reaper) then
    model.error = model.recording_reconnect.reason
    model.recording_reconnect = nil
  end
  local recovery_reason = model.error
  local function failed(reason)
    -- Stop polling a refused connection so its recovery instruction stays visible.
    model.attached = false
    if reason == 'recording' then model.recording_reconnect = {reason=recovery_reason} end
    model.error = reason == 'changed' and 'repair_refused' or reason
    return false, model.error
  end
  if model.error=='unsupported_sample_rate' then
    return false,model.error
  end
  local reason=state.analysis_channel_blocked and 'channel_profile_required' or model.error
  local installer_retry=INSTALL_FAILURE[model.error]==true
  -- Replacing effects cannot repair the project's layout or user-owned input routing.
  if reason=='channel_profile_required' or reason=='channels_unavailable'
      or reason=='input_mapping_changed' or reason=='input_mapping_unverified' then
    model.error=reason
    return false,reason
  end
  if (model.error or not model.attached) and recording_active(reaper) then
    model.recording_reconnect = model.recording_reconnect or {reason=model.error}
    model.attached, model.error = false, 'recording'
    return false, 'recording'
  end
  model.startup_at = nil
  session.reset(model)
  if backend then
    -- A healthy reconnect reuses the sleeping helper. Replacement is reserved
    -- for an explicit recovery of a missing, incompatible or failed connection.
    local ok, reason
    if model.error and model.error ~= 'existing_instance' and model.error ~= 'initializing'
      and model.error ~= 'startup_failed' and not installer_retry then
      ok, reason = backend:repair()
    else
      ok, reason = backend:close()
    end
    if not ok then return failed(reason) end
  end
  backend = nil
  model.attached, model.error = false, nil
  model.source_key, model.capture_epoch, model.measured_source = nil, nil, nil
  local ok, reason = ensure(model)
  if ok then return true end
  if reason ~= 'existing_instance' or installer_retry then return failed(reason) end
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
  if not ok then return failed(reason) end
  model.error = nil
  -- Time spent reading the confirmation is not helper startup time.
  model.startup_at, model.next_attach_retry = nil, nil
  ok, reason = ensure(model)
  if not ok then return failed(reason) end
  return true
end

function metering.tick(state)
  local model = state.metering
  if not model then return end
  local now = reaper.time_precise()
  local dt = model.last_time and math.max(0, now - model.last_time) or 0
  model.last_time = now
  local project = reaper.EnumProjects(-1)
  local project_playing = project and (reaper.GetPlayStateEx(project) & 5) ~= 0 or false
  local project_changed=model.source_project~=nil and model.source_project~=project
  model.source_project=project
  if state.analysis_audio_suspended then
    local key,playing=source(state,project,project_playing)
    -- Stopping a preview retains its measurement until another source starts.
    if not playing and not project_changed then key=model.source_key or key end
    local profile=state.preview_analysis_profile or state.analysis_output_profile or state.analysis_channels
    local signature=profile and profile.signature or 'stereo'
    local changed=project_changed or model.source_key~=nil and model.source_key~=key
      or model.channel_signature~=nil and model.channel_signature~=signature
    if changed then
      session.reset(model)
      model.capture_epoch,model.last_sequence,model.progress_at,model.stall_retry_deadline=nil,nil,nil,nil
      model.stop_pending_at,model.route_hold_project=nil,nil
      model.measured_source,model.measured_preview_mixed=nil,nil
      -- Retire incompatible readings now; renew the helper capture after audio resumes.
      model.playing,model.force_source_reset=false,true
    end
    apply_channel_profile(state)
    model.source_key=key
    model.audio_suspended_at=model.audio_suspended_at or now
    model.preview_capture_active=false
    return
  end
  if model.audio_suspended_at then
    local elapsed=math.max(0,now-model.audio_suspended_at)
    -- Device closure does not consume helper startup or final-publication time.
    for _,key in ipairs({'startup_at','next_attach_retry','progress_at','stall_retry_deadline','stop_pending_at'}) do
      if model[key] then model[key]=model[key]+elapsed end
    end
    model.audio_suspended_at=nil
    dt=0
  end
  if not measuring_enabled(state) then
    model.startup_at = nil
    model.route_hold_project=nil
    if model.error == 'initializing' then model.error = nil end
    if backend and model.attached then
      local ok, reason = backend:close()
      if not ok then model.error = reason end
      model.attached = false
    end
    model.playing = false
    return
  end
  local checking=state.analysis_channel_route_checking==true
  local active=project_playing or state.analysis_live_input or (state.preview and state.preview.playing)
  local profile=state.preview_analysis_profile or state.analysis_channels
  local still_stopped=model.route_hold_project~=nil and model.route_hold_project==project and not active
    and not state.analysis_channel_blocked and model.channel_signature==(profile and profile.signature or 'stereo')
  if checking or still_stopped then
    hold_for_route_check(model, project, active, dt)
    return
  end
  apply_channel_profile(state)
  if channel_capture_blocked(state) then model.route_hold_project=nil; return end
  if model.recording_reconnect then
    if recording_active(reaper) then return end
    local connected = metering.reconnect(state)
    if not connected then return end
  end
  if not ensure(model) then return end
  local configured, configure_error = backend:configure(model.prefs, project,model.capture_profile)
  if configure_error == 'control_incompatible' and backend:reclaim() then
    -- The same meter reloaded in place and lost its run; start measuring again
    -- exactly as after a fresh attach.
    session.reset(model)
    model.capture_mode, model.capture_epoch, model.measured_source = nil, nil, nil
    model.last_sequence, model.progress_at = nil, nil
    configured, configure_error = backend:configure(model.prefs, project,model.capture_profile)
  end
  if not configured then
    model.error = configure_error; return
  end
  local key, playing, mode = source(state, project, project_playing)
  local mixed = mode == 1 and state.analysis_preview_mixed == true
  local changed = model.measured_source ~= nil and key ~= model.measured_source
  local started, stopped = playing and not model.playing, not playing and model.playing
  if stopped and not model.stall_retry_deadline then
    -- A short preview can finish between drawing frames. Consume its last
    -- publication before marking playback stopped.
    local final = backend:poll()
    if final.pending_publication then
      model.stop_pending_at = model.stop_pending_at or now
      if now - model.stop_pending_at < UPDATE_TIMEOUT then return end
    end
    if final.ready then
      if model.capture_epoch and final.capture_epoch ~= model.capture_epoch then
        session.reset(model)
      end
      model.capture_epoch = final.capture_epoch
      final.playing = true
      session.update(model, final, dt)
      warnings.update(model.warnings, model.values, model.prefs, dt)
      session.animate(model, dt, scale.loudness(model.prefs))
    end
  end
  model.stop_pending_at = nil
  -- Project Play resets in the helper before sample one. A change in the mix
  -- during preview needs a separate reset so its samples never share a run.
  local legacy_monitor_restart = project_playing and mode == 0 and model.capture_mode == 1
    and not changed and model.prefs.auto_reset == 'On Play'
  if model.force_source_reset or model.route_hold_project or (playing and mix_changed(model, mixed)) then
    if not reset_backend(model,mode) then return end
    model.force_source_reset,model.route_hold_project=nil,nil
    session.reset(model)
  elseif legacy_monitor_restart or playing and changed and model.prefs.auto_reset == 'New Reference' then
    -- A compatible older helper used preview mode for stopped monitoring.
    -- Reset as soon as Lua sees Play when its audio callback cannot see that edge.
    if not reset_backend(model, mode) then return end
    session.reset(model)
  elseif model.capture_mode ~= mode then
    local ok, reason = backend:capture(mode, false)
    if not ok then model.error = reason; return end
  end
  if started and model.prefs.auto_reset == 'On Play' then session.reset(model) end
  if playing then model.measured_source, model.measured_preview_mixed = key, mixed end
  model.source_key, model.playing, model.capture_mode = key, playing, mode
  local snapshot = backend:poll()
  snapshot.playing = playing
  check_progress(model, snapshot, mode, now)
  if snapshot.ready then
    if model.capture_epoch and snapshot.capture_epoch ~= model.capture_epoch then
      session.reset(model)
    end
    model.capture_epoch = snapshot.capture_epoch
  end
  if snapshot.ready then model.error = nil
  elseif not snapshot.pending_publication then model.error = snapshot.status end
  if snapshot.ready and not playing and snapshot.history and #snapshot.history > 0 then
    -- A whole run can start and stop between interface ticks. Drain its audio
    -- windows before the stopped display releases live readings.
    snapshot.playing = true
    session.update(model, snapshot, 0)
    snapshot.playing = false
  end
  session.update(model, snapshot, dt)
  if not model.stall_retry_deadline then warnings.update(model.warnings, model.values, model.prefs, dt) end
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
