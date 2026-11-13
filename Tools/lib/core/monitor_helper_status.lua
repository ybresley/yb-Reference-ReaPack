-- One explanation and recovery action for every view of the shared helper.
local status = {}
local states = {
  missing = {title = 'Monitoring Filter Unavailable',
    detail = 'yb-Reference Monitoring Filter is missing from Monitor FX.',
    button = 'Add Helper', action = 'restore_monitor_filter'},
  bypassed = {title = 'Helper Is Turned Off',
    detail = 'It’s bypassed in Monitor FX.',
    button = 'Enable Helper', action = 'enable_monitor_filter'},
  offline = {title = 'Helper Is Offline',
    detail = 'yb-Reference Monitoring Filter is offline in Monitor FX.',
    button = 'Enable Helper', action = 'enable_monitor_filter'},
  incompatible = {title = 'Helper Version Mismatch',
    detail = 'Reload the helper for this version of yb-Reference.',
    button = 'Update Helper', action = 'restore_monitor_filter'},
  duplicate = {title = 'Multiple Helpers In Monitor FX',
    detail = 'Keep one yb-Reference Monitoring Filter and remove the extra copies.'},
  settling = {title = 'Checking Monitor FX…',
    detail = 'yb-Reference is checking for its Monitoring Filter.'},
  recovering = {title = 'Waiting For Monitor FX…',
    detail = 'The saved helper hasn’t appeared yet. yb-Reference will reconnect if it becomes available.'},
}

function status.describe(system)
  system = system or {}
  if system.available then return nil end
  if system.waiting_for_recording then
    return {title='Waiting For Recording To Stop',
      detail='Monitoring Filter setup will continue after recording stops in every project.'}
  end
  if system.phase == 'settling' and system.waiting_for_saved_helper then
    return states.recovering
  end
  local known = states[system.phase]
  if known then
    if not known.button then return known end
    local can_recover = known.action == 'enable_monitor_filter' and system.can_enable
      or known.action == 'restore_monitor_filter' and system.can_restore
    if not can_recover then
      local title = system.phase == 'incompatible' and system.helper_identified == false
        and 'Check Monitoring Filter' or known.title
      return {title = title, detail = system.message or known.detail}
    end
    return {title = known.title, detail = system.phase == 'missing' and system.message or known.detail,
      button = known.button, action = known.action}
  end
  return {title = 'Monitoring Filter Unavailable',
    detail = system.message or 'The helper could not be connected in Monitor FX.',
    button = system.can_restore and 'Restore Helper' or nil,
    action = system.can_restore and 'restore_monitor_filter' or nil}
end

return status
