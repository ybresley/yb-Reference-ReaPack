-- One explanation and recovery action for every view of the shared helper.
local status = {}
local states = {
  missing = {title = 'Monitoring Filter unavailable',
    detail = 'The saved helper is not available in Reaper. Choose Add Helper to restore it.',
    button = 'Add Helper', action = 'restore_monitor_filter'},
  bypassed = {title = 'Helper is turned off',
    detail = 'yb-Reference Monitoring Filter is bypassed in Monitor FX.',
    button = 'Enable Helper', action = 'enable_monitor_filter'},
  offline = {title = 'Helper is offline',
    detail = 'yb-Reference Monitoring Filter is offline in Monitor FX.',
    button = 'Enable Helper', action = 'enable_monitor_filter'},
  incompatible = {title = 'Helper needs updating',
    detail = 'Reload the helper for this version of yb-Reference.',
    button = 'Update Helper', action = 'restore_monitor_filter'},
  duplicate = {title = 'Multiple helpers in Monitor FX',
    detail = 'Keep one yb-Reference Monitoring Filter and remove the extra copies.'},
  settling = {title = 'Setting up spectrum and filter…',
    detail = 'Waiting for the helper in Monitor FX.'},
  recovering = {title = 'Waiting for Monitoring FX…',
    detail = 'Reaper is still loading the Monitoring FX chain. yb-Reference will reconnect automatically.'},
}

function status.describe(system)
  system = system or {}
  if system.available then return nil end
  if system.phase == 'settling' and system.waiting_for_saved_helper then
    return states.recovering
  end
  local known = states[system.phase]
  if known then
    if system.phase == 'missing' and system.message then
      return {title = known.title, detail = system.message, button = known.button, action = known.action}
    end
    return known
  end
  return {title = 'Spectrum helper unavailable',
    detail = system.message or 'The helper could not be connected in Monitor FX.',
    button = system.can_restore and 'Restore Helper' or nil,
    action = system.can_restore and 'restore_monitor_filter' or nil}
end

return status
