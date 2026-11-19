-- Saved arrangements are separate from older layout preferences so visiting an
-- older copy cannot erase these choices. Each record format has its own key:
-- older copies keep reading theirs (v1 had a Waveform panel, v2 three layout
-- control modes), and a newer copy reads the newest one it finds.
local preferences = require('core.panel_layout_preferences')
local layout = require('core.layout_prototype')
local meters = require('core.meter_layout')
local settings = {}
local SECTION, KEY = 'yb-Reference', 'panel_layout_v3'
local PREVIOUS_KEYS = {'panel_layout_v2', 'panel_layout_v1'}
local METER_SPLITS = {history_x=true, history_y=true, readings_x=true, loudness_lr=true}

function settings.load(previous, previous_error, meter_prefs)
  local text = reaper.GetExtState(SECTION, KEY)
  for _, key in ipairs(PREVIOUS_KEYS) do
    if text ~= '' then break end
    text = reaper.GetExtState(SECTION, key)
  end
  local model, splits, err
  if text ~= '' then
    model, splits, err = preferences.decode(text)
  elseif previous_error then
    err = previous_error
  else
    model, splits, err = preferences.migrate(previous, meter_prefs)
  end
  if not model then model, splits = preferences.defaults() end
  return model, splits, err
end

function settings.flush(state, force)
  local changed_at = state.panel_layout_changed_at
  if not changed_at or (not force and reaper.time_precise()-changed_at < .25) then
    return true
  end
  if state.panel_layout_error then return nil, state.panel_layout_error end
  local text, err = preferences.encode(state.layout_prototype, state.layout_meter_splits)
  if not text then return nil, err end
  reaper.SetExtState(SECTION, KEY, text, true)
  state.panel_layout_changed_at = nil
  return true
end

function settings.apply(state, action)
  local operation = action.operation
  local reset_all = action.type == 'layout_prototype'
    and operation and operation.type == 'reset_all'
  if state.panel_layout_error and not reset_all then return nil, state.panel_layout_error end
  local dragging = false
  if reset_all then
    state.layout_prototype, state.layout_meter_splits = preferences.defaults()
    state.panel_layout_error = nil
  elseif action.type == 'layout_prototype' then
    local result, err = layout.apply(state.layout_prototype, operation)
    if not result then return nil, err end
    if operation.type == 'reset' then
      state.layout_meter_splits = select(2, preferences.defaults())
    end
    dragging = operation.type == 'split'
  elseif action.type == 'meter_panel_swap' then
    local changed = meters.swap(state.layout_meter_splits, action.a, action.b, action.geometry)
    if not changed then return nil, 'These meter panels do not share a border.' end
    state.layout_meter_splits = changed
  elseif action.type == 'meter_panel_split' then
    local value = action.value
    if not METER_SPLITS[action.key] or type(value) ~= 'number'
        or value ~= value or value < 0 or value > 1 then
      return nil, 'Invalid meter divider position.'
    end
    state.layout_meter_splits[action.key] = value
    dragging = true
  else
    return nil, 'Panel layout action is unavailable.'
  end
  -- Save discrete choices immediately. Divider movement saves once input settles
  -- or on close, including when a popup disappears before its release frame.
  state.panel_layout_changed_at = reaper.time_precise()
  if dragging and action.commit ~= true then return true end
  return settings.flush(state, true)
end

return settings
