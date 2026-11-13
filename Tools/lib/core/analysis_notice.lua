local meter_status = require('core.meter_status')
local helper_status = require('core.monitor_helper_status')
local arrangements = require('core.speaker_arrangements')
local notice = {}
local PAIR, FAULT, CHANNELS = 60, 80, 90

local function message(title, detail, priority, button, action)
  return {title=title,detail=detail,priority=priority,button=button,action=action}
end
local function pending(reason)
  return reason=='stopped' or reason=='waiting_for_samples' or reason=='initializing' or reason=='waiting'
end
local function prefer(first, second)
  if second and (not first or second.priority>first.priority) then return second end
  return first
end
local function audio_settings(title, detail, priority)
  return message(title,detail,priority or CHANNELS,'Audio Settings','analysis_channels_open')
end
local function layout_notice(detail)
  local warning=message('Check Channel Layout',detail,CHANNELS,'Channel Layout','analysis_channels_open')
  warning.channel_layout=true
  return warning
end
local function speaker_setup(state)
  local profile=state.analysis_output_profile or state.analysis_channels
  if not profile or profile.known~=false then return end
  local suggestion=state.analysis_channel_suggestion
  local arrangement=suggestion and arrangements.get(suggestion.arrangement)
  local name=arrangement and arrangement.label
  local setup=message('Set Project Speakers',
    'Choose a speaker layout for the surround field and LUFS readings.',20,
    name and 'Use Recommendation' or 'Choose Layout',
    name and 'analysis_channels_setting' or 'analysis_channels_open')
  if state.analysis_channel_save_error then
    setup.detail=setup.detail..' Your speaker choices haven’t been saved yet.'
  end
  setup.setup,setup.channel_layout=true,true
  if name then
    setup.recommendation='Recommended: '..name
    setup.action_data={type='analysis_channels_setting',key='suggestion'}
    setup.secondary_button,setup.secondary_action='Choose Layout','analysis_channels_open'
  end
  return setup
end
local function input_mapping(reason)
  return reason=='input_mapping_changed' or reason=='input_mapping_unverified'
end
local function input_notice(reason)
  return message('Meter Inputs Are Unavailable',meter_status.error(reason),CHANNELS)
end
local function trusted(model)
  return model and model.preview_capture_active
end

local PLAYBACK_TITLES={reference_not_isolated='Check Reference Mode'}
-- Audio settings and the shared overlay use the same source-aware explanation.
function notice.routing(state, fallback)
  local reason=state.analysis_channel_route_reason
  local profile,available=state.analysis_channels,state.analysis_channel_available_count
  if state.analysis_channel_error or state.analysis_channel_profile_blocked
      or profile and type(available)=='number' and profile.count>available then
    return layout_notice(state.analysis_channel_error or state.analysis_channel_limit_warning
      or state.analysis_channel_route_warning or fallback)
  end
  if PLAYBACK_TITLES[reason] then
    return message(PLAYBACK_TITLES[reason],state.analysis_channel_route_warning,CHANNELS)
  end
  if reason=='reference_route_unverified' then
    return audio_settings('Reference Connection Unavailable',state.analysis_channel_route_warning)
  end
  return audio_settings('Check Audio Outputs',state.analysis_channel_route_warning or fallback
    or 'The analysis effects cannot receive every selected channel. Check the audio outputs and Monitor FX.')
end

function notice.channel(state, verified)
  if state.analysis_meter_start_error then
    if state.analysis_meter_start_error=='old_owner' then
      return message('Close The Other yb-Reference Window','The meters will start after it closes.',100)
    end
    return message('Meters Couldn’t Start','Close and reopen yb-Reference to try again.',100)
  end
  if state.analysis_audio_suspended and state.analysis_audio_pause_notice then
    return message('Audio Paused',meter_status.error('audio_suspended'),100)
  end
  if not state.analysis_channels then return end
  if state.analysis_channel_profile_blocked or state.analysis_channel_error then return notice.routing(state) end
  if verified and not state.analysis_channel_profile_blocked and not state.analysis_channel_error
      and (state.analysis_channel_route_only or not state.analysis_channel_blocked) then return end
  if state.analysis_channel_route_checking and state.analysis_channel_route_only then return end
  local system=state.monitor_filter and state.monitor_filter.system
  local reason=system and system.phase=='ready' and system.analysis_input_status
  if input_mapping(reason) then return input_notice(reason) end
  local available=system and system.input_channels
  local measured=state.preview_analysis_profile or state.analysis_output_profile or state.analysis_channels
  if state.analysis_channel_blocked or available and available>0 and available<measured.count then
    return notice.routing(state)
  end
end

local function meter_notice(state, model)
  if state.analysis_channel_profile_blocked or state.analysis_channel_error then return notice.routing(state) end
  local reason=model.error
  if reason=='recording' then
    local waiting=message('Waiting For Recording To Stop',meter_status.error(reason),FAULT)
    waiting.pending=true
    return waiting
  end
  local verified=trusted(model) and (not reason or reason=='channel_profile_required' or reason=='channels_unavailable')
  if verified then return end
  if input_mapping(reason) then return input_notice(reason) end
  local meter_fault=reason and not pending(reason)
    and reason~='channel_profile_required' and reason~='channels_unavailable'
  if not meter_fault and state.analysis_channel_route_checking and state.analysis_channel_route_only then return end
  if not meter_fault and (state.analysis_channel_blocked or reason=='channels_unavailable') then return notice.routing(state) end
  if reason=='channel_profile_required' then return speaker_setup(state) or notice.routing(state) end
  if not reason or pending(reason) then return end
  if reason=='existing_instance' then
    return message('Loudness Meter Is In Use','Close the other yb-Reference window before reconnecting.',FAULT,
      'Reconnect','meter_reconnect')
  end
  local reconnect=meter_status.can_reconnect(reason)
  local detail=reconnect and 'Retrying starts a new Loudness measurement.' or meter_status.error(reason)
  return message(reason=='unsupported_sample_rate' and 'Unsupported Sample Rate' or 'Loudness Meter Is Unavailable',
    detail,FAULT,reconnect and 'Retry Loudness Meter' or nil,reconnect and 'meter_reconnect' or nil)
end

local function monitoring_notice(system)
  if system.waiting_for_recording then
    local status=helper_status.describe(system)
    if status then
      local waiting=message(status.title,status.detail,FAULT)
      waiting.pending=true
      return waiting
    end
    return
  end
  if system.phase=='idle' or system.phase=='settling' or system.phase=='recovering' then return end
  local status=helper_status.describe(system)
  if not status then return end
  return message(status.title,status.detail,FAULT,status.button,status.action)
end

local CLEANUP_REASONS={
  inspection_failed='could not be checked',
  record_changed='has changed ownership information',
  track_unavailable='could not be identified',
  multiple_tracks='matches more than one old meter track',
  track_changed='has changed track settings or content',
  effect_changed='has changed effects',
  unexpected_send='has an old meter send on an unexpected track',
  orphan_send='has no matching old meter track',
  send_ambiguous='has more than one matching old meter send',
  unmarked_send='has a send whose ownership could not be confirmed',
  send_changed='has changed send settings',
  send_limit='has too many hardware sends for automatic removal',
  cleanup_interrupted='could not be fully removed',
  send_delete_failed='has a send that Reaper could not remove',
  track_delete_failed='could not be removed by Reaper',
  project_changed='belongs to a project that changed during cleanup',
}

-- Cleanup guidance stays in Settings so it cannot block healthy measurements.
function notice.legacy_cleanup(state)
  local problem=state.meter_track_cleanup_problem
  if not problem then return end
  local project=problem.project_name and problem.project_name~=''
    and ('project “'..problem.project_name..'”') or 'the affected project'
  local is_master=problem.track_number==0
  local target
  if not is_master and (problem.track or problem.track_name or problem.track_number) then
    target=problem.track_number and ('Track '..problem.track_number) or 'The old meter track'
    if problem.track_name and problem.track_name~='' then target=target..' “'..problem.track_name..'”' end
    if problem.send_number then target=target..', hardware output '..problem.send_number..',' end
    target=target..' in '..project
  else
    target='Master'
    if problem.send_number then target=target..' hardware output '..problem.send_number end
    target=target..' in '..project
  end
  local detail=target..' '..(CLEANUP_REASONS[problem.reason] or 'could not be removed safely')
    ..'. Review it in Reaper.'
  if problem.reason=='project_list_limit' then
    detail='Old meter connections could not all be checked because too many projects are open. Close unused project tabs and reopen yb-Reference.'
  end
  local button=problem.track and not is_master and 'Show Track' or problem.project and 'Show Master' or nil
  return message('Old Meter Track Needs Review',detail,FAULT,button,
    button and 'meter_track_cleanup_show' or nil)
end

local function measurement_notice(state, id)
  if id~='spectrum' and id~='stereo' and id~='loudness' then return end
  if state.analysis_meter_start_error or state.analysis_audio_suspended and state.analysis_audio_pause_notice then
    return notice.channel(state)
  end
  local meter=state.metering
  if id=='loudness' then
    if not meter or not meter.prefs then return end
    return meter_notice(state,meter) or speaker_setup(state)
  end
  local profile=state.analysis_output_profile or state.analysis_channels
  if id=='stereo' and profile and profile.view=='surround' then
    local shared
    if meter then shared=meter_notice(state,meter)
    elseif state.analysis_channel_blocked then shared=notice.routing(state) end
    if not profile.known then
      return prefer(shared,speaker_setup(state))
    end
    return shared
  end
  local model=state[id]
  if not model then return end
  local verified=trusted(model)
  local system=state.monitor_filter and state.monitor_filter.system
  local helper
  if system and not verified then helper=monitoring_notice(system) end
  -- A known missing, disabled or incompatible helper outranks an inferred
  -- capability failure. It can offer the repair that actually applies.
  local shared=prefer(helper,notice.channel(state,verified))
  if id=='stereo' and model.pair_unavailable then
    shared=prefer(shared,message('Selected Pair Is Unavailable','Choose two channels the reference plays through.',PAIR,
      'Stereo Settings','stereo_settings_open'))
  end
  if model.playing and model.capture_failed and not model.pair_unavailable then
    shared=prefer(shared,message(id=='stereo' and 'Stereo Has Stopped Updating' or 'Spectrum Has Stopped Updating',
      'Check the yb-Reference Monitoring Filter in Reaper’s Monitor FX.',FAULT))
  end
  return shared
end

function notice.layout_save_failure(state)
  if not state.analysis_channel_save_error then return end
  local problem=message('Speaker Layout Wasn’t Saved',
    'You can keep working. Save these speaker choices again before closing this project or yb-Reference.',30,
    'Save Layout Again','analysis_channels_setting')
  problem.action_data={type='analysis_channels_setting',key='save_retry'}
  problem.nonblocking,problem.save_failure=true,true
  return problem
end

function notice.describe(state,id)
  if id~='spectrum' and id~='stereo' and id~='loudness' then return end
  local current=measurement_notice(state,id)
  if current and current.setup then return current end
  return prefer(current,notice.layout_save_failure(state))
end

return notice
