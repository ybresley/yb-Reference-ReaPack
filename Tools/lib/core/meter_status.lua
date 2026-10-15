-- Translate adapter states without exposing internal identifiers in the panel.
local status={}
local errors={
  insert_failed='Reaper could not load its stock Loudness Meter. Check that it is installed, then reconnect.',
  crest_insert_failed='Reaper could not load the yb-Reference meter. Close and reopen yb-Reference, then reconnect. If this continues, check yb-Reference_Meter.jsfx in Reaper’s Effects/yb-Reference folder.',
  parameters_missing='The installed meter has different controls. Update Reaper, then reconnect.',
  crest_parameters_missing='An older stereo meter is loaded. Close and reopen yb-Reference to load the current meter.',
  crest_source_unreadable='The stereo meter file is missing. Reinstall yb-Reference, then reconnect.',
  crest_install_conflict='A different or edited meter file was found. Its files have been left untouched. Check the yb-Reference meter installation before reconnecting.',
  crest_install_failed='The stereo meter could not be installed. Check that Reaper’s Effects and Data folders are writable, then reconnect.',
  crest_restore_failed='The meter update failed and its previous files could not be restored. Close yb-Reference and check its meter backup files before continuing.',
  no_master='Reaper’s master output is unavailable.',
  configuration_failed='The meter did not accept its measurement settings. Reconnect to try again.',
  configuration_changed='The meter settings changed. Reconnect to restore measurement.',
  offline='The meter is offline. Bring it online in Monitor FX, then reconnect.',
  bypassed='The meter is bypassed. Enable it in Monitor FX, then reconnect.',
  missing='The meter was removed from Monitor FX. Reconnect to start a new measurement.',
  changed='The meter was renamed or replaced. Close yb-Reference and check its meter effects before reopening.',
  identity_failed='Reaper loaded an unexpected effect. Check Monitor FX before reconnecting.',
  rename_failed='The new meter could not be named. Reconnect to try again.',
  delete_failed='A meter effect could not be removed. Check Monitor FX before reconnecting.',
  moved='The meter effects were moved. Reconnect to measure before other Monitor FX.',
  ambiguous='More than one matching meter was found. Check Monitor FX before reconnecting.',
  existing_instance='Meter effects from another session are still present. Close any other yb-Reference windows, then choose Reconnect to recover.',
  stalled='The meter stopped receiving updates. Check that Monitor FX and Reaper’s audio device are running, then reconnect.',
  lra_invalid='The stereo measurement is unavailable. Check the input and use 44.1, 48, 88.2, 96, 176.4 or 192 kHz, then reconnect.',
  detached='The meter is disconnected. Reconnect to start measuring.',
  capture_invalid='The meter could not start this measurement. Reconnect to try again.',
}

function status.error(reason)
  return errors[reason] or errors[tostring(reason):gsub('^crest_','')]
    or 'Measurement is unavailable. Check Monitor FX, then reconnect.'
end

return status
