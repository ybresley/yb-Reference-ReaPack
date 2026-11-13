-- Translate adapter states without exposing internal identifiers in the panel.
local status={}
local unsupported_rate='The current sample rate isn’t supported for Loudness measurements. In Reaper, choose 44.1, 48, 88.2, 96, 176.4 or 192 kHz.'
local errors={
  audio_suspended='Reaper’s audio device is closed. Measurements resume when it reopens.',
  initializing='Starting meter…',
  recording='Loudness meter setup will continue after recording stops in every project.',
  waiting='Waiting for Loudness measurements.',
  startup_failed='The meter did not start. Check that Monitor FX and Reaper’s audio device are running, then choose Reconnect.',
  insert_failed='Reaper could not load its stock Loudness Meter. Check that it is installed, then reconnect.',
  crest_insert_failed='Reaper could not load the yb-Reference meter. Close and reopen yb-Reference, then reconnect. If this continues, check yb-Reference_Meter.jsfx in Reaper’s Effects/yb-Reference folder.',
  parameters_missing='The installed meter has different controls. Update Reaper, then reconnect.',
  crest_parameters_missing='The loaded yb-Reference meter is missing required controls. Choose Reconnect to reload it.',
  control_incompatible='The loaded meter didn’t match this version of yb-Reference. Choose Reconnect to reload it and start a new measurement.',
  storage_failed='The meter connection could not be saved. Check that Reaper’s settings folder is writable, then reconnect.',
  crest_source_unreadable='The yb-Reference meter file could not be read. Reinstall yb-Reference, then choose Reconnect.',
  crest_install_conflict='A different or edited meter file was found. Its files have been left untouched. Check the yb-Reference meter installation before reconnecting.',
  crest_install_leftover='A previous meter update didn’t finish, so its temporary files are still in Reaper’s Data/yb-Reference folder. Close yb-Reference, remove the yb-Reference_Meter.jsfx files ending in .pending or .backup, then reopen it.',
  crest_install_missing='The meter file is missing from Reaper’s Effects/yb-Reference folder. Reinstall yb-Reference through ReaPack, then reopen yb-Reference.',
  unknown_meter='The yb-Reference Meter couldn’t be verified. Remove that effect from Monitor FX, then reopen yb-Reference.',
  crest_install_failed='The yb-Reference meter could not be installed. Check that Reaper’s Effects and Data folders are writable, then choose Reconnect.',
  crest_restore_failed='The meter update failed and the previous meter could not be restored.',
  no_master='Reaper’s master output is unavailable.',
  configuration_failed='The meter did not accept its measurement settings. Reconnect to try again.',
  configuration_changed='The meter settings changed. Reconnect to restore measurement.',
  offline='The yb-Reference meter is offline. Bring it online in Monitor FX.',
  bypassed='The yb-Reference meter is bypassed. Enable it in Monitor FX.',
  missing='The yb-Reference meter is missing from Monitor FX. Choose Reconnect to start a new measurement.',
  changed='The meter connection changed. Choose Reconnect to start a new measurement.',
  repair_refused='The meter could not be verified. Close yb-Reference, remove only yb-Reference Meter from Monitor FX, then reopen.',
  identity_failed='Reaper loaded an unexpected effect. Check Monitor FX before reconnecting.',
  rename_failed='The new meter could not be named. Reconnect to try again.',
  delete_failed='A meter effect could not be removed. Check Monitor FX before reconnecting.',
  moved='The meter was moved in Monitor FX. Choose Reconnect to measure before the other effects.',
  ambiguous='More than one matching meter was found. Check Monitor FX before reconnecting.',
  existing_instance='Meter effects from another session are still present. Close any other yb-Reference windows, then choose Reconnect to recover.',
  stalled='The meter stopped receiving updates. Check that Monitor FX and Reaper’s audio device are running, then reconnect.',
  lra_invalid='The meter returned an invalid Loudness reading. Check the audio feeding the meter, then choose Reconnect.',
  unsupported_sample_rate=unsupported_rate,
  detached='The meter is disconnected. Reconnect to start measuring.',
  capture_invalid='The meter couldn’t verify the measurements it received. Choose Reconnect to start a new measurement.',
  channels_unavailable='Monitor FX has fewer channels than the selected layout. Check Channel Layout and Reaper’s audio outputs.',
  channel_profile_required='Check Settings > Audio and the project output routing before measuring.',
  input_mapping_changed='An analysis effect is receiving reordered or combined channels. Restore its matching input channel connections in Monitor FX.',
  input_mapping_unverified='The analysis effect’s input channel connections could not be verified. Check Monitor FX and your Reaper version.',
}

function status.error(reason)
  return errors[reason] or errors[tostring(reason):gsub('^crest_','')]
    or 'Measurement is unavailable. Check Monitor FX.'
end

local manual = {recording=true,offline=true,bypassed=true,repair_refused=true,ambiguous=true,
  crest_restore_failed=true,unsupported_sample_rate=true,unknown_meter=true}
function status.can_reconnect(reason) return not manual[reason] end

-- The card text for a Reset or Reconnect the user just asked for, or nil when
-- it worked or is simply still starting up.
function status.action_problem(ok, reason)
  if ok or reason == nil or reason == 'initializing' or reason == 'recording' then return nil end
  return status.error(reason)
end

return status
