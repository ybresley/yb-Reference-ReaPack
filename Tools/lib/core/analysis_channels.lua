-- Speaker assignments describe analysis only; they never reorder the audio.
local json = require('vendor.json')
local channels = {}
local ROLES = {
  {id='unknown',label='Unassigned'},
  {id='M',label='Mono',angle=0},
  {id='L',label='Left',angle=-30}, {id='R',label='Right',angle=30},
  {id='L45',label='Quad Left (45°)',short='L',angle=-45},
  {id='R45',label='Quad Right (45°)',short='R',angle=45},
  {id='C',label='Centre',angle=0}, {id='LFE',label='LFE',lfe=true},
  {id='Ls',label='Left Surround',angle=-110}, {id='Rs',label='Right Surround',angle=110},
  {id='Lss',label='Left Side',angle=-90}, {id='Rss',label='Right Side',angle=90},
  {id='Lrs',label='Left Rear',angle=-135}, {id='Rrs',label='Right Rear',angle=135},
  {id='Cs',label='Rear Centre',angle=180},
  {id='Lc',label='Left Centre',angle=-15}, {id='Rc',label='Right Centre',angle=15},
  {id='Lw',label='Left Wide',angle=-60}, {id='Rw',label='Right Wide',angle=60},
  {id='Tfl',label='Top Front Left',angle=-30,elevation=45},
  {id='Tfr',label='Top Front Right',angle=30,elevation=45},
  {id='Tsl',label='Top Side Left',angle=-90,elevation=45},
  {id='Tsr',label='Top Side Right',angle=90,elevation=45},
  {id='Trl',label='Top Rear Left',angle=-135,elevation=45},
  {id='Trr',label='Top Rear Right',angle=135,elevation=45},
  {id='Tc',label='Top Centre',angle=0,elevation=90},
}
local BY_ID = {}
for _, role in ipairs(ROLES) do
  -- ITU-R BS.1770-5 Annex 3, Tables 4–5. Rear and height speakers
  -- do not share the side-surround weighting; LFE is excluded from LUFS.
  role.weight = role.lfe and 0 or role.angle and
    (math.abs(role.angle)>=60 and math.abs(role.angle)<=120
      and (role.elevation or 0)<30 and 1.41 or 1) or 0
  BY_ID[role.id] = role
end
local arrangements=require('core.speaker_arrangements')
local function integer(n, low, high)
  return type(n)=='number' and n==math.floor(n) and n>=low and n<=high
end
function channels.roles() return ROLES end
function channels.presets(count)
  local result={{label='Unassigned',roles={}}}
  for i=1,count do result[1].roles[i]='unknown' end
  for _,item in ipairs(arrangements.list(count)) do
    for _,order in ipairs(item.orders) do
      result[#result+1]={label=item.label..' · '..order.label,roles=order.roles}
    end
  end
  return result
end
function channels.profile(count, setting)
  if not integer(count,1,8) then return nil,'Analysis supports one to eight channels.' end
  setting=setting or {}
  if type(setting)~='table' then return nil,'Channel settings are damaged.' end
  local roles=setting.roles
  if roles==nil then
    roles=count==1 and {'M'} or count==2 and {'L','R'} or {}
    if count>2 then for i=1,count do roles[i]='unknown' end end
  end
  if type(roles)~='table' or #roles~=count then return nil,'Assign every source channel.' end
  local profile={count=count,known=true,roles={},labels={},weights={},positions={}}
  local seen={}
  for i=1,count do
    local role=BY_ID[roles[i]]
    if not role then return nil,'This speaker assignment is unavailable.' end
    if role.id~='unknown' and seen[role.id] then return nil,'Each speaker can be assigned only once.' end
    seen[role.id]=true
    profile.roles[i],profile.labels[i]=role.id,role.id=='unknown' and tostring(i) or role.short or role.id
    profile.weights[i]=role.weight
    if role.id=='unknown' then profile.known=false end
    profile.positions[i]={angle=role.angle,elevation=role.elevation or 0,lfe=role.lfe==true}
  end
  if not profile.known then for i=1,count do profile.weights[i]=0 end end
  profile.pair_left=setting.pair_left or 1
  profile.pair_right=setting.pair_right or math.min(2,count)
  if not integer(profile.pair_left,1,count) or not integer(profile.pair_right,1,count) then
    return nil,'The selected channel pair is unavailable.'
  end
  profile.view=setting.view or (count>2 and 'surround' or 'pair')
  if profile.view~='surround' and profile.view~='pair' then return nil,'This channel view is unavailable.' end
  profile.signature=count..':'..table.concat(profile.roles,',')
  return profile
end
function channels.setting(profile)
  local roles={}
  for i=1,profile.count do roles[i]=profile.roles[i] end
  return {count=profile.count,roles=roles,pair_left=profile.pair_left,
    pair_right=profile.pair_right,view=profile.view}
end
function channels.encode(identity, profile, available_count)
  local valid,err=channels.profile(profile.count,channels.setting(profile))
  if not valid then return nil,err end
  if available_count~=nil and not integer(available_count,1,128) then
    return nil,'The project channel count is unavailable.'
  end
  return json.encode({version=available_count and 2 or 1,identity=identity,
    available_count=available_count,setting=channels.setting(valid)})
end
function channels.decode(text,identity,count)
  if not text or text=='' then return channels.profile(count) end
  local ok,record=pcall(json.decode,text)
  if not ok or type(record)~='table' then return nil,'Channel settings are damaged.' end
  if record.version~=1 and record.version~=2 then return nil,'This version cannot read the saved channel settings.' end
  if record.version==2 and not integer(record.available_count,1,128) then
    return nil,'Channel settings are damaged.'
  end
  if record.identity~=identity then return nil,'The saved channel settings belong to another source.' end
  if type(record.setting)~='table' or not integer(record.setting.count,1,8) then
    return nil,'Channel settings are damaged.'
  end
  -- A replaced file's old speaker assignments must not label its new channels.
  if record.setting.count~=count then return channels.profile(count) end
  return channels.profile(count,record.setting)
end

-- A top-down energy display, not a phase or source-localisation estimate.
function channels.field(profile, values)
  local points,total,x,y={},0,0,0
  for i=1,profile.count do
    local position=profile.positions[i]
    local level=values and values[i] and values[i].rms
    local power=type(level)=='number' and level==level and level>-150 and level<100
      and 10^(level/10) or 0
    local angle=position.angle and math.rad(position.angle)
    local px,py=angle and math.sin(angle) or 0,angle and -math.cos(angle) or 0
    -- Use the displayed height positions for the balance dot too. An overhead
    -- centre speaker has no horizontal direction in this top-down view.
    local radius=position.elevation>=90 and 0 or position.elevation>0 and .66 or 1
    px,py=px*radius,py*radius
    points[i]={x=px,y=py,power=power,lfe=position.lfe,elevation=position.elevation}
    if angle and not position.lfe then
      total=total+power; x=x+px*power; y=y+py*power
    end
  end
  return points,total>0 and x/total or nil,total>0 and y/total or nil
end
return channels
