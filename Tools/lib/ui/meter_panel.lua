-- The panel draws session state and returns intent; the adapter owns all audio.
local theme=require('ui.theme')
local tips=require('ui.tips')
local widgets=require('ui.widgets')
local readings=require('core.meter_readings')
local layout=require('core.meter_layout')
local status_text=require('core.meter_status')
local bars=require('ui.meter_bars')
local history=require('ui.meter_history')
local controls=require('ui.meter_controls')
local drawing=require('ui.meter_drawing')
local style=require('ui.meter_style')
local numeric=require('ui.meter_numeric')
local swaps=require('ui.divider_swaps')
local panel={}
local T,R,M=theme.tokens,reaper,theme.metrics

local READING_KEYS={'crest','rms','target'}
local READING_LABELS={crest='Crest Factor',rms='RMS',target='Target Diff'}
local READING_UNITS={crest='dB',rms='dBFS',target='LU'}
local READING_TIPS={
  crest='Sample peak above average RMS since reset.',
  rms='Stereo average level over 400 ms.',
}
local MEASUREMENTS={{'I','Integrated'},{'M','Momentary'},{'S','Short-Term'}}
local GROUP_NAMES={loudness='Loudness',lr='L/R',readings='Readings',history='History'}
local PASSIVE={}

local function reading_metrics(ctx)
  local s=theme.scale
  local function height(size,sample)
    if not ctx then return size*s end
    local pushed=theme.push_release_font(ctx,size*s)
    local _,h=R.ImGui_CalcTextSize(ctx,sample)
    if pushed then R.ImGui_PopFont(ctx) end
    return h
  end
  local label=height(style.readings_label_size,'Crest Factor')
  local value=height(style.readings_value_size,'−88.8')
  local unit=height(style.readings_unit_size,'dBFS')
  return {label=label,value=value,unit=unit,
    block=label+style.readings_label_gap*s+math.max(value,unit),
    gap=style.readings_row_gap*s}
end

local function readings_geometry(ctx,r,embedded)
  local s,pad=theme.scale,M.WINDOW_PAD
  local available=r.h-(r.footer_height or M.RULER_H)
  local top=r.y+style.plot_top*s
  local metrics=reading_metrics(ctx)
  local needed=#READING_KEYS*metrics.block+(#READING_KEYS-1)*metrics.gap
  local height
  if embedded then
    local span=drawing.meter_bottom(r)-top
    if span<needed then return end
    top=top+(span-needed)/2
    height=available
  else
    height=style.plot_top*s+pad*2+needed
    if height>available then return end
    top=top+pad
  end
  return {top=top,height=height,row=metrics.block+metrics.gap,metrics=metrics}
end

local function readings_column(ctx,dl,r,model,placement,embedded,presentation)
  local keys=READING_KEYS
  local s=theme.scale
  local metrics=placement.metrics
  if not embedded then
    drawing.surface(dl,{x=r.x,y=r.y,w=r.w,h=placement.height})
  end
  local centre=r.x+(r.w-20*s)/2
  local values=model.values or {}
  local measurement=model.prefs.target_difference_measurement or 'Integrated'
  local selected=1
  for index,choice in ipairs(MEASUREMENTS) do
    if choice[2]==measurement then selected=index; break end
  end
  local old_x,old_y=R.ImGui_GetCursorScreenPos(ctx)
  local action
  R.ImGui_DrawList_PushClipRect(dl,r.x,r.y,r.x+r.w,r.y+placement.height,true)
  for i,key in ipairs(keys) do
    local y=placement.top+(i-1)*placement.row
    local raw
    if key=='crest' then raw=values.crest
    elseif key=='rms' then raw=readings.rms(values)
    else raw=readings.target_difference(model) end
    local value=drawing.number(raw)
    if key=='target' and raw and raw>=.05 then value='+'..value end
    local colour=T.ACCENT
    if value=='—' then colour=T.TEXT_TERTIARY end
    local font=theme.push_release_font(ctx,style.readings_value_size*s)
    local body=value:gsub('^−',''):gsub('^%+','')
    local body_width=R.ImGui_CalcTextSize(ctx,body)
    if font then R.ImGui_PopFont(ctx) end
    local label=READING_LABELS[key]
    local label_width=r.w-20*s
    if key=='target' then
      local suffix=' ('..MEASUREMENTS[selected][1]..')'
      local label_font=theme.push_release_font(ctx,style.readings_label_size*s)
      -- Keep the selected measurement visible even in a manually narrowed column.
      label=widgets.ellipsize(ctx,label,math.max(0,label_width-R.ImGui_CalcTextSize(ctx,suffix)))..suffix
      if label_font then R.ImGui_PopFont(ctx) end
    end
    if key=='target' and not presentation then
      R.ImGui_SetCursorScreenPos(ctx,centre-label_width/2,y)
      local next_measurement=MEASUREMENTS[selected%#MEASUREMENTS+1][2]
      if widgets.text_button(ctx,'##target_difference',label,label_width,metrics.label,style.readings_label_size*s,
          'Click to switch to '..next_measurement..'.') then
        action={type='meter_set_preference',key='target_difference_measurement',value=next_measurement}
      end
    else
      drawing.text(ctx,dl,centre,y,label,T.TEXT_SECONDARY,style.readings_label_size*s,'center',label_width)
    end
    local value_y=y+metrics.label+style.readings_label_gap*s
    drawing.text(ctx,dl,centre,value_y,value,colour,style.readings_value_size*s,'number')
    drawing.text(ctx,dl,centre+body_width/2+5*s,value_y+(metrics.value-metrics.unit)/2,
      READING_UNITS[key],T.TEXT_TERTIARY,style.readings_unit_size*s)
    if not presentation then
      local tip=READING_TIPS[key] or measurement..' above (+) or below (−) target.'
      tips.show(ctx,R.ImGui_IsMouseHoveringRect(ctx,r.x,y,r.x+r.w,y+metrics.block),
        tip,'meter_reading_'..key)
    end
  end
  R.ImGui_DrawList_PopClipRect(dl)
  R.ImGui_SetCursorScreenPos(ctx,old_x,old_y)
  return action
end

local function set_footer_height(geometry,footer_height)
  if footer_height==nil then return geometry end
  geometry.footer_height=footer_height
  for _,key in ipairs({'loudness','lr','readings','history'}) do
    if geometry[key] then geometry[key].footer_height=footer_height end
  end
  return geometry
end

local function minimum_height(footer_height)
  if footer_height~=nil then
    return (style.plot_top+style.caption_height+1)*theme.scale+footer_height
  end
  return 88*theme.scale
end

function panel.measure(width,height,opts,top_row_height,splits,footer_height,ctx)
  local count=#READING_KEYS
  local metrics=reading_metrics(ctx)
  local reading_min=style.plot_top+style.caption_height
    +(count*metrics.block+(count-1)*metrics.gap)/theme.scale
  local options={scale=theme.scale,
    show_meters=opts.show_meters,show_loudness=opts.show_loudness,
    show_lr=opts.show_lr,show_history=opts.show_history,
    history_position=opts.history_position,
    show_readings=opts.extra_readings==true,
    readings_width=M.METER_READINGS_W/theme.scale,
    readings_min_height=reading_min+(footer_height or M.RULER_H)/theme.scale,
    top_row_height=top_row_height,splits=splits}
  local geometry=layout.calculate(width,height,options)
  local loudness_enabled,lr_enabled=geometry.loudness~=nil,geometry.lr~=nil
  local meters=loudness_enabled or lr_enabled
  local both=loudness_enabled and lr_enabled
  local normal_width=both and 312 or (loudness_enabled and 210 or 130)
  local first=geometry.loudness or geometry.lr
  if first and geometry.history and (width<normal_width*theme.scale
      or first.h<style.compact_history_height*theme.scale) then
    options.show_history=false
    geometry=layout.calculate(width,height,options)
    geometry.history_hidden=opts.show_history~=false
  end
  local minimum=not meters and 160 or both and style.compact_min_width
    or loudness_enabled and style.compact_loudness_width or style.compact_lr_width
  if width<minimum*theme.scale or height<style.compact_min_height*theme.scale then
    return {numeric=true,w=width,h=height,seams={},footer_height=footer_height,
      history_hidden=opts.show_history~=false,readings_hidden=opts.extra_readings==true}
  end
  if meters and width<normal_width*theme.scale then
    options.compact_meters=true
    geometry=layout.calculate(width,height,options)
    geometry.history_hidden=opts.show_history~=false or nil
    geometry.readout_size=(width>=300*theme.scale and 18
      or width>=280*theme.scale and 16 or 14)*theme.scale
    for _,key in ipairs({'loudness','lr'}) do
      if geometry[key] then geometry[key].compact=true end
    end
  end
  local loudness,lr=geometry.loudness,geometry.lr
  local reversed=loudness and lr and lr.x<loudness.x
    and math.min(lr.y+lr.h,loudness.y+loudness.h)>math.max(lr.y,loudness.y)
  if loudness then loudness.axis_side=reversed and 'right' or 'left' end
  if lr then lr.axis_side=reversed and 'left' or 'right' end
  if geometry.history and geometry.history.y>0 then
    geometry.history.plot_left=geometry.loudness and 32 or 8
  end
  return set_footer_height(geometry,footer_height)
end

-- Match the first grey meter surface, including whichever group was swapped left.
function panel.surface_left_inset(geometry,width,height,prefs)
  if geometry.numeric then return 0 end
  if width and height and prefs then
    local visible=prefs.show_meters~=false
    local minimum=not visible and 160
      or prefs.show_loudness and prefs.show_lr and 312 or 260
    if width<minimum*theme.scale or height<minimum_height(geometry.footer_height) then return 0 end
  end
  local left
  for _, key in ipairs({'loudness','lr','readings','history'}) do
    local r=geometry[key]
    if r and r.y==0 and r.h>=minimum_height(r.footer_height) then
      local x
      if key=='loudness' or key=='lr' then
        x=drawing.meter_bounds(r,r.axis_side or (key=='loudness' and 'left' or 'right'))
      elseif key=='history' then
        x=r.x+(r.plot_left or style.history_left)*theme.scale
      else
        x=r.x+8*theme.scale
      end
      left=left and math.min(left,x) or x
    end
  end
  return left or 0
end

local seam_drag

local function split_state(state)
  local key=state.layout_prototype and state.layout_prototype.active or 'default'
  return state.layout_meter_splits and state.layout_meter_splits[key]
end

local function seam_input(ctx,geometry,x,y,width,height,variant,swap_blocked)
  if swap_blocked then
    if not R.ImGui_IsMouseDown(ctx,0) then seam_drag=nil end
    return nil,{},true
  end
  local action,faces,blocked
  faces={}
  local mx,my=R.ImGui_GetMousePos(ctx)
  local seen={}
  if seam_drag and seam_drag.variant~=variant then seam_drag=nil end
  R.ImGui_PushID(ctx,variant)
  for _,seam in ipairs(geometry.seams or {}) do
    seen[seam.key]=true
    R.ImGui_SetCursorScreenPos(ctx,x+seam.x,y+seam.y)
    R.ImGui_InvisibleButton(ctx,'##meter_split_'..seam.key,
      math.max(1,seam.w),math.max(1,seam.h))
    local hot,held=R.ImGui_IsItemHovered(ctx),R.ImGui_IsItemActive(ctx)
    blocked=blocked or hot or held
    faces[#faces+1]={seam=seam,hot=hot,held=held}
    if R.ImGui_IsItemActivated(ctx) then
      local boundary=seam.axis=='x' and seam.x+seam.value_offset or seam.y+seam.value_offset
      seam_drag={variant=variant,key=seam.key,axis=seam.axis,
        offset=seam.axis=='x' and mx-x-boundary or my-y-boundary}
    end
    if hot or held then
      R.ImGui_SetMouseCursor(ctx,seam.axis=='x'
        and R.ImGui_MouseCursor_ResizeEW() or R.ImGui_MouseCursor_ResizeNS())
    end
    if held and seam_drag and seam_drag.key==seam.key then
      local pointer=seam.axis=='x' and mx-x or my-y
      local span=seam.axis=='x' and width or height
      action={type='meter_panel_split',key=seam.key,
        value=math.max(0,math.min(1,(pointer-seam_drag.offset)/math.max(1,span)))}
    end
    tips.show(ctx,hot,'Drag to resize panels.','meter_split_'..seam.key)
  end
  if seam_drag and (not seen[seam_drag.key] or not R.ImGui_IsMouseDown(ctx,0)) then
    seam_drag=nil
  end
  R.ImGui_PopID(ctx)
  return action,faces,blocked
end

local function paint_seams(ctx,faces,x,y)
  local dl=R.ImGui_GetWindowDrawList(ctx)
  local alpha=R.ImGui_GetStyleVar(ctx,R.ImGui_StyleVar_Alpha())
  for _,face in ipairs(faces) do
    if face.hot or face.held then
      local seam=face.seam
      R.ImGui_DrawList_AddRectFilled(dl,x+seam.x,y+seam.y,
        x+seam.x+seam.w,y+seam.y+seam.h,
        theme.fade(face.held and T.FILL_PRIMARY or T.FILL_SECONDARY,alpha))
    end
  end
end

function panel.paint(ctx,model,geometry,x,y,presentation)
  local dl=R.ImGui_GetWindowDrawList(ctx)
  if geometry.numeric then
    local footer=geometry.footer_height or theme.metrics.RULER_H
    return numeric.draw(ctx,dl,{x=x,y=y,w=geometry.w,
      h=math.max(0,geometry.h-footer),
      corner_size=footer==0 and R.ImGui_GetFrameHeight(ctx)+4*theme.scale or 0,
      surface_painted=geometry.surface_painted},model,presentation)
  end
  local readout_size=geometry.readout_size or bars.readout_size(model.prefs)
  local function translated(r)
    return r and {x=x+r.x,y=y+r.y,w=r.w,h=r.h,controls=r.controls,
      plot_left=r.plot_left,axis_side=r.axis_side,footer_height=r.footer_height,
      compact=r.compact,surface_painted=geometry.surface_painted}
  end
  local first=translated(geometry.loudness or geometry.lr)
  local readings_frame=geometry.readings and translated(geometry.readings)
  local readings_placement
  if readings_frame and model.prefs.extra_readings then
    readings_placement=readings_geometry(ctx,readings_frame,first~=nil)
  end
  if not readings_placement then readings_frame=nil end
  local rightmost
  for _,key in ipairs({'loudness','lr','readings'}) do
    local r=geometry[key]
    if r and r.y==0 and (not rightmost or r.x+r.w>rightmost.x+rightmost.w) then
      rightmost=r
    end
  end
  local last=translated(rightmost)
  -- Join neighbouring groups by their current geometry, independent of swap history.
  local backgrounds={}
  for _,key in ipairs({'loudness','lr','readings'}) do
    local r=translated(geometry[key])
    if key=='readings' and not readings_frame then r=nil end
    if r and (key~='readings' or first) and r.h>=minimum_height(r.footer_height) then
      local left,right
      if key=='readings' then left,right=r.x+8*theme.scale,r.x+r.w
      else left,right=drawing.meter_bounds(r,r.axis_side or (key=='loudness' and 'left' or 'right')) end
      backgrounds[#backgrounds+1]={x=left,y=r.y,w=right-left,
        h=r.h-(r.footer_height or theme.metrics.RULER_H),
        panel_left=r.x,panel_right=r.x+r.w}
    end
  end
  table.sort(backgrounds,function(a,b) return a.y==b.y and a.x<b.x or a.y<b.y end)
  local shared
  for _,r in ipairs(backgrounds) do
    if shared and math.abs(r.y-shared.y)<.01 and math.abs(r.h-shared.h)<.01
      and r.panel_left>=shared.panel_right-.01
      and r.panel_left-shared.panel_right<=8*theme.scale+.01 then
      shared.w=r.x+r.w-shared.x
      shared.panel_right=r.panel_right
    else
      if shared and not geometry.surface_painted then drawing.surface(dl,shared) end
      shared=r
    end
  end
  if shared and not geometry.surface_painted then drawing.surface(dl,shared) end
  local action
  if geometry.surface_painted then
    for _,seam in ipairs(geometry.seams or {}) do
      if seam.axis=='y' or seam.key=='history_x' then
        local footer=seam.axis=='y' and (geometry.footer_height or theme.metrics.RULER_H) or 0
        drawing.rect(dl,x+seam.x,y+seam.y-footer,seam.w,seam.h+footer,T.BG_WINDOW)
      end
    end
  end
  for _,key in ipairs({'loudness','lr','history'}) do
    local r=translated(geometry[key])
    if r and r.w>0 and r.h>0 then
      R.ImGui_DrawList_PushClipRect(dl,r.x,r.y,r.x+r.w,r.y+r.h,true)
      if key=='history' then
        r.inset_time=first and last and r.y==first.y and r.x>=last.x+last.w
        if r.h>=minimum_height(r.footer_height) then
          history.draw(ctx,dl,r,model,model.prefs,presentation)
        end
      elseif r.h>=minimum_height(r.footer_height) then
        local draw=key=='loudness' and bars.loudness or (model.prefs.mode=='LUFS' and bars.stereo or bars.k_system)
        action=draw(ctx,dl,r,model,model.prefs,readout_size,presentation) or action
      end
      R.ImGui_DrawList_PopClipRect(dl)
    end
  end
  if readings_frame then
    action=readings_column(ctx,dl,readings_frame,model,readings_placement,first~=nil,presentation) or action
  end
  return action
end

function panel.draw(ctx,state,res,x,y,width,height,geometry,footer_height)
  local model=state.metering
  if not model or not model.prefs or width<=0 or height<=0 then return end
  local s=theme.scale
  local dl=R.ImGui_GetWindowDrawList(ctx)
  local effective_footer=footer_height or geometry and geometry.footer_height
  local ruler=effective_footer or theme.metrics.RULER_H
  local old_x,old_y=R.ImGui_GetCursorScreenPos(ctx)
  R.ImGui_PushID(ctx,'output_meter')
  local opts=model.prefs
  geometry=set_footer_height(geometry or panel.measure(width,height,opts,nil,split_state(state),footer_height,ctx),footer_height)
  -- Only the top-right group shares its heading with the permanent menu button.
  for _,key in ipairs({'loudness','lr','history'}) do
    local r=geometry[key]
    if r and r.y==0 and r.x+r.w>=width-1 then r.controls=true end
  end
  local initializing=model.error=='initializing'
  local reconnect=not initializing and (model.error or not model.attached)
  local error=model.preference_error or (model.error and status_text.error(model.error))
    or (not model.attached and 'Meter unavailable')
  if error and (width<120*s or height<62*s) then
    if not geometry.surface_painted then
      drawing.surface(dl,{x=x,y=y,w=width,h=math.max(0,height-ruler)})
    end
    drawing.text(ctx,dl,x+4*s,y+4*s,error,initializing and T.TEXT_SECONDARY or T.DANGER_RED,
      11*s,nil,math.max(0,width-8*s))
    tips.show(ctx,R.ImGui_IsMouseHoveringRect(ctx,x,y,x+width,y+height),error,'meter_error')
    if width>=32*s and height>=25*s then
      controls.draw(ctx,model,x+8*s,y+2*s,width-8*s,res,geometry.history_hidden,
        {x=x,y=y,w=width,h=height},geometry.readings_hidden)
    end
    R.ImGui_PopID(ctx)
    R.ImGui_SetCursorScreenPos(ctx,old_x,old_y)
    return nil,x,y,x+width,y+height-ruler
  end
  local error_top,error_height,error_text_height
  if error then
    local font=theme.push_release_font(ctx,11*s)
    local _,text_height=R.ImGui_CalcTextSize(ctx,error,nil,nil,false,width-32*s)
    if font then R.ImGui_PopFont(ctx) end
    -- Grow upward from the existing action row so Reconnect stays under the pointer.
    local bottom=y+math.min(height-2*s,math.max(86*s,(height+62*s)/2))
    error_height=math.min(math.max(62*s,text_height+46*s),bottom-y-2*s)
    error_top=bottom-error_height
    error_text_height=math.max(1,error_height-46*s)
  end
  local error_hover=error and R.ImGui_IsMouseHoveringRect(ctx,
    x+8*s,error_top,x+width-8*s,error_top+error_height)
  local variant=state.layout_prototype and state.layout_prototype.active or 'default'
  local panels={}
  for _,key in ipairs({'loudness','lr','readings','history'}) do
    local r=geometry[key]
    if r then panels[#panels+1]={id=key,x=r.x,y=r.y,w=r.w,h=r.h} end
  end
  -- Disabled widgets still own hover, so omit inputs covered by the warning.
  local swap_pair,swap_input
  if error_hover then
    swap_input={faces={},blocked=false,highlights={}}
  else
    swap_pair,swap_input=swaps.input(ctx,'meter_'..variant,panels,
      geometry.seams or {},x,y,GROUP_NAMES)
  end
  local split_action,faces,split_blocked=seam_input(ctx,geometry,x,y,width,height,
    variant,swap_input.blocked or error_hover)
  if error then R.ImGui_BeginDisabled(ctx) end
  if split_blocked then
    R.ImGui_PushStyleVar(ctx,R.ImGui_StyleVar_DisabledAlpha(),1)
    R.ImGui_BeginDisabled(ctx)
  end
  local passive=(error or split_blocked) and PASSIVE or nil
  local action=panel.paint(ctx,model,geometry,x,y,passive)
  if split_blocked then
    R.ImGui_EndDisabled(ctx)
    R.ImGui_PopStyleVar(ctx)
  end
  if error then R.ImGui_EndDisabled(ctx) end
  paint_seams(ctx,faces,x,y)
  action=split_action or action
  local history_corner=geometry.history and geometry.history.y==0
    and geometry.history.x+geometry.history.w>=width-1
  local menu_inset=history_corner and (style.history_right+4)*s or 0
  -- A shared ruler is unused by numeric tiles and keeps the hover control clear
  -- of their first row. Without a ruler, use the outer corner rather than a strip.
  local menu_y=geometry.numeric and ruler>0 and y+height-ruler or y+2*s
  local menu_padding=geometry.numeric and 8*s or 16*s
  local menu_action=controls.draw(ctx,model,x+8*s,menu_y,width-menu_padding-menu_inset,res,
    geometry.history_hidden,{x=x,y=y,w=width,h=height},geometry.readings_hidden)
  action=menu_action or action
  swaps.paint(ctx,swap_input)
  if error then
    -- A fault stays visible without reserving a status row or moving the plots.
    local top=error_top
    drawing.rect(dl,x+8*s,top,width-16*s,error_height,T.BG_POPUP,4*s)
    R.ImGui_SetCursorScreenPos(ctx,x+16*s,top+8*s)
    local font=theme.push_release_font(ctx,11*s)
    -- The complete recovery message wraps, and can scroll when the view is short.
    if R.ImGui_BeginChild(ctx,'meter_error_message',width-32*s,error_text_height) then
      R.ImGui_PushTextWrapPos(ctx,0)
      R.ImGui_TextColored(ctx,initializing and T.TEXT_SECONDARY or T.DANGER_RED,error)
      R.ImGui_PopTextWrapPos(ctx)
      R.ImGui_EndChild(ctx)
    end
    if font then R.ImGui_PopFont(ctx) end
    tips.show(ctx,error_hover,error,'meter_error')
    if reconnect then
      R.ImGui_SetCursorScreenPos(ctx,x+width-100*s,top+error_height-30*s)
      if R.ImGui_Button(ctx,'Reconnect',84*s,22*s) then action={type='meter_reconnect'} end
    end
  end
  if swap_pair then
    action={type='meter_panel_swap',a=swap_pair.a,b=swap_pair.b,geometry=geometry}
  end
  R.ImGui_PopID(ctx)
  R.ImGui_SetCursorScreenPos(ctx,old_x,old_y)
  return action,x,y,x+width,y+height-ruler
end

return panel
