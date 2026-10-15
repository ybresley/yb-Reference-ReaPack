-- Saved arrangements contain choices and proportions, never live drag state.
local json = require('vendor.json')
local layout = require('core.layout_prototype')
local reference = require('core.reference_layout')
local preferences = {}
local VARIANTS = {'automatic', 'map', 'direct'}
local VARIANT = {automatic=true, map=true, direct=true}
local PANELS = {waveform=true, spectrum=true, stereo=true, loudness=true}
local MODES = {auto=true, row=true, stack=true, grid=true,
  top=true, bottom=true, left=true, right=true}
local METER_ORDER = {'loudness', 'lr', 'readings', 'history'}
local METERS = {loudness=true, lr=true, readings=true, history=true}
local METER_SHARES = {history_x=true, history_y=true, readings_x=true, loudness_lr=true}
local INVALID = 'Saved panel arrangements are invalid.'

local function only_keys(value, allowed)
  for key in pairs(value) do if not allowed[key] then return false end end
  return true
end

local function copy_list(value, allowed, complete)
  if type(value) ~= 'table' then return nil end
  local result, seen = {}, {}
  for index, id in ipairs(value) do
    if not allowed[id] or seen[id] then return nil end
    result[index], seen[id] = id, true
  end
  if #result < 1 then return nil end
  for key in pairs(value) do
    if type(key) ~= 'number' or key % 1 ~= 0 or key < 1 or key > #result then
      return nil
    end
  end
  if complete then
    for id in pairs(allowed) do if not seen[id] then return nil end end
  end
  return result
end

local function meter_choices(value)
  if value == nil then value = {} end
  if type(value) ~= 'table' then return nil end
  local result = {}
  for key, fraction in pairs(value) do
    if key ~= 'order' then
      if not METER_SHARES[key] or not layout.valid_share('x', fraction) then return nil end
      result[key] = fraction
    end
  end
  result.order = copy_list(value.order == nil and METER_ORDER or value.order, METERS, true)
  if not result.order then return nil end
  return result
end

local function normalize(model, meter_splits)
  if type(model) ~= 'table' or not VARIANT[model.active]
      or type(model.variants) ~= 'table' or not only_keys(model.variants, VARIANT)
      or (meter_splits ~= nil and type(meter_splits) ~= 'table') then
    return nil, nil, INVALID
  end
  meter_splits = meter_splits or {}
  if not only_keys(meter_splits, VARIANT) then return nil, nil, INVALID end
  local clean = {active=model.active, editing=false, variants={}}
  local meters = {}
  for _, name in ipairs(VARIANTS) do
    local source = model.variants[name]
    if type(source) ~= 'table' or not MODES[source.mode]
        or not only_keys(source, {mode=true, enabled=true, order=true, shares=true})
        or type(source.shares) ~= 'table' then return nil, nil, INVALID end
    local enabled = copy_list(source.enabled, PANELS, false)
    local order = copy_list(source.order, PANELS, true)
    if not enabled or not order then return nil, nil, INVALID end
    local shares = {}
    for key, value in pairs(source.shares) do
      if not layout.valid_share(key, value) then return nil, nil, INVALID end
      shares[key] = value
    end
    if shares.x == nil or shares.y == nil then return nil, nil, INVALID end
    clean.variants[name] = {mode=source.mode, enabled=enabled, order=order, shares=shares}
    meters[name] = meter_choices(meter_splits[name])
    if not meters[name] then return nil, nil, INVALID end
  end
  return clean, meters
end

function preferences.defaults()
  return normalize(layout.new(), {})
end

function preferences.encode(model, meter_splits)
  local clean, meters, err = normalize(model, meter_splits)
  if not clean then return nil, err end
  clean.editing = nil
  return json.encode({version=1, layout=clean, meter_splits=meters})
end

function preferences.decode(text)
  if text == nil or text == '' then return preferences.defaults() end
  if type(text) ~= 'string' then return nil, nil, INVALID end
  local ok, stored = pcall(json.decode, text)
  if not ok or type(stored) ~= 'table' then return nil, nil, INVALID end
  if stored.version ~= 1 then
    return nil, nil, 'Saved panel arrangements use an unsupported version.'
  end
  if not only_keys(stored, {version=true, layout=true, meter_splits=true})
      or type(stored.layout) ~= 'table'
      or not only_keys(stored.layout, {active=true, variants=true})
      or type(stored.meter_splits) ~= 'table' then return nil, nil, INVALID end
  -- A stored record is complete; missing variants must not silently reset choices.
  for _, name in ipairs(VARIANTS) do
    local meter = stored.meter_splits[name]
    if type(meter) ~= 'table' or meter.order == nil then return nil, nil, INVALID end
  end
  return normalize(stored.layout, stored.meter_splits)
end

local function import_shares(target, source)
  for count=2,3 do
    for _, shape in ipairs({'horizontal', 'vertical', 'top', 'bottom', 'left', 'right'}) do
      local old = source.splits[shape .. '_' .. count]
      local mode = shape == 'horizontal' and 'row' or shape == 'vertical' and 'stack' or shape
      local function put(axis, index, value)
        target[mode .. '_' .. count .. '_' .. axis .. index] = value
      end
      if mode == 'row' or mode == 'stack' then
        for i=1,count-1 do put(mode == 'row' and 'x' or 'y', i, old[i]) end
      elseif count == 2 then
        -- The previous wide/tall shapes collapsed to a plain two-panel strip.
        local wide = mode == 'top' or mode == 'bottom'
        local strip = source.splits[(wide and 'vertical' or 'horizontal') .. '_2']
        put(wide and 'y' or 'x', 1, strip[1])
      else
        local wide = mode == 'top' or mode == 'bottom'
        put(wide and 'y' or 'x', 1, old[1])
        put(wide and 'x' or 'y', 1, old[2])
      end
    end
  end
end

function preferences.migrate(reference_prefs, meter_prefs)
  local model, meters = preferences.defaults()
  if reference_prefs == nil and meter_prefs == nil then return model, meters end
  local legacy, err
  if reference_prefs ~= nil then
    legacy, err = reference.normalise(reference_prefs)
    if not legacy then return nil, nil, err end
  end
  if meter_prefs ~= nil and (type(meter_prefs) ~= 'table'
      or (meter_prefs.visible ~= nil and type(meter_prefs.visible) ~= 'boolean')
      or (meter_prefs.view ~= nil and meter_prefs.view ~= 'all'
        and meter_prefs.view ~= 'pictures' and meter_prefs.view ~= 'meters')) then
    return nil, nil, INVALID
  end
  local shape = legacy and legacy.mode or 'auto'
  model.active = shape == 'auto' and 'automatic' or 'map'
  local target = model.variants[model.active]
  target.mode = shape == 'horizontal' and 'row' or shape == 'vertical' and 'stack' or shape
  local order = legacy and legacy.orders[shape == 'auto' and 'horizontal' or shape]
    or {'waveform', 'spectrum', 'stereo'}
  target.order = {order[1], order[2], order[3], 'loudness'}
  local view = meter_prefs and meter_prefs.view or 'all'
  local show_meter = view ~= 'pictures' and not (meter_prefs and meter_prefs.visible == false)
  local show_pictures = view ~= 'meters' or not show_meter
  target.enabled = {}
  if show_pictures then
    for _, id in ipairs(legacy and legacy.enabled or {'waveform', 'spectrum', 'stereo'}) do
      target.enabled[#target.enabled+1] = id
    end
  end
  if show_meter then target.enabled[#target.enabled+1] = 'loudness' end
  if legacy then import_shares(target.shares, legacy) end
  return normalize(model, meters)
end

return preferences
