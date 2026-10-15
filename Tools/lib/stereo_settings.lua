local preferences = require('core.stereo_preferences')
local core = require('core.stereo')
local raster = require('core.stereo_raster')
local settings = {}
local SECTION, KEY = 'yb-Reference', 'stereo_preferences_v2'
local LEGACY_KEY = 'stereo_preferences_v1'

function settings.load()
  local text = reaper.GetExtState(SECTION, KEY)
  if text == '' then text = reaper.GetExtState(SECTION, LEGACY_KEY) end
  local prefs, err = preferences.decode(text)
  return prefs or preferences.defaults(), err
end

function settings.flush(state, force)
  local changed_at = state.stereo_preferences_changed_at
  if not changed_at or (not force and (state.stereo.now or 0) - changed_at < 0.25) then
    return true
  end
  if state.stereo_preferences_error then return nil, state.stereo_preferences_error end
  local text, err = preferences.encode(state.stereo_preferences)
  if not text then return nil, err end
  reaper.SetExtState(SECTION, KEY, text, true)
  state.stereo_preferences_changed_at = nil
  return true
end

function settings.apply(state, action)
  if action.type == 'stereo_freeze' then
    local elapsed = core.set_frozen(state.stereo, action.value == true, state.stereo.now or 0)
    if elapsed and state.stereo.raster then raster.shift_time(state.stereo.raster, elapsed) end
    return true
  end
  local prefs, err
  if action.type == 'stereo_reset_all_settings' then
    prefs = preferences.defaults()
  elseif state.stereo_preferences_error then
    return nil, state.stereo_preferences_error
  elseif action.type == 'stereo_reset_settings' then
    prefs, err = preferences.normalize(state.stereo_preferences)
    local view = action.view or state.stereo_view
    if prefs and prefs.views[view] then
      prefs.views[view] = preferences.defaults().views[view]
    else
      return nil, err or 'Stereo view is unavailable.'
    end
  elseif action.type == 'stereo_setting' then
    prefs, err = preferences.update(state.stereo_preferences,
      action.view, action.key, action.value)
  else
    return nil, 'Stereo setting is unavailable.'
  end
  if not prefs then return nil, err end
  if action.commit == false then
    state.stereo_preferences = prefs
    -- Save after dragging settles even if Escape closes the popup before release.
    state.stereo_preferences_changed_at = state.stereo.now or 0
    return true
  end
  local text
  text, err = preferences.encode(prefs)
  if not text then return nil, err end
  reaper.SetExtState(SECTION, KEY, text, true)
  state.stereo_preferences, state.stereo_preferences_error = prefs, nil
  state.stereo_preferences_changed_at = nil
  return true
end

return settings
