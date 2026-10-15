local warnings = {}

local fields = {
  m = 'm', s = 's', i = 'i',
  l = 'peak_l', r = 'peak_r',
}

local function exceeds(key, value, target, peak_mode)
  if value == nil or value ~= value then return false end
  if key == 'l' or key == 'r' then
    if peak_mode=='True Peak' then return value>0 end
    return value>=0
  end
  return target ~= nil and value >= target
end

function warnings.new()
  return {
    flags = { m=false, s=false, i=false, l=false, r=false, tp=false },
    suppressed = {},
    values = {},
    clip_below = { l=0, r=0 },
  }
end

function warnings.update(state, values, opts, dt)
  values = values or {}
  opts = opts or {}
  dt = type(dt)=='number' and dt==dt and dt>=0 and dt<math.huge and dt or 0
  local target_changed = state.target ~= opts.target
  local ceiling_changed = state.ceiling ~= opts.ceiling
  local peak_mode = opts.peak_measurement or 'True Peak'
  local peak_changed = state.peak_measurement ~= peak_mode

  for key, field in pairs(fields) do
    local value = values[field]
    if key=='l' or key=='r' then value=values['warning_peak_'..key] or value end
    state.values[field] = value
    local over = exceeds(key, value, opts.target, peak_mode)
    if peak_changed and (key=='l' or key=='r') then
      state.flags[key], state.suppressed[key], state.clip_below[key] = over, over, 0
    elseif target_changed and key ~= 'l' and key ~= 'r' then
      state.flags[key] = over
      state.suppressed[key] = over
    elseif not over then
      if key == 'm' or key == 's' or key == 'i' then
        state.flags[key] = false
      elseif state.flags[key] and opts.clip_hold and opts.clip_hold>0 then
        state.clip_below[key] = state.clip_below[key] + dt
        if state.clip_below[key]>=opts.clip_hold then state.flags[key]=false end
      end
      state.suppressed[key] = false
    elseif not state.suppressed[key] then
      state.flags[key] = true
      state.suppressed[key] = true
    end
    if over and (key=='l' or key=='r') then state.clip_below[key]=0 end
  end

  local tp = values.tp_max
  state.values.tp_max = tp
  local tp_over = tp ~= nil and tp == tp and opts.ceiling ~= nil and tp > opts.ceiling
  if ceiling_changed then
    state.flags.tp = tp_over
    state.tp_clear_max = tp
  elseif tp_over and (state.tp_clear_max == nil or tp > state.tp_clear_max) then
    state.flags.tp = true
  end

  state.target, state.ceiling = opts.target, opts.ceiling
  state.peak_measurement = peak_mode
  return state
end

function warnings.clear(state)
  for key, field in pairs(fields) do
    state.flags[key] = false
    state.suppressed[key] = exceeds(key, state.values[field], state.target, state.peak_measurement)
    if key=='l' or key=='r' then state.clip_below[key]=0 end
  end
  state.flags.tp = false
  state.tp_clear_max = state.values.tp_max
  return state
end

function warnings.active(state, key)
  return state ~= nil and state.flags[key] == true
end

return warnings
