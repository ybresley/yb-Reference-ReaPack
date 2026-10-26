local theme=require('ui.theme')
local tips=require('ui.tips')
local scale=require('core.meter_scale')
local warnings=require('core.meter_warnings')
local ramps=require('ui.meter_colours')
local style=require('ui.meter_style')
local drawing=require('ui.meter_drawing')
local T,R=theme.tokens,reaper
local text,line,rect=drawing.text,drawing.line,drawing.rect
local number,loudness_number=drawing.number,drawing.loudness_number
local bars={}
local LOUDNESS_ENTRIES={
  {label='M',key='m',detail='Momentary · 400 ms',maximum='m_max',setting='show_m'},
  {label='S',key='s',detail='Short-term · 3 seconds',maximum='s_max',setting='show_s'},
  {label='I',key='i',detail='Integrated · this playback',setting='show_i'},
}
-- Grid marks and bar geometry share this mapping at every size and scale.
local meter_y = scale.y

local function lr_number(value)
  return (value and value>0 and '+' or '')..number(value)
end

local function lr_number_colour(value)
  if value==nil then return T.TEXT_TERTIARY end
  return value and value>0 and T.DANGER_RED or T.ACCENT
end

local function accent_fill(dl,x,w,top,bottom,y,base)
  if y>=bottom or bottom<=top then return end
  -- Fixed to the scale, so moving peaks cannot stretch or pulse the shading.
  local dark=theme.blend(base&0xFF,base,.68)
  local upper=theme.blend(dark,base,(bottom-y)/(bottom-top))
  R.ImGui_DrawList_AddRectFilledMultiColor(dl,x,y,x+w,bottom,upper,upper,dark,dark)
end

local function lr_layer(dl,opts,x,w,top,bottom,y,colour)
  y=math.max(top,y)
  if opts.lr_shading==false then rect(dl,x,y,w,bottom-y,colour)
  else accent_fill(dl,x,w,top,bottom,y,colour) end
end

local function meter_tooltip(ctx, r, message, id, presentation)
  if presentation then return false end
  local hovered=R.ImGui_IsMouseHoveringRect(ctx,r.x,r.y,r.x+r.w,r.y+r.h)
  tips.show(ctx,hovered,message,id)
  return hovered
end

local function loudness_colour(model,opts,key,value)
  if value==nil then return T.TEXT_TERTIARY end
  if ramps.has(opts.colours) then
    -- Clearing the current warning still acknowledges that above-target episode.
    if value>=opts.target and not warnings.active(model.warnings,key) then return T.ACCENT end
    -- Readouts retain full accent brightness at low levels so they stay legible.
    return ramps.at(opts.colours,math.max(-(opts.yellow_lead or 5),value-opts.target),T.ACCENT,opts)
  end
  if opts.colours=='Solid Accent' then return T.ACCENT end
  if opts.colours=='Thresholds' then
    return warnings.active(model.warnings,key) and T.DANGER_RED or T.ACCENT
  end
  return warnings.active(model.warnings,key) and T.DANGER_RED or T.ACCENT
end

local function lra_bracket(ctx,dl,model,opts,cx,width,top,bottom,compact,presentation)
  local values,moving=model.values or {},model.display or {}
  if not moving.lra_low or not moving.lra_high then return end
  local s=theme.scale
  local x=cx-width/2-(compact and 9 or 12)*s
  local low,high,map=scale.loudness(opts)
  local hi=map(moving.lra_high,bottom,top,low,high)
  local lo=map(moving.lra_low,bottom,top,low,high)
  local gold=drawing.brightness(style.lra,opts.lra_brightness)
  line(dl,x,hi,x,lo,gold,2*s)
  line(dl,x,hi,x+7*s,hi,gold,2*s)
  line(dl,x,lo,x+7*s,lo,gold,2*s)
  -- Open chevrons distinguish a boundary outside the visible scale from a cap.
  if moving.lra_high>high then line(dl,x-3*s,top+4*s,x,top,gold,1.5*s) end
  if moving.lra_low<low then line(dl,x-3*s,bottom-4*s,x,bottom,gold,1.5*s) end
  local label_w=(compact and 32 or 34)*s
  local cy=math.max(top+16*s,math.min(bottom-16*s,(hi+lo)/2))
  text(ctx,dl,x-5*s,cy-15*s,'LRA',gold,(compact and 11 or 12)*s,'right',label_w)
  text(ctx,dl,x-5*s,cy+1*s,number(values.lra),gold,(compact and 12 or 14)*s,'right',label_w)
  return meter_tooltip(ctx,{x=x-label_w-6*s,y=top,w=label_w+14*s,h=bottom-top},
    'Loudness range\nLow: '..loudness_number(values.lra_low,opts)..' '..scale.unit(opts)
    ..'\nHigh: '..loudness_number(values.lra_high,opts)..' '..scale.unit(opts),'lra_bracket',presentation)
end

local function meter_click(ctx, x, top, width, bottom, id, presentation)
  if presentation then return nil end
  local old_x,old_y=R.ImGui_GetCursorScreenPos(ctx)
  R.ImGui_SetCursorScreenPos(ctx,x,top)
  local clicked=R.ImGui_InvisibleButton(ctx,'##clear_warnings_'..id,width,bottom-top)
  R.ImGui_SetCursorScreenPos(ctx,old_x,old_y)
  return clicked and {type='meter_clear_warnings'} or nil
end

local function loudness_columns(width,s)
  local available=width-43*s
  -- A permanent gap keeps the LRA label readable before and after it appears.
  local regular_col=available/3
  local regular_gap=regular_col-math.min(32*s,regular_col*.45)
  local compact=width<240*s
  local reserve=math.max(0,(compact and 54 or 58)*s-regular_gap)*1.5
  local col=(available-reserve)/3
  return col,reserve,compact
end

function bars.readout_size(opts)
  return 20*theme.scale
end

function bars.loudness(ctx,dl,r,model,opts,readout_size,presentation)
  local s=theme.scale
  local side=r.axis_side or 'left'
  local plot_left,plot_right=drawing.meter_bounds(r,side)
  local left=plot_left+(side=='left' and not r.compact and 3 or 0)*s
  local col,reserve,compact=loudness_columns(r.w,s)
  local visible=0
  for _,entry in ipairs(LOUDNESS_ENTRIES) do
    if opts[entry.setting]~=false then visible=visible+1 end
  end
  local separate_lra=not r.compact and opts.show_lra~=false and opts.show_i==false
  if separate_lra then visible=visible+1 end
  local legacy_spacing=not r.compact and visible==3 and not separate_lra
  if not legacy_spacing and visible>0 then
    col=(r.compact and plot_right-plot_left or r.w-43*s)/visible
    reserve=0
  end
  readout_size=readout_size or bars.readout_size()
  local width=math.min(32*s,col*.45)
  local pair_cell=r.compact and col or math.max(col*.84,style.readout_spacing*s)
  -- Keep the M/S readout spacing without pushing M against the plot edge.
  local pair_centre=left+math.max(col,pair_cell/2+width/2+5*s)
  local integrated_width=width*1.2
  local integrated_slot=(opts.show_m~=false and 1 or 0)+(opts.show_s~=false and 1 or 0)+1
  local integrated_x=legacy_spacing and left+col*2.5+reserve
    or left+col*(integrated_slot-.5)
  local top,bottom=r.y+style.plot_top*s,drawing.meter_bottom(r)
  local action
  local low,high,map=scale.loudness(opts)
  local vals=model.values or {}
  local moving=model.display or vals
  drawing.loudness_axis(ctx,dl,plot_left,plot_right,top,bottom,opts,side)
  local bracket_hover=not r.compact and opts.show_lra~=false
    and lra_bracket(ctx,dl,model,opts,integrated_x,integrated_width,top,bottom,compact,presentation)
  local slot=0
  for i,e in ipairs(LOUDNESS_ENTRIES) do
    if opts[e.setting]~=false then
    slot=slot+1
    local bar_width=i==3 and integrated_width or width
    local cell=i==3 and col or pair_cell
    local cx=legacy_spacing and (i==3 and integrated_x or pair_centre+(i-1.5)*cell)
      or left+col*(slot-.5)
    local raw,value=vals[e.key],moving[e.key]
    if e.key=='i' and opts.keep_integrated==false and model.playing==false and not model.hold then
      raw,value=nil,nil
    end
    local over=raw and raw>=opts.target
    drawing.meter_readout(ctx,dl,r,cx,e.label,loudness_number(raw,opts),loudness_colour(model,opts,e.key,raw),readout_size)
    if opts.extra_readings and not r.compact and e.maximum then
      local maximum=model[e.maximum]
      text(ctx,dl,cx,r.y,loudness_number(maximum,opts),maximum and T.ACCENT or T.TEXT_TERTIARY,
        12*s,'number',nil,style.plot_top*s)
      meter_tooltip(ctx,{x=cx-cell/2,y=r.y,w=cell,h=style.plot_top*s},
        (e.key=='m' and 'Momentary' or 'Short-term')..' maximum since reset ('..scale.unit(opts)..').',
        'meter_maximum_'..e.key,presentation)
    end
    action=meter_click(ctx,cx-cell/2,top,cell,r.y+r.h,'lufs_'..e.key,presentation) or action
    rect(dl,cx-bar_width/2,top,bar_width,bottom-top,T.FILL_QUATERNARY,2*s)
    if value and value>low then
      local y=map(value,bottom,top,low,high)
      if ramps.has(opts.colours) then
        ramps.paint(R.ImGui_DrawList_AddRectFilledMultiColor,dl,opts.colours,cx-bar_width/2,bar_width,top,bottom,low,high,value,opts.target,1,T.ACCENT,map,opts)
      else
        local base=opts.colours=='Neutral' and T.TEXT_SECONDARY or T.ACCENT
        rect(dl,cx-bar_width/2,y,bar_width,bottom-y,base)
        if opts.colours=='Thresholds' and value>opts.target then
          local target_y=map(opts.target,bottom,top,low,high)
          rect(dl,cx-bar_width/2,y,bar_width,target_y-y,T.DANGER_RED)
        end
        if over and opts.colours=='Thresholds' then
          line(dl,cx-bar_width/2,y,cx+bar_width/2,y,T.DANGER_RED,2*s)
        end
      end
    end
    local held=model.loudness_peak and model.loudness_peak[e.key]
    if e.key~='i' and opts.ms_hold~=0 and held and held>=low and held<=high then
      local hy=map(held,bottom,top,low,high)
      line(dl,cx-bar_width/2-2*s,hy,cx+bar_width/2+2*s,hy,T.TEXT_PRIMARY,2*s)
    end
    if not bracket_hover then meter_tooltip(ctx,{x=cx-cell/2,y=top,w=cell,h=r.y+r.h-top},e.detail
      ..'\nTarget '..number(opts.target)..' LUFS'
      ..'\nClick to clear warnings.','meter_'..e.label,presentation) end
  end
  end
  return action
end

local function true_peak_maximum(ctx,dl,r,model,left,right,presentation)
  if not model.prefs.extra_readings or r.compact then return end
  local s=theme.scale
  local value=model.tp_max
  local colour=value and (warnings.active(model.warnings,'tp') and T.DANGER_RED or T.ACCENT) or T.TEXT_TERTIARY
  text(ctx,dl,(left+right)/2,r.y,lr_number(value),colour,12*s,'number',nil,style.plot_top*s)
  meter_tooltip(ctx,{x=left,y=r.y,w=right-left,h=style.plot_top*s},
    'True-peak maximum since reset (dBTP).',
    'meter_maximum_tp',presentation)
end

local function stereo_bounds(r)
  local s=theme.scale
  local left,right=drawing.meter_bounds(r,r.axis_side or 'right')
  local channel=(right-left)/2
  return left,right,channel,math.min(28*s,channel*.55)
end

function bars.stereo(ctx,dl,r,model,opts,readout_size,presentation)
  local s=theme.scale
  local floor=opts.lr_floor or -48
  local content=opts.lr_contents or 'RMS + Peak'
  local peak_name=opts.peak_measurement or 'True Peak'
  local peak_unit=content=='RMS Only' and 'dBFS'
    or (peak_name=='True Peak' and 'dBTP' or 'dBFS')
  local top,bottom=r.y+style.plot_top*s,drawing.meter_bottom(r)
  local action
  local vals,moving=model.values or {},model.display or model.values or {}
  local channel_left,channel_right,channel_w,bar_w=stereo_bounds(r)
  local side=r.axis_side or 'right'
  local edge=side=='left' and channel_left or channel_right
  local grid=drawing.brightness(T.STROKE_TERTIARY,opts.grid_brightness)
  for _,tick in ipairs(drawing.axis_ticks(ctx,top,bottom,floor,3,10*s)) do
    local y=meter_y(tick,bottom,top,floor,0)
    line(dl,channel_left,y,channel_right,y,grid)
    drawing.axis_label(ctx,dl,edge,y,tostring(tick),side,10*s,
      drawing.brightness(T.TEXT_TERTIARY,opts.grid_brightness),grid)
  end
  for i,ch in ipairs({'l','r'}) do
    local cx=channel_left+channel_w*(i-.5)
    local rms,peak=moving['rms_'..ch],moving['live_peak_'..ch]
    local held=model.peak_hold and model.peak_hold[ch]
    local readout=content=='RMS Only' and vals['rms_'..ch] or vals['peak_'..ch]
    drawing.meter_readout(ctx,dl,r,cx,ch:upper(),lr_number(readout),lr_number_colour(readout),readout_size or bars.readout_size())
    action=meter_click(ctx,cx-channel_w/2,top,channel_w,r.y+r.h,'stereo_'..ch,presentation) or action
    R.ImGui_DrawList_PushClipRect(dl,channel_left,top,channel_right,bottom,true)
    rect(dl,cx-bar_w/2,top,bar_w,bottom-top,T.FILL_QUATERNARY,2*s)
    if peak and content~='RMS Only' then
      local py=meter_y(peak,bottom,top,floor,0)
      local colour=content=='Peak Only' and T.ACCENT or theme.fade(T.ACCENT,.46)
      lr_layer(dl,opts,cx-bar_w/2,bar_w,top,bottom,py,colour)
    end
    if rms and content~='Peak Only' then
      local ry=meter_y(rms,bottom,top,floor,0)
      lr_layer(dl,opts,cx-bar_w/2,bar_w,top,bottom,ry,T.ACCENT)
    end
    local clipped=opts.show_clipping~=false and warnings.active(model.warnings,ch)
    if clipped then
      line(dl,cx-bar_w/2-2*s,top+s,cx+bar_w/2+2*s,top+s,T.DANGER_RED,2*s)
    end
    if opts.lr_hold~=0 and held and held >= floor then
      local hy=math.max(top+s,meter_y(held,bottom,top,floor,0))
      if not clipped or hy>top+2*s then
        line(dl,cx-bar_w/2-2*s,hy,cx+bar_w/2+2*s,hy,T.TEXT_PRIMARY,2*s)
      end
    end
    R.ImGui_DrawList_PopClipRect(dl)
    meter_tooltip(ctx,{x=cx-channel_w/2,y=top,w=channel_w,h=r.y+r.h-top},
      (ch=='l' and 'Left' or 'Right')..' channel · '..peak_unit
      ..'\nRMS: '..number(vals['rms_'..ch])..' dBFS'
      ..'\n'..peak_name..' (400 ms): '..number(vals['peak_'..ch])
      ..' '..(peak_name=='True Peak' and 'dBTP' or 'dBFS')
      ..'\nClick to clear warnings.', 'stereo_'..ch,presentation)
  end
  true_peak_maximum(ctx,dl,r,model,channel_left,channel_right,presentation)
  return action
end

function bars.k_system(ctx,dl,r,model,opts,readout_size,presentation)
  local meter_y=scale.linear_y
  local s=theme.scale
  local offset=tonumber(opts.mode:sub(3)) or 14
  local content=opts.lr_contents or 'RMS + Peak'
  local peak_name=opts.peak_measurement or 'True Peak'
  local peak_unit=peak_name=='True Peak' and 'dBTP' or 'dBFS'
  local left,right,col,width=stereo_bounds(r)
  local side=r.axis_side or 'right'
  local edge=side=='left' and left or right
  local top=r.y+style.plot_top*s
  local bottom=drawing.meter_bottom(r)
  local action
  local low=(opts.lr_floor or -48)+offset
  local grid=drawing.brightness(T.STROKE_TERTIARY,opts.grid_brightness)
  local vals=model.values or {}
  local moving=model.display or vals
  for _,tick in ipairs(drawing.axis_ticks(ctx,top,bottom,low,6,10*s,offset,meter_y,0)) do
    local y=meter_y(tick,bottom,top,low,offset)
    local zero=tick==0
    line(dl,left,y,right,y,zero and drawing.brightness(T.TEXT_TERTIARY,opts.grid_brightness) or grid)
    drawing.axis_label(ctx,dl,edge,y,tick>0 and '+'..tick or tostring(tick),side,10*s,
      zero and T.TEXT_PRIMARY or drawing.brightness(T.TEXT_TERTIARY,opts.grid_brightness),
      zero and drawing.brightness(T.TEXT_TERTIARY,opts.grid_brightness) or grid)
  end
  -- Calibrated RMS reads a full-scale sine as 0 dBFS; crest remains raw peak/RMS.
  for i,ch in ipairs({'l','r'}) do
    local cx=left+col*(i-.5)
    local raw=vals['rms_'..ch]
    local peak=model.peak_hold and model.peak_hold[ch]
    local calibrated=raw and raw+3.01029995664
    local display=calibrated and calibrated+offset
    if content=='Peak Only' then
      display=vals['peak_'..ch] and vals['peak_'..ch]+offset
    end
    -- K-system zero is a reference level; red still starts above full scale.
    local absolute=display and display-offset
    drawing.meter_readout(ctx,dl,r,cx,ch:upper(),lr_number(display),lr_number_colour(absolute),readout_size or bars.readout_size())
    action=meter_click(ctx,cx-col/2,top,col,r.y+r.h,'k_'..ch,presentation) or action
    R.ImGui_DrawList_PushClipRect(dl,left,top,right,bottom,true)
    rect(dl,cx-width/2,top,width,bottom-top,T.FILL_QUATERNARY,2*s)
    if content~='RMS Only' then
      local peak_value=moving['live_peak_'..ch]
      if peak_value then
        local py=meter_y(peak_value+offset,bottom,top,low,offset)
        lr_layer(dl,opts,cx-width/2,width,top,bottom,py,
          content=='Peak Only' and T.ACCENT or theme.fade(T.ACCENT,.46))
      end
    end
    if content~='Peak Only' then
      local rms=moving['rms_'..ch]
      if rms then
        local ry=meter_y(rms+3.01029995664+offset,bottom,top,low,offset)
        lr_layer(dl,opts,cx-width/2,width,top,bottom,ry,T.ACCENT)
      end
    end
    local clipped=opts.show_clipping~=false and warnings.active(model.warnings,ch)
    if clipped then line(dl,cx-width/2-2*s,top+s,cx+width/2+2*s,top+s,T.DANGER_RED,2*s) end
    if opts.lr_hold~=0 and peak and peak+offset >= low then
      local y=math.max(top+s,meter_y(peak+offset,bottom,top,low,offset))
      if not clipped or y>top+2*s then
        line(dl,cx-width/2-2*s,y,cx+width/2+2*s,y,T.TEXT_PRIMARY,2*s)
      end
    end
    R.ImGui_DrawList_PopClipRect(dl)
    meter_tooltip(ctx,{x=cx-col/2,y=top,w=col,h=r.y+r.h-top},
      'RMS · 400 ms · sine calibrated'
      ..'\n0 on '..opts.mode..' = −'..offset..' dBFS (RMS), −'..offset..' '..peak_unit..' ('..peak_name..').'
      ..'\nClick to clear warnings.','k_'..ch,presentation)
  end
  if opts.extra_readings then
    true_peak_maximum(ctx,dl,r,model,left,right,presentation)
  else
    text(ctx,dl,(left+right)/2,r.y,opts.mode,T.TEXT_TERTIARY,11*s,'center',nil,style.plot_top*s)
  end
  return action
end


return bars
