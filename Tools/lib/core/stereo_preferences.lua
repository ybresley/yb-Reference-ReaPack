local json = require('vendor.json')
local preferences = {}

local modes = {'lissajous', 'polar_sample'}
local choices = {
  trail = {short = true, medium = true, long = true},
  trace = {dots = true, lines = true},
}
local invalid = 'Saved stereo settings are invalid.'

local function finite(value)
  return type(value) == 'number' and value == value and math.abs(value) < math.huge
end

function preferences.defaults()
  local result = {version = 2, views = {}, show_clipping = true,
    clip_hold = 2, show_correlation = false}
  for _, mode in ipairs(modes) do
    result.views[mode] = {brightness = 1, history = 1, trail = 'long',
      trace = 'dots'}
  end
  return result
end

function preferences.normalize(value)
  if type(value) ~= 'table' then return nil, invalid end
  if value.version ~= nil and value.version ~= 1 and value.version ~= 2 then
    return nil, 'Saved stereo settings use an unsupported version.'
  end
  local result = preferences.defaults()
  for _, key in ipairs({'show_clipping', 'show_correlation'}) do
    if value[key] ~= nil then
      if type(value[key]) ~= 'boolean' then return nil, invalid end
      result[key] = value[key]
    end
  end
  if value.clip_hold ~= nil then
    local hold = value.clip_hold
    if hold ~= 0 and hold ~= 0.5 and hold ~= 1 and hold ~= 2 then return nil, invalid end
    result.clip_hold = hold
  end
  if value.views ~= nil and type(value.views) ~= 'table' then return nil, invalid end
  -- Version 1's guide and quiet-signal choices no longer affect the display.
  -- Copy the remaining controls into the current shape without changing them.
  for _, mode in ipairs(modes) do
    local source = value.views and value.views[mode]
    if source ~= nil then
      if type(source) ~= 'table' then return nil, invalid end
      for key in pairs(result.views[mode]) do
        local item = source[key]
        if item ~= nil then
          if key == 'brightness' or key == 'history' then
            if not finite(item) or item < 0.5 or item > 1.5 then return nil, invalid end
          elseif not choices[key][item] then return nil, invalid end
          result.views[mode][key] = item
        end
      end
    end
  end
  -- A folded polar waveform cannot form one continuous connected trace.
  result.views.polar_sample.trace = 'dots'
  return result
end

function preferences.encode(value)
  local result, err = preferences.normalize(value)
  if not result then return nil, err end
  return json.encode(result)
end

function preferences.decode(text)
  if text == nil or text == '' then return preferences.defaults() end
  if type(text) ~= 'string' then return nil, invalid end
  local ok, value = pcall(json.decode, text)
  if not ok or type(value) ~= 'table' then return nil, invalid end
  if value.version ~= 1 and value.version ~= 2 then
    return nil, 'Saved stereo settings use an unsupported version.'
  end
  return preferences.normalize(value)
end

function preferences.update(value, mode, key, item)
  local result, err = preferences.normalize(value)
  if not result then return nil, err end
  if mode ~= nil and not result.views[mode] then return nil, invalid end
  local target = mode and result.views[mode] or result
  if not target or target[key] == nil or key == 'version' or key == 'views' then
    return nil, invalid
  end
  target[key] = item
  return preferences.normalize(result)
end

return preferences
