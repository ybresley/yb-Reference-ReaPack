-- The panel draws session state and returns intent; the adapter owns all audio.
local theme=require('ui.theme')
local tips=require('ui.tips')
local layout=require('core.meter_layout')
local warnings=require('core.meter_warnings')
local status_text=require('core.meter_status')
local bars=require('ui.meter_bars')
local history=require('ui.meter_history')
local controls=require('ui.meter_controls')
local drawing=require('ui.meter_drawing')
local style=require('ui.meter_style')
local swaps=require('ui.divider_swaps')
local panel={}
local T,R,M=theme.tokens,reaper,theme.metrics

local READING_KEYS={'m','s','tp','crest'}
local READING_LABELS={m='M Max',s='S Max',tp='TP Max',crest='Crest Factor'}
local READING_UNITS={m='LUFS',s='LUFS',tp='dBTP',crest='dB'}
local GROUP_NAMES={loudness='Loudness',lr='L/R',readings='Readings',history='History'}
local PASSIVE={}

local function readings_column(ctx,dl,r,model,embedded)
  if not model.prefs.extra_readings then return end
  local keys=READING_KEYS
  local s,pad=theme.scale,M.WINDOW_PAD
  local available=r.h-(r.footer_height or M.RULER_H)
  local top=r.y+style.plot_top*s
  local row,height
  if embedded then
    row=(drawing.meter_bottom(r)-top)/#keys
    height=available
  else
    row=math.min(M.METER_READINGS_ROW_H,(available-style.plot_top*s-pad*2)/#keys)
    height=style.plot_top*s+pad*2+row*#keys
    top=top+pad
    drawing.surface(dl,{x=r.x,y=r.y,w=r.w,h=height})
  end
  local centre=r.x+(r.w-20*s)/2
  local values=model.values or {}
  R.ImGui_DrawList_PushClipRect(dl,r.x,r.y,r.x+r.w,r.y+height,true)
  for i,key in ipairs(keys) do
    -- Raise the text block slightly: visible glyphs sit below its nominal centre.
    local y=top+(i-.5)*row-20*s
    local value=key=='crest'
      and drawing.number(values.crest)
      or drawing.number(model[key..'_max'])
    local colour=key=='tp' and warnings.active(model.warnings,'tp') and T.DANGER_RED or T.ACCENT
    if value=='—' then colour=T.TEXT_TERTIARY end
    local font=theme.push_release_font(ctx,20*s)
    local body=value:gsub('^−','')
    local body_width=R.ImGui_CalcTextSize(ctx,body)
    if font then R.ImGui_PopFont(ctx) end
    drawing.text(ctx,dl,centre,y,READING_LABELS[key],T.TEXT_SECONDARY,11*s,'center',r.w-pad*2)
    drawing.text(ctx,dl,centre,y+14*s,value,colour,20*s,'number')
    drawing.text(ctx,dl,centre+body_width/2+5*s,y+18*s,READING_UNITS[key],T.TEXT_TERTIARY,12*s)
  end
  R.ImGui_DrawList_PopClipRect(dl)
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

function panel.measure(width,height,opts,top_row_height,splits,footer_height)
  local count=#READING_KEYS
  local geometry=layout.calculate(width,height,{scale=theme.scale,
    show_meters=opts.show_meters,show_loudness=opts.show_loudness,
    show_lr=opts.show_lr,show_history=opts.show_history,
    history_position=opts.history_position,
    show_readings=opts.extra_readings==true,
    readings_width=M.METER_READINGS_W/theme.scale,
    readings_min_height=(M.METER_READINGS_MIN_ROW_H*count
      +M.WINDOW_PAD*2+M.RULER_H)/theme.scale+style.plot_top,
    top_row_height=top_row_height,splits=splits})
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
  local readout_size=bars.readout_size(model.prefs)
  local function translated(r)
    return r and {x=x+r.x,y=y+r.y,w=r.w,h=r.h,controls=r.controls,
      plot_left=r.plot_left,axis_side=r.axis_side,footer_height=r.footer_height}
  end
  local first=translated(geometry.loudness or geometry.lr)
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
      if shared then drawing.surface(dl,shared) end
      shared=r
    end
  end
  if shared then drawing.surface(dl,shared) end
  local action
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
  if geometry.readings then readings_column(ctx,dl,translated(geometry.readings),model,first~=nil) end
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
  local meter_visible=model.prefs.show_meters~=false
  local minimum_width=not meter_visible and 160
    or model.prefs.show_loudness and model.prefs.show_lr and 312 or 260
  if width<minimum_width*s or height<minimum_height(effective_footer) then
    drawing.surface(dl,{x=x,y=y,w=width,h=math.max(0,height-ruler)})
    drawing.text(ctx,R.ImGui_GetWindowDrawList(ctx),x+4*s,y+4*s,'Enlarge the view to see the meters.',T.TEXT_TERTIARY,11*s,nil,math.max(0,width-8*s))
    return
  end
  R.ImGui_PushID(ctx,'output_meter')
  local opts=model.prefs
  geometry=set_footer_height(geometry or panel.measure(width,height,opts,nil,split_state(state)),footer_height)
  -- Only the top-right group shares its heading with the permanent menu button.
  for _,key in ipairs({'loudness','lr','history'}) do
    local r=geometry[key]
    if r and r.y==0 and r.x+r.w>=width-1 then r.controls=true end
  end
  local reconnect=model.error or not model.attached
  local error=model.preference_error or (model.error and status_text.error(model.error))
    or (not model.attached and 'Meter unavailable')
  local error_top=error and y+math.max(24*s,(height-62*s)/2)
  local error_hover=error and R.ImGui_IsMouseHoveringRect(ctx,
    x+8*s,error_top,x+width-8*s,error_top+62*s)
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
  local action=panel.paint(ctx,model,geometry,x,y,(error or split_blocked) and PASSIVE or nil)
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
  local menu_action=controls.draw(ctx,model,x+8*s,y+2*s,width-16*s-menu_inset,res,
    geometry.history_hidden,{x=x,y=y,w=width,h=height},geometry.readings_hidden)
  action=menu_action or action
  swaps.paint(ctx,swap_input)
  if error then
    -- A fault stays visible without reserving a status row or moving the plots.
    local top=error_top
    drawing.rect(dl,x+8*s,top,width-16*s,62*s,T.BG_POPUP,4*s)
    drawing.text(ctx,dl,x+16*s,top+8*s,error,T.DANGER_RED,11*s,nil,width-32*s)
    tips.show(ctx,R.ImGui_IsMouseHoveringRect(ctx,x+8*s,top,x+width-8*s,top+62*s),error,'meter_error')
    if reconnect then
      R.ImGui_SetCursorScreenPos(ctx,x+width-100*s,top+32*s)
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
