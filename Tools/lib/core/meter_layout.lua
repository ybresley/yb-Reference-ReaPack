-- Meter groups keep their own axes; history moves beside or below them.
local layout = {}
local divider_pairs=require('core.divider_pairs')
local CONTENT={'loudness','lr','readings','history'}

local function rect(x,y,w,h) return {x=x,y=y,w=math.max(0,w),h=math.max(0,h)} end
local function clamp(value,low,high) return math.max(low,math.min(high,value)) end

local function split(splits,key)
  local value=splits and splits[key]
  if type(value)~='number' or value~=value or math.abs(value)==math.huge then return nil end
  return clamp(value,0,1)
end

local function ordered_content(splits,result)
  local order,seen={},{}
  for _,key in ipairs(splits and splits.order or {}) do
    if (key=='loudness' or key=='lr' or key=='readings' or key=='history')
      and not seen[key] then
      order[#order+1]=key
      seen[key]=true
    end
  end
  for _,key in ipairs(CONTENT) do
    if not seen[key] then order[#order+1]=key end
  end
  local visible={}
  for _,key in ipairs(order) do
    if result[key] then visible[#visible+1]=key end
  end
  return order,visible
end

local function occupant_min(key,axis,s,options,history_min)
  if axis=='y' then
    if key=='readings' then return (options.readings_min_height or 120)*s end
    return (key=='history' and 100 or 120)*s
  end
  if key=='loudness' then return 180*s end
  if key=='lr' then return 132*s end
  if key=='readings' then return 88*s end
  return history_min*s
end

local function fit_swapped_slots(result,slot_ids,occupants,gap,s,options,history_min)
  local top={}
  for index,slot in ipairs(slot_ids) do
    if result[slot].y==0 then
      top[#top+1]={slot=slot,content=occupants[index],box=result[slot]}
    end
  end
  table.sort(top,function(a,b) return a.box.x<b.box.x end)
  local width_total,minimum_total=0,0
  for _,entry in ipairs(top) do
    entry.minimum=occupant_min(entry.content,'x',s,options,history_min)
    width_total=width_total+entry.box.w
    minimum_total=minimum_total+entry.minimum
  end
  if width_total>=minimum_total then
    for _,entry in ipairs(top) do
      local need=math.max(0,entry.minimum-entry.box.w)
      for _,donor in ipairs(top) do
        if need<=0 then break end
        local available=math.max(0,donor.box.w-donor.minimum)
        local take=math.min(need,available)
        donor.box.w=donor.box.w-take
        entry.box.w=entry.box.w+take
        need=need-take
      end
    end
    local next_x=0
    for _,entry in ipairs(top) do
      entry.box.x=next_x
      next_x=next_x+entry.box.w+gap
    end
  end
  local below
  for index,slot in ipairs(slot_ids) do
    if result[slot].y>0 then below={slot=slot,content=occupants[index]} end
  end
  if below then
    local bottom=result[below.slot]
    local top_min=0
    for _,entry in ipairs(top) do
      top_min=math.max(top_min,occupant_min(entry.content,'y',s,options,history_min))
    end
    local bottom_min=occupant_min(below.content,'y',s,options,history_min)
    local available=bottom.y+bottom.h-gap
    if available>=top_min+bottom_min then
      local boundary=clamp(bottom.y-gap,top_min,available-bottom_min)
      for _,entry in ipairs(top) do entry.box.h=boundary end
      bottom.y=boundary+gap
      bottom.h=available-boundary
    end
  end
end

local function add_seams(result,gap)
  local seams={}
  local function add(key,axis,x,y,w,h,value_offset)
    if w>0 and h>0 then
      seams[#seams+1]={key=key,axis=axis,x=x,y=y,w=w,h=h,
        value_offset=value_offset or 0}
    end
  end
  local loudness,lr,readings,history=result.loudness,result.lr,result.readings,result.history
  if loudness and lr then
    add('loudness_lr','x',loudness.x+loudness.w,0,gap,loudness.h)
  end
  local last=lr or loudness
  if last and readings then
    add('readings_x','x',last.x+last.w,0,gap,last.h,gap)
  end
  if history and last then
    if history.y>0 then
      add('history_y','y',0,last.h,history.w,gap)
    else
      local neighbour=readings or last
      add('history_x','x',neighbour.x+neighbour.w,0,gap,history.h,gap)
    end
  end
  result.seams=seams
end

function layout.calculate(width,height,options)
  options=options or {}
  local s=options.scale or 1
  width,height=math.max(0,width),math.max(0,height)
  local gap=math.min(8*s,width/12,height/12)
  local show_meters=options.show_meters~=false
  local loudness=show_meters and options.show_loudness~=false
  local lr=show_meters and options.show_lr~=false
  local show_history=options.show_history~=false
  if not loudness and not lr and not show_history then
    if show_meters then loudness=true else show_history=true end
  end
  local result={}
  local readings_w=(options.readings_width or 0)*s
  local minimum=(loudness and lr) and 312 or (loudness and 210 or (lr and 130 or 160))
  local compact=options.compact_meters==true and (loudness or lr)
  if compact then
    show_history=false
    readings_w=0
    if options.show_history~=false then result.history_hidden=true end
    if options.show_readings~=false then result.readings_hidden=true end
  end
  local position=options.history_position or 'Automatic'
  local history_min=height<230*s and 170 or 220
  if position=='Beside Meters' then
    history_min=height<230*s and 140 or 160
  end
  local plot_width=width
  if readings_w>0 then
    local required=minimum*s
    -- In short windows history cannot move below; readings must not displace it.
    if show_history and (loudness or lr) and height<220*s+gap and position~='Below Meters' then
      required=required+history_min*s+gap
    end
    if height>=(options.readings_min_height or 0)*s and width-readings_w-gap>=required then
      plot_width=width-readings_w-gap
    else
      result.readings_hidden=true
      readings_w=0
    end
  end
  local picture_h=height
  local meter_w,meter_h=plot_width,picture_h
  if show_history and (loudness or lr) then
    if position~='Below Meters' and plot_width>=(minimum+history_min)*s+gap then
      meter_w=math.max(minimum*s,math.floor((plot_width-gap)*.60))
      result.history=rect(meter_w+gap,0,plot_width-meter_w-gap,picture_h)
    elseif picture_h>=220*s+gap then
      local desired=options.top_row_height or math.floor((picture_h-gap)*.56)
      meter_h=math.max(120*s,math.min(desired,picture_h-gap-100*s))
      result.history=rect(0,meter_h+gap,width,picture_h-meter_h-gap)
    else
      result.history_hidden=true
    end
  elseif show_history then result.history=rect(0,0,plot_width,picture_h) end

  -- Readings belong to the meter row, never to the history row underneath it.
  if readings_w>0 and (loudness or lr) and meter_h<(options.readings_min_height or 0)*s then
    readings_w=0
    plot_width=width
    meter_w=width
    result.readings_hidden=true
  end

  -- Choose the arrangement with the same space allowance in both toggle states,
  -- then return unused readings space to the plots without changing their rows.
  if options.show_readings==false then
    if readings_w>0 then
      plot_width=width
      if result.history and result.history.x>0 then
        meter_w=math.max(minimum*s,math.floor((width-gap)*.60))
        result.history=rect(meter_w+gap,0,width-meter_w-gap,picture_h)
      else
        meter_w=width
        if result.history then result.history.w=width end
      end
      readings_w=0
    end
    result.readings_hidden=nil
  end

  -- Reserve readings before choosing an arrangement. Growing the window must
  -- not switch to side-by-side plots that leave no room for a visible column.
  if readings_w>0 then
    if result.history and result.history.x>0 then
      result.readings=rect(meter_w+gap,0,readings_w,meter_h)
      result.history.x=result.history.x+readings_w+gap
    else
      result.readings=rect(plot_width+gap,0,readings_w,meter_h)
    end
  end

  if loudness and lr then
    local loudness_w
    if compact then
      -- Compact groups share five equal lanes and keep scales at the outside edges.
      local lane=math.max(0,(meter_w-gap-67*s)/5)
      loudness_w=math.min(math.max(0,meter_w-gap),32*s+lane*3)
    else
      loudness_w=math.min(math.floor((meter_w-gap)*.68),math.max(0,meter_w-gap-132*s))
    end
    result.loudness=rect(0,0,loudness_w,meter_h)
    result.lr=rect(loudness_w+gap,0,meter_w-loudness_w-gap,meter_h)
  elseif loudness then result.loudness=rect(0,0,meter_w,meter_h)
  elseif lr then result.lr=rect(0,0,meter_w,meter_h) end

  -- The saved arrangement returns when space permits; compression never rewrites it.
  local splits=not compact and options.splits or nil
  local content_history_min=result.history and result.history.y>0 and 160 or history_min
  local slot_content
  if splits and splits.order then
    slot_content={}
    local _,occupants=ordered_content(splits,result)
    local index=1
    for _,key in ipairs(CONTENT) do
      if result[key] then
        slot_content[key]=occupants[index]
        index=index+1
      end
    end
  end
  local function slot_min(slot,axis,normal)
    if not slot_content then return normal end
    return occupant_min(slot_content[slot],axis,s,options,content_history_min)
  end
  local last=result.lr or result.loudness
  local history=result.history
  local readings=result.readings
  local history_x=split(splits,'history_x')
  if history_x and history and history.y==0 and last then
    local neighbour=readings or last
    local neighbour_min=readings and math.min(readings.w,slot_min('readings','x',88*s))
      or (result.lr and math.min(last.w,132*s) or math.min(last.w,210*s))
    if not readings then
      neighbour_min=math.min(last.w,slot_min(result.lr and 'lr' or 'loudness',
        'x',result.lr and 132*s or 210*s))
    end
    local history_min_w=math.min(history.w,slot_min('history','x',history_min*s))
    local target=clamp(history_x*width,neighbour.x+neighbour_min+gap,
      width-history_min_w)
    neighbour.w=target-gap-neighbour.x
    history.x=target
    history.w=width-target
  end

  local history_y=split(splits,'history_y')
  if history_y and history and history.y>0 and last then
    local meter_min=math.min(last.h,120*s)
    if slot_content then
      for _,key in ipairs({'loudness','lr','readings'}) do
        if result[key] then meter_min=math.max(meter_min,slot_min(key,'y',120*s)) end
      end
    end
    local history_min_h=math.min(history.h,slot_min('history','y',100*s))
    local target=clamp(history_y*height,meter_min,height-gap-history_min_h)
    for _,key in ipairs({'loudness','lr','readings'}) do
      if result[key] then result[key].h=target end
    end
    history.y=target+gap
    history.h=height-target-gap
  end

  local readings_x=split(splits,'readings_x')
  if readings_x and readings and last then
    local right=readings.x+readings.w
    local meter_min=result.lr and math.min(last.w,132*s)
      or math.min(last.w,210*s)
    meter_min=math.min(last.w,slot_min(result.lr and 'lr' or 'loudness',
      'x',meter_min))
    local readings_min=math.min(readings.w,slot_min('readings','x',88*s))
    local target=clamp(readings_x*width,last.x+meter_min+gap,
      right-readings_min)
    last.w=target-gap-last.x
    readings.x=target
    readings.w=right-target
  end

  local loudness_lr=split(splits,'loudness_lr')
  if loudness_lr and result.loudness and result.lr then
    local a,b=result.loudness,result.lr
    local right=b.x+b.w
    local a_min,b_min=math.min(a.w,slot_min('loudness','x',180*s)),
      math.min(b.w,slot_min('lr','x',132*s))
    local target=clamp(loudness_lr*width,a_min,right-gap-b_min)
    a.w=target
    b.x=target+gap
    b.w=right-b.x
  end
  if splits and splits.order then
    local _,occupants=ordered_content(splits,result)
    local slot_ids={}
    for _,key in ipairs(CONTENT) do
      if result[key] then slot_ids[#slot_ids+1]=key end
    end
    fit_swapped_slots(result,slot_ids,occupants,gap,s,options,content_history_min)
    add_seams(result,gap)
    local boxes={}
    for index,slot in ipairs(slot_ids) do boxes[index]=result[slot] end
    for index,content in ipairs(occupants) do result[content]=boxes[index] end
    result.swapped=true
    return result
  end
  add_seams(result,gap)
  return result
end

function layout.swap(splits,a,b,geometry)
  if a==b or not geometry or not geometry[a] or not geometry[b] then return nil end
  local panels={}
  for _,key in ipairs(CONTENT) do
    local r=geometry[key]
    if r then panels[#panels+1]={id=key,x=r.x,y=r.y,w=r.w,h=r.h} end
  end
  local adjacent=false
  for _,pair in ipairs(divider_pairs.measure(panels,geometry.seams or {})) do
    if (pair.a==a and pair.b==b) or (pair.a==b and pair.b==a) then
      adjacent=true
      break
    end
  end
  if not adjacent then return nil end
  local order=ordered_content(splits,geometry)
  local first,second
  for index,key in ipairs(order) do
    if key==a then first=index elseif key==b then second=index end
  end
  if not first or not second then return nil end
  order[first],order[second]=order[second],order[first]
  local updated={}
  for key,value in pairs(splits or {}) do
    if key~='order' then updated[key]=value end
  end
  updated.order=order
  return updated
end

return layout
