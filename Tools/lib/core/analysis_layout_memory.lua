-- Each available master width has its own choice, including intentional subsets.
local channels=require('core.analysis_channels')
local json=require('vendor.json')
local memory={}
local function width(value)
  return type(value)=='number' and math.tointeger(value) and value>=1 and value<=128
end
local function damaged() return nil,'Channel settings are damaged.' end
function memory.decode(text,identity)
  local result={version=3,identity=identity,layouts={}}
  if not text or text=='' then return result end
  local ok,record=pcall(json.decode,text)
  if not ok or type(record)~='table' then return damaged() end
  if record.version~=1 and record.version~=2 and record.version~=3 then
    return nil,'This version cannot read the saved channel settings.'
  end
  if record.identity~=identity then return nil,'The saved channel settings belong to another source.' end
  local function add(available,setting)
    if not width(available) or type(setting)~='table' or not width(setting.count)
        or setting.count>8 or setting.count>available then return nil end
    local profile=channels.profile(setting.count,setting)
    if not profile then return nil end
    result.layouts[tostring(available)]=channels.setting(profile)
    return true
  end
  if record.version==3 then
    if type(record.layouts)~='table' then return damaged() end
    local total=0
    for available,setting in pairs(record.layouts) do
      local number=type(available)=='string' and tonumber(available)
      if not number or tostring(number)~=available or not add(number,setting) then return damaged() end
      total=total+1
      if total>128 then return damaged() end
    end
  else
    local available=record.version==2 and record.available_count
      or type(record.setting)=='table' and record.setting.count
    if not add(available,record.setting) then return damaged() end
  end
  return result
end
function memory.profile(record,available)
  if not width(available) then return nil,'The project channel count is unavailable.' end
  local setting=record.layouts[tostring(available)]
  if setting then return channels.profile(setting.count,setting),nil,true end
  return channels.profile(math.min(8,available)),nil,false
end
function memory.encode(record,identity,available,profile)
  local copy={version=3,identity=identity,layouts={}}
  for count,setting in pairs(record.layouts) do copy.layouts[count]=setting end
  if available~=nil then
    if not width(available) then return nil,'The project channel count is unavailable.' end
    if profile then
      local valid,err=channels.profile(profile.count,channels.setting(profile))
      if not valid then return nil,err end
      if valid.count>available then return nil,'The custom arrangement exceeds the available source channels.' end
      copy.layouts[tostring(available)]=channels.setting(valid)
    else copy.layouts[tostring(available)]=nil end
  end
  local text=json.encode(copy)
  local valid,err=memory.decode(text,identity)
  if not valid then return nil,err end
  return text,valid
end
return memory
