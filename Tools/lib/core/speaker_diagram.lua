-- Speaker positions stay fixed while crowded labels can move around their ring.
local diagram={}
local function overlaps(a,b,gap)
  return a.x<b.x+b.w+gap and a.x+a.w+gap>b.x
    and a.y<b.y+b.h+gap and a.y+a.h+gap>b.y
end
local function distance_to_box(x,y,box)
  local dx=x-math.max(box.x,math.min(x,box.x+box.w))
  local dy=y-math.max(box.y,math.min(y,box.y+box.h))
  return math.sqrt(dx*dx+dy*dy)
end

function diagram.layout(profile,box,measure,scale,marker)
  scale,marker=scale or 1,(marker or 7)*(scale or 1)
  local gap,pad=4*scale,6*scale
  local cx,cy=box.x+box.width/2,box.y+box.height/2
  local entries,max_extent={},0
  if profile then
    for i,position in ipairs(profile.positions) do
      if position.angle~=nil or position.lfe then
        local text=box.numbers and tostring(i) or profile.labels[i]
        local w,h=measure(text)
        max_extent=math.max(max_extent,math.sqrt(w*w+h*h)/2)
        entries[#entries+1]={channel=i,text=text,w=w,h=h,angle=math.rad(position.angle or 0),
          ring=position.elevation>0 and .66 or 1,overhead=position.elevation>=90,lfe=position.lfe}
      end
    end
  end
  local maximum=math.min(box.width,box.height)/2-pad-marker-gap-max_extent
  local geometry_maximum=math.min(box.width,box.height)/2-pad-marker
  local work=0
  local function positions(radius)
    local result={cx=cx,cy=cy,radius=radius,inner_radius=radius*.66,points={},gap=gap,marker=marker}
    for _,entry in ipairs(entries) do
      local distance=entry.overhead and 0 or radius*entry.ring
      local px,py=math.sin(entry.angle)*distance,-math.cos(entry.angle)*distance
      if entry.lfe then px,py=-box.width/2+pad+marker,box.height/2-pad-math.max(marker,entry.h/2) end
      result.points[#result.points+1]={x=cx+px,y=cy+py,channel=entry.channel,lfe=entry.lfe,ring=entry.ring}
    end
    return result
  end
  local function candidates(entry,result,spread)
    local found={}
    local function add(angle,extra,offset)
      local dx,dy=math.sin(angle),-math.cos(angle)
      local support=(math.abs(dx)*entry.w+math.abs(dy)*entry.h)/2
      local distance=result.radius*entry.ring+marker+gap+support+extra
      local bounds={x=cx+dx*distance-entry.w/2,y=cy+dy*distance-entry.h/2,w=entry.w,h=entry.h,
        text=entry.text,moved=offset~=0,cost=math.abs(offset)*16+extra/scale}
      if entry.lfe then
        local point=result.points[entry.index]
        bounds.x,bounds.y=point.x+marker+gap,point.y-entry.h/2
      end
      if bounds.x<box.x+pad or bounds.x+bounds.w>box.x+box.width-pad
          or bounds.y<box.y+pad or bounds.y+bounds.h>box.y+box.height-pad then return end
      for _,point in ipairs(result.points) do
        if distance_to_box(point.x,point.y,bounds)<marker+gap-1e-8 then return end
      end
      found[#found+1]=bounds
    end
    -- One radial position keeps ordinary layouts unchanged. Angular candidates
    -- offer space for coincident and closely spaced custom speaker roles.
    if entry.lfe then add(0,0,0); return found end
    for offset=0,spread and 12 or 0 do
      for _,sign in ipairs(offset==0 and {1} or {-1,1}) do
        local angle=entry.angle+offset*sign*math.pi/12
        for tier=0,3 do add(angle,tier*8*scale,offset) end
      end
    end
    table.sort(found,function(a,b)
      if a.cost~=b.cost then return a.cost<b.cost end
      if a.x~=b.x then return a.x<b.x end
      return a.y<b.y
    end)
    return found
  end
  local function place(radius,spread)
    local result=positions(radius)
    local pending={}
    for index,entry in ipairs(entries) do
      entry.index=index
      local choices=candidates(entry,result,spread)
      if #choices==0 then return end
      pending[#pending+1]={index=index,choices=choices}
    end
    table.sort(pending,function(a,b)
      if #a.choices~=#b.choices then return #a.choices<#b.choices end
      return a.index<b.index
    end)
    local selected={}
    local attempt_work=0
    local function assign(index)
      if index>#pending then return true end
      local item=pending[index]
      for _,bounds in ipairs(item.choices) do
        if attempt_work>=(spread and 1024 or 128) then return end
        work,attempt_work=work+1,attempt_work+1
        local free=true
        for _,other in pairs(selected) do if overlaps(bounds,other,gap*.5) then free=false; break end end
        if free then
          selected[item.index]=bounds
          if assign(index+1) then return true end
          selected[item.index]=nil
        end
      end
    end
    if not assign(1) then return end
    for index,point in ipairs(result.points) do
      local bounds=selected[index]
      point.label=bounds
      if bounds.moved then
        local ex=math.max(bounds.x,math.min(point.x,bounds.x+bounds.w))
        local ey=math.max(bounds.y,math.min(point.y,bounds.y+bounds.h))
        local dx,dy=ex-point.x,ey-point.y
        local distance=math.sqrt(dx*dx+dy*dy)
        point.leader={x1=point.x+dx*marker/distance,y1=point.y+dy*marker/distance,
          x2=ex-dx*scale/distance,y2=ey-dy*scale/distance}
      end
    end
    result.fits,result.work=true,work
    return result
  end
  if maximum>=16*scale then
    local result
    for step=0,3 do
      local radius=maximum*(1-step*.15)
      if radius>=16*scale then
        result=place(radius,false)
        if result then return result end
      end
    end
    -- Four bounded sizes preserve a useful field instead of searching down to
    -- a one-pixel ring. The callers cache the finished layout across frames.
    for step=0,3 do
      local radius=maximum*(1-step*.15)
      if radius>=16*scale then
        result=place(radius,true)
        if result then return result end
      end
    end
  end
  local result=positions(math.max(0,math.min(math.max(16*scale,maximum),geometry_maximum)))
  result.fits,result.compact,result.work=false,true,work
  result.reason='labels_unavailable'
  if geometry_maximum<16*scale then
    result.points,result.radius,result.inner_radius={},0,0
    result.reason='frame_too_small'
  end
  return result
end
return diagram
