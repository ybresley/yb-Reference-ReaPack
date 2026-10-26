-- Preferences persist display and reset choices, never live measurement state.
local preferences = {}
local json = require('vendor.json')
local targets = require('core.meter_targets')

preferences.VERSION = 6
preferences.OPTIONS = {
  view = { 'all', 'pictures', 'meters' },
  mode = { 'LUFS', 'K-20', 'K-14', 'K-12' },
  colours = { 'Accent Fade', 'Solid Accent', 'Thresholds' },
  range = { -36, -48, -60 }, seconds = { 5, 10, 15, 30, 60 },
  loudness_scale = { 'Expanded', 'Target +9', 'Target +18' },
  readings = { 'Absolute', 'Relative' },
  history_position = { 'Automatic', 'Beside Meters', 'Below Meters' },
  meter_widths = { 'Equal', 'Integrated Wider' },
  tolerance = { 0, .5, 1, 2 },
  ms_hold = { -1, 0, .5, 1.5, 3 },
  lr_contents = { 'RMS + Peak', 'Peak Only', 'RMS Only' },
  peak_measurement = { 'Sample Peak', 'True Peak' },
  target_difference_measurement = { 'Integrated', 'Momentary', 'Short-Term' },
  lr_floor = { -48, -60, -90 },
  lr_hold = { 0, .5, 1.5, 3 },
  peak_fall = { 'Fast', 'Normal', 'Slow' },
  clip_hold = { 0, .5, 2 },
  history_fill = { 'Off', 'Short-Term', 'Momentary', 'Integrated' },
  time_format = { 'Seconds', 'Minutes:Seconds' },
  number_size = { 16, 18, 20 },
  history_line_width = { 1, 2, 3 },
  yellow_lead = { 3, 5, 6, 9 },
  red_span = { 1, 3, 6 },
  auto_reset = { 'Manual', 'On Play', 'New Reference' },
  seek_reset = { 'Keep Measuring', 'Start New Run' },
  loop_reset = { 'Accumulate', 'Start New Run' },
}

local BOOLEAN = {
  visible=true, show_meters=true, show_loudness=true, extra_readings=true,
  show_m=true, show_s=true, show_i=true,
  show_lra=true, show_lr=true, show_history=true, show_target=true,
  show_clipping=true, history_m=true, history_s=true,
  history_integrated=true, history_colours=true,
  history_legend=true, lr_shading=true, keep_integrated=true,
}

function preferences.defaults()
  return { view='all', visible=true, show_meters=true,
    show_loudness=true, show_lr=true,
    show_history=true, mode='LUFS', colours='Accent Fade', target=-16,
    ceiling=-1, range=-48, seconds=10, preset='',
    loudness_scale='Expanded', readings='Absolute',
    show_m=true, show_s=true, show_i=true, show_lra=true,
    history_position='Automatic', extra_readings=true,
    meter_widths='Integrated Wider', tolerance=0, show_target=false,
    ms_hold=1.5, lr_contents='RMS + Peak', peak_measurement='True Peak', lr_floor=-48,
    lr_hold=1.5, peak_fall='Normal', show_clipping=true, clip_hold=0,
    history_m=true, history_s=true, history_integrated=false,
    history_fill='Short-Term', history_opacity=.22, history_colours=true,
    time_format='Minutes:Seconds', history_legend=true, number_size=20,
    history_line_width=2, grid_brightness=1, lra_brightness=1,
    yellow_lead=5, red_span=3, lr_shading=true,
    auto_reset='On Play', keep_integrated=true,
    target_difference_measurement='Integrated',
    seek_reset='Keep Measuring', loop_reset='Accumulate' }
end

local function finite(value)
  return type(value)=='number' and value==value and math.abs(value)<math.huge
end

local function valid(key, value)
  if BOOLEAN[key] then return type(value)=='boolean' end
  if key=='target' then return finite(value) and value>=-60 and value<=0 end
  if key=='ceiling' then return finite(value) and value>=-24 and value<=3 end
  if key=='history_opacity' then return finite(value) and value>=0 and value<=.5 end
  if key=='grid_brightness' then return finite(value) and value>=.5 and value<=1.5 end
  if key=='lra_brightness' then return finite(value) and value>=.75 and value<=1.5 end
  if key=='preset' then
    local preset=type(value)=='string' and targets.get(value)
    return value=='' or (preset~=nil and preset.target~=nil)
  end
  for _, option in ipairs(preferences.OPTIONS[key] or {}) do
    if value==option then return true end
  end
  return false
end

local function has_content(prefs)
  return (prefs.show_meters and (prefs.show_lr or (prefs.show_loudness
    and (prefs.show_m or prefs.show_s or prefs.show_i or prefs.show_lra))))
    or prefs.show_history
end

local function has_trace(prefs)
  return prefs.history_m or prefs.history_s or prefs.history_integrated
end

local function fill_enabled(prefs)
  return prefs.history_fill=='Off'
    or (prefs.history_fill=='Momentary' and prefs.history_m)
    or (prefs.history_fill=='Short-Term' and prefs.history_s)
    or (prefs.history_fill=='Integrated' and prefs.history_integrated)
end

local function validate(value)
  if type(value)~='table' then return nil,'Saved meter settings are invalid.' end
  local result=preferences.defaults()
  for key in pairs(result) do
    if value[key]~=nil then
      if not valid(key,value[key]) then return nil,'Saved meter settings are invalid.' end
      result[key]=value[key]
    end
  end
  if not has_content(result) then return nil,'Keep at least one meter display visible.' end
  if not has_trace(result) then return nil,'Keep at least one history line enabled.' end
  -- A stale preset label cannot claim settings that the user has changed.
  if result.preset~='' and not targets.active(result) then result.preset='' end
  return result
end

function preferences.encode(prefs)
  local result,err=validate(prefs)
  if not result then return nil,err end
  return json.encode({version=preferences.VERSION,preferences=result})
end

local FIXED = {
  meter_widths='Integrated Wider', number_size=20, history_line_width=2,
  time_format='Minutes:Seconds', grid_brightness=1, lra_brightness=1,
  auto_reset='On Play', seek_reset='Keep Measuring',
}

local LEGACY_EXTRA_READINGS = {
  ['Off']=false, ['True Peak Max']=true, ['Crest L/R']=true, ['Both']=true,
  ['Momentary Max']=true, ['Short-Term Max']=true, ['Loudness Max']=true, ['All']=true,
}

local function migrate(prefs,version)
  local result={}
  for key,value in pairs(prefs) do result[key]=value end
  if version==1 and result.show_loudness==false then
    result.show_m,result.show_s,result.show_i,result.show_lra=false,false,false,false
  end
  if version<3 then
    local traces=result.history_traces
    if traces~=nil and traces~='M + S' and traces~='Momentary'
        and traces~='Short-Term' then return nil end
    result.history_m=traces~='Short-Term'
    result.history_s=traces~='Momentary'
    if result.colours=='Neutral' then result.colours='Solid Accent' end
  end
  if version<4 and result.extra_readings~=nil then
    local enabled=LEGACY_EXTRA_READINGS[result.extra_readings]
    if enabled==nil then return nil end
    result.extra_readings=enabled
  end
  if version<5 then result.peak_measurement='True Peak' end
  if version<6 then result.target_difference_measurement='Integrated' end
  for key,value in pairs(FIXED) do result[key]=value end
  return result
end

function preferences.decode(text)
  if text==nil or text=='' then return preferences.defaults() end
  if type(text)~='string' then return nil,'Saved meter settings are invalid.' end
  local ok,data=pcall(json.decode,text)
  if not ok or type(data)~='table' then return nil,'Saved meter settings are invalid.' end
  if data.version~=1 and data.version~=2 and data.version~=3
      and data.version~=4 and data.version~=5 and data.version~=preferences.VERSION then
    return nil,'Saved meter settings use an unsupported version.'
  end
  if type(data.preferences)~='table' then return nil,'Saved meter settings are invalid.' end
  return validate(migrate(data.preferences,data.version))
end

function preferences.set(prefs,key,value)
  if FIXED[key]~=nil and value~=FIXED[key] then
    return false,'That meter setting is unavailable.'
  end
  if not valid(key,value) then return false,'That meter setting is unavailable.' end
  if key=='preset' and value~='' then
    local old_preset,old_target,old_ceiling=prefs.preset,prefs.target,prefs.ceiling
    targets.apply(prefs,value)
    return old_preset~=prefs.preset or old_target~=prefs.target or old_ceiling~=prefs.ceiling
  end
  local individual = key=='show_m' or key=='show_s' or key=='show_i' or key=='show_lra'
  if key:sub(1,5)=='show_' or key:sub(1,8)=='history_' then
    local next_prefs={}
    for field,current in pairs(prefs) do next_prefs[field]=current end
    next_prefs[key]=value
    if individual then
      next_prefs.show_loudness = next_prefs.show_m or next_prefs.show_s
        or next_prefs.show_i or next_prefs.show_lra
    end
    if key=='show_loudness' and value
        and not (next_prefs.show_m or next_prefs.show_s
          or next_prefs.show_i or next_prefs.show_lra) then
      next_prefs.show_m,next_prefs.show_s,next_prefs.show_i,next_prefs.show_lra=true,true,true,true
    end
    if (key=='history_m' or key=='history_s' or key=='history_integrated')
        and not has_trace(next_prefs) then
      return false,'Keep at least one history line enabled.'
    end
    if not has_content(next_prefs) then return false,'Keep at least one meter display visible.' end
    if individual then
      local changed=prefs[key]~=value or prefs.show_loudness~=next_prefs.show_loudness
      prefs[key],prefs.show_loudness=value,next_prefs.show_loudness
      return changed
    end
    if key=='show_loudness' and value then
      prefs.show_m,prefs.show_s,prefs.show_i,prefs.show_lra=
        next_prefs.show_m,next_prefs.show_s,next_prefs.show_i,next_prefs.show_lra
    end
  end
  if key=='history_fill' then
    local next_prefs={}
    for field,current in pairs(prefs) do next_prefs[field]=current end
    next_prefs.history_fill=value
    if not fill_enabled(next_prefs) then
      return false,'Show that history line before filling it.'
    end
  end
  local changed=prefs[key]~=value
  if (key=='target' or key=='ceiling') and prefs.preset~='' then changed=true end
  targets.edit(prefs,key,value)
  return changed
end

local PAGE_FIELDS = {
  Display={'show_meters','show_loudness','show_lr','show_history',
    'history_position','extra_readings','target_difference_measurement'},
  Loudness={'show_m','show_s','show_i','show_lra','show_target',
    'loudness_scale','range','readings','ms_hold','target','ceiling',
    'preset','tolerance'},
  ['L/R']={'mode','lr_contents','peak_measurement','lr_floor','lr_hold','peak_fall',
    'show_clipping','clip_hold'},
  History={'history_m','history_s','history_integrated','seconds',
    'history_fill','history_opacity','history_colours','history_legend'},
  Appearance={'colours','yellow_lead','red_span','lr_shading'},
  Session={'keep_integrated','seek_reset','loop_reset'},
}

function preferences.reset_page(prefs,page)
  local fields=PAGE_FIELDS[page]
  if not fields then return nil,'That settings page is unavailable.' end
  local next_prefs={}
  for key,value in pairs(prefs) do next_prefs[key]=value end
  local defaults=preferences.defaults()
  for _,key in ipairs(fields) do next_prefs[key]=defaults[key] end
  if not has_content(next_prefs) then
    next_prefs.show_meters=true
    next_prefs.show_loudness=true
    next_prefs.show_m=true
  end
  if not has_trace(next_prefs) then next_prefs.history_s=true end
  return validate(next_prefs)
end

return preferences
