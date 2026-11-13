local channels=require('core.analysis_channels')
local diagram=require('core.speaker_diagram')
local outline=require('core.surround_outline')
local theme=require('ui.theme')
local settings=require('ui.stereo_settings')
local tips=require('ui.tips')
local field={}
-- Caches and afterglow belong to one drawn field. The live panel keeps its own;
-- a demonstration passes another through presentation.store so the two never
-- share an afterglow or a clock. The afterglow clock stops while the display is
-- frozen, so held shapes stay put.
function field.new_store()
  return {placement=nil,shape={signature=nil,shape=nil},clock={now=0,last=nil},
    trail=outline.new_trail(36),trail_signature=nil}
end
local live_store=field.new_store()
local amounts,phases={},{}
local CURVE_STEPS=12
local POINT_CAPACITY=256
local HOVER_RADIUS=8
local GENERAL_TIP='Speaker levels from channel RMS. The white dot shows energy balance, and its ring grows as the sound spreads. LFE is separate; height speakers use the inner ring.'
local PHASE_TIP='Speaker levels from channel RMS. Blue sides are in phase, red sides have opposite polarity, and grey sides are unrelated or too quiet to compare. Ring arcs show where shared sound sits; point at a side for its reading. The white dot shows energy balance, and its ring grows as the sound spreads. LFE is separate; height speakers use the inner ring.'

-- Per-frame drawing context. Reused so the frame loop allocates no tables.
local frame={R=nil,dl=nil,T=nil,scale=1,ox=0,oy=0,cx=0,cy=0,by_channel=nil,shape=nil,points=nil,used=0}

-- Returns the afterglow time, and whether the field went undrawn long enough
-- (hidden pane, other view) that its old shapes no longer belong on screen.
local MAX_STEP=0.25
local function advance_clock(ctx,clock,frozen)
  local now=reaper.ImGui_GetTime(ctx)
  local step=clock.last and now-clock.last or 0
  if clock.last and not frozen then clock.now=clock.now+math.max(0,math.min(MAX_STEP,step)) end
  clock.last=now
  return clock.now,step>MAX_STEP
end

local function shape_for(shape_cache,profile)
  local signature=profile and profile.signature or ''
  if shape_cache.signature~=signature then
    shape_cache.signature,shape_cache.shape=signature,outline.shape(profile)
  end
  return shape_cache.shape
end

-- Level fraction per channel, and the usable correlation for each floor side
-- (false when the side stays neutral). Returns whether the helper sent phase.
local function read_values(shape,values,count)
  for i=1,count do
    local value=values and values[i]
    amounts[i]=value and outline.amount(value.rms) or 0
  end
  local correlations=values and values.correlations
  local any_side=false
  for k,edge in ipairs(shape.edges) do
    local reading=false
    any_side=any_side or edge.phase
    if correlations and edge.phase then
      local a,b=values[edge.a],values[edge.b]
      reading=outline.phase(correlations[outline.pair_index(edge.a,edge.b,count)],
        a and a.rms,b and b.rms) or false
    end
    phases[k]=reading
  end
  -- Phase is shown only when the meter sent pairs and some side can use one.
  return correlations~=nil and any_side
end

-- Screen position of a channel's level tip on its spoke.
local function tip(channel,amount)
  local point=frame.by_channel[channel]
  return frame.ox+frame.cx+(point.x-frame.cx)*amount,frame.oy+frame.cy+(point.y-frame.cy)*amount
end

-- Blue and red are reserved for phase readings. Any side without one, including
-- every side when the meter sends no phase, stays grey.
local function side_colour(T,reading)
  local mix=outline.phase_mix(reading or nil)
  if mix>=0 then return theme.blend(T.TEXT_SECONDARY,T.STEREO_TRACE,mix) end
  return theme.blend(T.TEXT_SECONDARY,T.STEREO_CLIP,-mix)
end

-- Walks the outline, handing each side's end points and control point to
-- visit. Sides that close behind the listener pass through the centre.
local function each_side(shape,levels,readings,visit,extra)
  local cx,cy=frame.ox+frame.cx,frame.oy+frame.cy
  for k,edge in ipairs(shape.edges) do
    local ax,ay=tip(edge.a,levels[edge.a] or 0)
    local bx,by=tip(edge.b,levels[edge.b] or 0)
    if edge.through_centre then
      visit(k,edge,ax,ay,cx,cy,bx,by,true,extra)
    else
      local qx,qy=outline.bend(ax,ay,bx,by,cx,cy,readings[k] or nil)
      visit(k,edge,ax,ay,qx,qy,bx,by,false,extra)
    end
  end
end

local function stroke_side(ax,ay,qx,qy,bx,by,straight,colour,thickness)
  local R,dl=frame.R,frame.dl
  if straight then
    R.ImGui_DrawList_AddLine(dl,ax,ay,qx,qy,colour,thickness)
    R.ImGui_DrawList_AddLine(dl,qx,qy,bx,by,colour,thickness)
  else
    R.ImGui_DrawList_AddBezierQuadratic(dl,ax,ay,qx,qy,bx,by,colour,thickness,0)
  end
end

local function add_point(px,py)
  local used=frame.used+1
  if used*2>POINT_CAPACITY then return end
  frame.points[used*2-1],frame.points[used*2]=px,py
  frame.used=used
end

local function collect_side(_,_,ax,ay,qx,qy,bx,by,straight)
  if straight then add_point(ax,ay); add_point(qx,qy); return end
  for step=0,CURVE_STEPS-1 do add_point(outline.curve_point(ax,ay,qx,qy,bx,by,step/CURVE_STEPS)) end
end

local function glow_side(_,_,ax,ay,qx,qy,bx,by,straight,colour)
  stroke_side(ax,ay,qx,qy,bx,by,straight,colour,frame.scale)
end

local function glow(item,alpha)
  each_side(frame.shape,item.amounts,item.phases,glow_side,theme.fade(frame.T.TEXT_SECONDARY,alpha))
end

-- Distance from the pointer to the segment p-q.
local function segment_distance(mx,my,px,py,qx,qy)
  local dx,dy=qx-px,qy-py
  local length=dx*dx+dy*dy
  local t=length>0 and math.max(0,math.min(1,((mx-px)*dx+(my-py)*dy)/length)) or 0
  local ex,ey=px+dx*t-mx,py+dy*t-my
  return math.sqrt(ex*ex+ey*ey)
end

local hover={active=false,mx=0,my=0,best=nil,distance=0,has_phase=false}
local function live_side(k,edge,ax,ay,qx,qy,bx,by,straight)
  local reading=not straight and phases[k] or nil
  stroke_side(ax,ay,qx,qy,bx,by,straight,side_colour(frame.T,reading),(hover.has_phase and 2 or 1.5)*frame.scale)
  if hover.active and edge.phase then
    -- Test the whole curve, not only its midpoint, so any part of a side responds.
    local px,py=ax,ay
    for step=1,CURVE_STEPS do
      local sx,sy=outline.curve_point(ax,ay,qx,qy,bx,by,step/CURVE_STEPS)
      local distance=segment_distance(hover.mx,hover.my,px,py,sx,sy)
      if distance<hover.distance then hover.best,hover.distance=k,distance end
      px,py=sx,sy
    end
  end
end

local function hover_text(profile,edge,reading)
  local a,b=profile.labels[edge.a],profile.labels[edge.b]
  if not reading then return string.format('%s – %s: too quiet or uneven to compare',a,b) end
  return string.format('%s – %s: correlation %+.2f, %s',a,b,reading,outline.verdict(reading))
end

-- Returns the panel action, then the hovered side's reading text (nil when no
-- side is hovered). presentation.pointer lets a demonstration hover a side
-- with its own scripted position; tips stay with the caller there.
function field.draw(ctx,state,width,height,res,exclusion,panel_x,panel_width,presentation)
  local R,T=reaper,theme.tokens
  local store=presentation and presentation.store or live_store
  local scale=theme.scale
  local x,y=R.ImGui_GetCursorScreenPos(ctx)
  local dl=R.ImGui_GetWindowDrawList(ctx)
  R.ImGui_DrawList_AddRectFilled(dl,x,y,x+width,y+height,T.STEREO_BG,3*scale)
  R.ImGui_Dummy(ctx,width,height)
  local blocked=presentation and presentation.blocked
  local action
  if not blocked then action=settings.draw(ctx,state,res,panel_x or x,y,panel_width or width,height,exclusion,presentation) end
  local profile=state.preview_analysis_profile or state.analysis_output_profile or state.analysis_channels
  local font_w,font_h=R.ImGui_CalcTextSize(ctx,'MW0123456789')
  local signature=table.concat({tostring(ctx),profile and profile.signature or '',width,height,scale,
    R.ImGui_GetFontSize(ctx),font_w,font_h},':')
  local placement_cache=store.placement
  if not placement_cache or placement_cache.signature~=signature then
    local layout=diagram.layout(profile,
      {x=0,y=0,width=width,height=height},
      function(text) return R.ImGui_CalcTextSize(ctx,text) end,scale,7)
    local by_channel={}
    for _,placement in ipairs(layout.points) do by_channel[placement.channel]=placement end
    placement_cache={signature=signature,layout=layout,by_channel=by_channel}
    store.placement=placement_cache
  end
  local layout=placement_cache.layout
  local frozen=state.stereo and state.stereo.frozen
  local now,gap=advance_clock(ctx,store.clock,frozen)
  local hover_tip
  hover.has_phase=false
  R.ImGui_DrawList_PushClipRect(dl,x,y,x+width,y+height,true)
  if profile and profile.known and layout.radius>0 then
    frame.R,frame.dl,frame.T,frame.scale=R,dl,T,scale
    frame.ox,frame.oy,frame.cx,frame.cy=x,y,layout.cx,layout.cy
    frame.by_channel=placement_cache.by_channel
    local cx,cy,radius=x+layout.cx,y+layout.cy,layout.radius
    R.ImGui_DrawList_AddCircle(dl,cx,cy,radius,T.STROKE_PRIMARY,64,scale)
    R.ImGui_DrawList_AddCircle(dl,cx,cy,layout.inner_radius,T.SPECTRUM_GRID,48,scale)
    R.ImGui_DrawList_AddLine(dl,cx-radius,cy,cx+radius,cy,T.SPECTRUM_GRID,scale)
    R.ImGui_DrawList_AddLine(dl,cx,cy-radius,cx,cy+radius,T.SPECTRUM_GRID,scale)
    local shape=shape_for(store.shape,profile)
    frame.shape=shape
    -- Quiet spokes show each floor and height speaker's axis.
    for _,channel in ipairs(shape.floor) do
      local point=frame.by_channel[channel]
      R.ImGui_DrawList_AddLine(dl,cx,cy,x+point.x,y+point.y,T.SPECTRUM_GRID,scale)
    end
    for _,channel in ipairs(shape.heights) do
      local point=frame.by_channel[channel]
      R.ImGui_DrawList_AddLine(dl,cx,cy,x+point.x,y+point.y,T.SPECTRUM_GRID,scale)
    end

    local values=not blocked and state.surround_channels or nil
    local has_phase=read_values(shape,values,profile.count)
    local trail=store.trail
    if store.trail_signature~=profile.signature or not values or (gap and not frozen) then
      outline.clear_trail(trail); store.trail_signature=profile.signature
    end
    if values and not frozen then
      outline.record(trail,now,amounts,has_phase and phases or nil,profile.count)
    end

    if values and #shape.floor>0 then
      -- Afterglow: recent shapes fade behind the live one, like the stereo dots.
      outline.each_glow(trail,now,glow,3)
      local points=state.surround_outline_points
      if points and R.ImGui_DrawList_AddConcavePolyFilled then
        frame.points,frame.used=points,0
        each_side(shape,amounts,phases,collect_side)
        if frame.used>=3 then
          points.resize(frame.used*2)
          R.ImGui_DrawList_AddConcavePolyFilled(dl,points,theme.fade(T.STEREO_TRACE,0.12))
          points.resize(POINT_CAPACITY)
        end
      end
      hover.has_phase=has_phase
      local scripted=presentation and presentation.pointer
      if scripted then
        hover.active=has_phase and scripted.x>=x and scripted.x<=x+width
          and scripted.y>=y and scripted.y<=y+height
        hover.mx,hover.my=scripted.x,scripted.y
      else
        hover.active=not presentation and has_phase and R.ImGui_IsMouseHoveringRect(ctx,x,y,x+width,y+height)
        if hover.active then hover.mx,hover.my=R.ImGui_GetMousePos(ctx) end
      end
      hover.best,hover.distance=nil,HOVER_RADIUS*scale
      each_side(shape,amounts,phases,live_side)
      if hover.best then hover_tip=hover_text(profile,shape.edges[hover.best],phases[hover.best]) end
      -- Phantom images: arcs on the ring between neighbouring speakers.
      if has_phase then
        for k,edge in ipairs(shape.edges) do
          local reading=phases[k]
          local first,last,centre
          if reading then first,last,centre=outline.phantom(values[edge.a].rms,values[edge.b].rms,reading) end
          if first then
            local start=edge.a_angle-math.pi/2
            R.ImGui_DrawList_PathArcTo(dl,cx,cy,radius,start+edge.span*first,start+edge.span*last,12)
            R.ImGui_DrawList_PathStroke(dl,theme.fade(side_colour(T,reading),0.75),0,3*scale)
            local angle=start+edge.span*centre
            R.ImGui_DrawList_AddCircleFilled(dl,cx+math.cos(angle)*radius,cy+math.sin(angle)*radius,
              2.5*scale,T.TEXT_PRIMARY,12)
          end
        end
      end
    end

    -- Speaker markers, level tips, heights and LFE.
    for _,placement in ipairs(layout.points) do
      local i=placement.channel
      local px,py=x+placement.x,y+placement.y
      local leader=layout.fits and placement.leader
      if leader then
        R.ImGui_DrawList_AddLine(dl,x+leader.x1,y+leader.y1,x+leader.x2,y+leader.y2,T.STROKE_PRIMARY,scale)
      end
      local value=values and values[i]
      local clipped=value and value.peak and value.peak>=0
      local colour=clipped and T.STEREO_CLIP or T.STEREO_TRACE
      local amount=amounts[i] or 0
      local position=profile.positions[i]
      if position.lfe or (position.elevation or 0)>=90 then
        -- LFE and overhead speakers have no spoke, so their dot grows instead.
        if amount>0 then R.ImGui_DrawList_AddCircleFilled(dl,px,py,(2+5*amount)*scale,colour,16)
        else R.ImGui_DrawList_AddCircle(dl,px,py,3*scale,T.STROKE_PRIMARY,12,scale) end
      else
        R.ImGui_DrawList_AddCircle(dl,px,py,3*scale,T.STROKE_PRIMARY,12,scale)
        if amount>0 then
          local tx,ty=tip(i,amount)
          R.ImGui_DrawList_AddCircleFilled(dl,tx,ty,2.5*scale,colour,12)
        end
      end
      local label=layout.fits and placement.label
      if label then
        R.ImGui_DrawList_AddText(dl,x+label.x,y+label.y,
          value and value.unaddressed and T.TEXT_TERTIARY or T.TEXT_SECONDARY,label.text)
      end
    end

    -- Energy balance, with a ring that grows as the sound spreads.
    local _,bx,by=channels.field(profile,values)
    if bx then
      local spread=outline.spread(bx,by)
      R.ImGui_DrawList_AddCircle(dl,cx+bx*radius,cy+by*radius,5*scale+spread*radius*0.32,
        T.STROKE_PRIMARY,32,scale)
      R.ImGui_DrawList_AddCircleFilled(dl,cx+bx*radius,cy+by*radius,4*scale,T.TEXT_PRIMARY,16)
    end
  end
  R.ImGui_DrawList_PopClipRect(dl)
  if not presentation then
    tips.show(ctx,R.ImGui_IsMouseHoveringRect(ctx,x,y,x+width,y+height),
      hover_tip or (layout.compact and 'Enlarge the view to see speaker labels. Speaker activity continues when the field fits.'
      or state.preview_analysis_profile and
        'Measuring audio on outputs '..table.concat(profile.outputs or {},', ')..'. Speakers keep their project positions.'
        or (hover.has_phase and PHASE_TIP or GENERAL_TIP)),
      hover_tip and 'surround_field_side' or 'surround_field',tips.rect(x,y,width,height))
  end
  R.ImGui_SetCursorScreenPos(ctx,x,y+height)
  return action,hover_tip
end
return field
