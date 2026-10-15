local theme=require('ui.theme')
local tips=require('ui.tips')
local scale=require('core.meter_scale')
local session=require('core.meter_session')
local display_curve=require('core.meter_history_display')
local time_axis=require('core.meter_history_axis')
local style=require('ui.meter_style')
local history_fill=require('ui.meter_history_fill')
local history_line=require('ui.meter_history_line')
local colour_fill=require('ui.meter_history_colour_fill')
local ramps=require('ui.meter_colours')
local drawing=require('ui.meter_drawing')
local T,R=theme.tokens,reaper
local text,line,rect=drawing.text,drawing.line,drawing.rect
local loudness_number=drawing.loudness_number
local time_label=drawing.time_label
local history={}
local INTEGRATED_COLOUR=0xAF95DFFF
-- Reused by each trace; the native drawing buffer belongs to the meter adapter.
local vertices={}
local function meter_tooltip(ctx,r,message,id)
  tips.show(ctx,R.ImGui_IsMouseHoveringRect(ctx,r.x,r.y,r.x+r.w,r.y+r.h),message,id)
end
local function history_curve(dl,model,key,start,finish,x,y,left,right,colour,thickness,fill_geometry,colour_geometry)
  local points=model.history_points
  local halo=display_curve.radius(right-left)*(finish-start)/math.max(1,right-left)
  local used,last_t,last_value=0,nil,nil
  local function flush()
    if points and used>1 then
      local drawn=display_curve.reduce(vertices,used,points,left,right,x(0))
      if drawn>1 and fill_geometry then
        local r=fill_geometry
        history_fill.paint(R.ImGui_DrawList_AddConcavePolyFilled,dl,points,drawn,
          model.history_fill_points,(session.HISTORY_LIMIT+2)*2,
          r.left,r.right,r.top,r.bottom,r.colour or T.SPECTRUM_AVERAGE_FILL,
          R.ImGui_DrawList_PushClipRect,R.ImGui_DrawList_PopClipRect,r.paint_polygon)
      elseif drawn>1 then
        points.resize(drawn*2)
        if colour_geometry then
          history_line.paint(R,dl,points,drawn,colour_geometry,model.history_fill_points)
        else
          history_line.stroke(R,dl,points,drawn,model.history_fill_points,colour,thickness)
        end
        model.history_fill_points.resize((session.HISTORY_LIMIT+2)*2)
        points.resize(session.HISTORY_LIMIT*2)
      end
    end
    used=0
  end
  local function add(t,value)
    if not value or value<=-99 then flush(); last_t=nil; return end
    if last_t and t-last_t>=.3 then flush(); last_t=nil end
    if last_t and t==last_t then return end
    if last_t and not points and not fill_geometry then line(dl,x(last_t),y(last_value),x(t),y(value),colour,thickness) end
    if points then
      used=used+1
      vertices[used*2-1],vertices[used*2]=x(t),y(value)
    end
    last_t,last_value=t,value
  end
  for i=1,model.history_count do
    local point=session.history_at(model,i)
    local next_point=session.history_at(model,i+1)
    -- Supply neighbouring measurements for the filter window at each plot edge.
    if (point.t<=finish+halo or (i>1 and session.history_at(model,i-1).t<finish+halo))
      and (point.t>=start-halo or (next_point and next_point.t>=start-halo)) then
      add(point.t,point[key])
    end
  end
  flush()
end

function history.draw(ctx,dl,r,model,opts,guide)
  local s=theme.scale
  local l=r.x+(r.plot_left or style.history_left)*s
  local right=r.x+r.w-style.history_right*s
  local top=r.y+style.plot_top*s
  local footer_height=r.footer_height or theme.metrics.RULER_H
  local background_bottom=r.y+r.h-footer_height
  local ruler_height=footer_height>0 and (r.inset_time and style.caption_height*s or footer_height) or 0
  local bottom=r.inset_time and ruler_height>0 and drawing.meter_bottom(r) or background_bottom
  local low,high,map=scale.loudness(opts)
  drawing.surface(dl,{x=l,y=r.y,w=right-l,h=background_bottom-r.y})
  local show_m=opts.history_m~=false
  local show_s=opts.history_s~=false
  local show_i=opts.history_integrated==true and (model.playing~=false or opts.keep_integrated~=false or model.hold)
  if opts.history_legend~=false then
    local count=(show_m and 1 or 0)+(show_s and 1 or 0)+(show_i and 1 or 0)
    local font=theme.push_release_font(ctx,11*s)
    local label_width=(show_m and R.ImGui_CalcTextSize(ctx,'M') or 0)
      +(show_s and R.ImGui_CalcTextSize(ctx,'S') or 0)
      +(show_i and R.ImGui_CalcTextSize(ctx,'I') or 0)
    local width=count*15*s+label_width+math.max(0,count-1)*12*s
    local x=(l+right-width)/2
    local legend_y=r.y+style.plot_top*s/2
    local function sample(label,colour)
      line(dl,x,legend_y,x+11*s,legend_y,colour,2*s)
      text(ctx,dl,x+15*s,r.y,label,T.TEXT_TERTIARY,nil,nil,nil,style.plot_top*s)
      x=x+27*s+R.ImGui_CalcTextSize(ctx,label)
    end
    if show_m then sample('M',T.TEXT_PRIMARY) end
    if show_s then sample('S',T.ACCENT) end
    if show_i then sample('I',INTEGRATED_COLOUR) end
    if font then R.ImGui_PopFont(ctx) end
  end
  local y=function(v) return map(v,bottom,top,low,high,true) end
  local elapsed=model.view_elapsed or model.elapsed
  local start=math.max(0,elapsed-opts.seconds)
  local duration=opts.seconds
  local x=function(t) return l+(t-start)/duration*(right-l) end
  -- Whole-pixel widths stay eligible for the renderer's textured antialiasing path.
  local stroke_width=math.max(1,math.floor(style.history_stroke*s+.5))
  local colour_geometry=opts.history_colours~=false and ramps.has(opts.colours) and {
    left=l,right=right,top=top,bottom=bottom,low=low,high=high,map=map,
    target=opts.target,palette=opts.colours,accent=T.ACCENT,thickness=stroke_width,
    opacity=math.floor(255*(opts.history_opacity or .22)+.5),
    yellow_lead=opts.yellow_lead,red_span=opts.red_span,
  } or nil
  local fill_geometry={left=l,right=right,top=top,bottom=bottom}
  if colour_geometry then
    fill_geometry.paint_polygon=function(draw_list,points,left,right,highest,lowest)
      colour_fill.paint(R,draw_list,points,left,right,highest,lowest,colour_geometry)
    end
  end
  local fill_key=opts.history_fill=='Momentary' and show_m and 'm'
    or opts.history_fill=='Short-Term' and show_s and 's'
    or opts.history_fill=='Integrated' and show_i and 'i'
  if fill_key and (opts.history_opacity or .22)>0 then
      local fill_colour=fill_key=='m' and T.TEXT_PRIMARY
        or fill_key=='i' and INTEGRATED_COLOUR or T.SPECTRUM_AVERAGE_FILL
      fill_geometry.colour=(fill_colour&0xFFFFFF00)
        | math.floor(255*(opts.history_opacity or .22)+.5)
      if fill_key~='s' then fill_geometry.paint_polygon=nil end
      R.ImGui_DrawList_PushClipRect(dl,l,top,right,bottom,true)
      history_curve(dl,model,fill_key,start,start+duration,x,y,l,right,nil,nil,fill_geometry)
      R.ImGui_DrawList_PopClipRect(dl)
  end
  drawing.loudness_axis(ctx,dl,l,right,top,bottom,opts,'right')
  if ruler_height>0 then
    local time_y=bottom
    R.ImGui_DrawList_PushClipRect(dl,l,bottom,right,time_y+ruler_height,true)
    local axis_font=theme.push_release_font(ctx,11*s)
    -- Keep every two-second tick; long windows omit labels that cannot fit.
    local function axis_time(t) return string.format('%d:%02d',t//60,t%60) end
    local label_width=R.ImGui_CalcTextSize(ctx,axis_time(math.floor(start+duration)))
    local label_stride=math.max(1,math.ceil((label_width+4*s)/(2/duration*(right-l))))
    time_axis.each(start,duration,right-l,function(t,offset)
      line(dl,l+offset,bottom,l+offset,bottom+theme.metrics.RULER_TICK_MINOR,
        drawing.brightness(T.STROKE_TERTIARY,opts.grid_brightness))
      if t%(2*label_stride)~=0 then return end
      local label=axis_time(t)
      local half=R.ImGui_CalcTextSize(ctx,label)/2
      local margin=math.min(offset-half,right-l-offset-half)
      if margin>0 then
        text(ctx,dl,l+offset,time_y,label,
          theme.fade(T.TEXT_TERTIARY,math.min(1,margin/(8*s))),nil,'center',nil,ruler_height)
      end
    end)
    if axis_font then R.ImGui_PopFont(ctx) end
    R.ImGui_DrawList_PopClipRect(dl)
  end
  R.ImGui_DrawList_PushClipRect(dl,l,top,right,bottom,true)
  if show_m then history_curve(dl,model,'m',start,start+duration,x,y,l,right,T.TEXT_PRIMARY,stroke_width) end
  if show_s then history_curve(dl,model,'s',start,start+duration,x,y,l,right,T.ACCENT,stroke_width,nil,colour_geometry) end
  if show_i then
    history_curve(dl,model,'i',start,start+duration,x,y,l,right,INTEGRATED_COLOUR,stroke_width)
  end
  local nearest,distance
  -- The release guide supplies a paint-only pointer; ordinary meters still use
  -- the real OS mouse and the same measured-point inspection path.
  local mx,my
  local hover
  if guide then
    mx,my=guide.x,guide.y
    hover=guide.inspect and mx>=l and mx<=right and my>=top and my<=bottom
  else
    mx,my=R.ImGui_GetMousePos(ctx)
    hover=R.ImGui_IsMouseHoveringRect(ctx,l,top,right,bottom)
  end
  for i=1,hover and model.history_count or 0 do
    local point=session.history_at(model,i)
    if point and point.t>=start and point.t<=start+duration then
      local px=x(point.t)
      if hover and (not distance or math.abs(px-mx)<distance) then nearest,distance=point,math.abs(px-mx) end
    end
  end
  R.ImGui_DrawList_PopClipRect(dl)
  if nearest then
    local px=x(nearest.t)
    line(dl,px,top,px,bottom,T.STROKE_PRIMARY)
    local label=time_label(nearest.t,opts)
      ..(show_m and '   M '..loudness_number(nearest.m,opts) or '')
      ..(show_s and '   S '..loudness_number(nearest.s,opts) or '')
      ..(show_i and '   I '..loudness_number(nearest.i,opts) or '')
      ..' '..scale.unit(opts)
    local labelw=math.min(right-l,R.ImGui_CalcTextSize(ctx,label)+12*s)
    local bx=math.max(l,math.min(right-labelw,px+8*s))
    rect(dl,bx,top+5*s,labelw,24*s,T.BG_POPUP,4*s)
    text(ctx,dl,bx+6*s,top+10*s,label,T.TEXT_PRIMARY,12*s,nil,labelw-12*s)
  end
  if not nearest and not guide then
    local detail='L/R loudness history. Hover to inspect readings.'
    if opts.show_target==true then detail=detail..' Dotted line: target.' end
    meter_tooltip(ctx,r,detail,'history')
  end
end


return history
