-- Compact readings keep their full measurement model; only their arrangement changes.
local theme=require('ui.theme')
local drawing=require('ui.meter_drawing')
local compact=require('core.meter_compact')
local readings=require('core.meter_readings')
local scale=require('core.meter_scale')
local warnings=require('core.meter_warnings')
local widgets=require('ui.widgets')
local tips=require('ui.tips')
local numeric={}
local R,T=reaper,theme.tokens
local LABELS={m='M',s='S',i='I',tp='TP',lra='LRA',crest='Crest Factor',rms='RMS',target='Target Diff'}
local UNITS={tp='dBTP',lra='LU',crest='dB',rms='dBFS',target='LU'}
local DETAILS={m='Momentary · 400 ms',s='Short-term · 3 seconds',i='Integrated · this playback',
  tp='Highest true peak across L/R since reset.',lra='Loudness range',
  crest='Sample peak above average RMS since reset.',rms='Stereo average level over 400 ms.'}
local MEASUREMENTS={{'I','Integrated'},{'M','Momentary'},{'S','Short-Term'}}

local function value(model,key)
  local values=model.values or {}
  if key=='tp' then return model.tp_max end
  if key=='rms' then return readings.rms(values) end
  if key=='target' then return readings.target_difference(model) end
  if key=='i' and model.prefs.keep_integrated==false and model.playing==false and not model.hold then return nil end
  return values[key]
end

local function text_size(ctx,text,size)
  local pushed=theme.push_release_font(ctx,size)
  local width,height=R.ImGui_CalcTextSize(ctx,text)
  if pushed then R.ImGui_PopFont(ctx) end
  return width,height
end

local function text_width(ctx,text,size)
  return text_size(ctx,text,size)
end

local function fixed_text(ctx,dl,x,y,text,colour,size,align,row_height)
  local pushed=theme.push_release_font(ctx,size)
  local width,height=R.ImGui_CalcTextSize(ctx,text)
  if align=='center' then x=x-width/2 end
  -- Line-box bottoms are not font baselines. Different sizes share a row centre.
  local top=y+(row_height-height)/2
  R.ImGui_DrawList_AddText(dl,x,top,colour,text)
  if pushed then R.ImGui_PopFont(ctx) end
end

-- Measure representative values once per draw, independently of live readings.
-- This keeps resizing and sign changes from moving the four groups.
local function text_metrics(ctx,s)
  local label_size=13*s
  local label_width,label_height=text_size(ctx,'TP',label_size)
  local lufs_width,lufs_height=text_size(ctx,'LUFS',label_size)
  local dbtp_width,dbtp_height=text_size(ctx,'dBTP',label_size)
  local unit_width=math.max(lufs_width,dbtp_width)
  local unit_height=math.max(lufs_height,dbtp_height)
  local widths={tile={},inline={}}
  local heights={value={}}
  heights.header=math.ceil(math.max(label_height,unit_height)+4*s)
  heights.detail_header=heights.header
  for _,size in ipairs({26,24,22,20}) do
    local minus_width,minus_height=text_size(ctx,'−88.8',size*s)
    local plus_width,plus_height=text_size(ctx,'+88.8',size*s)
    local number_width=math.max(minus_width,plus_width)
    widths.tile[size]=math.max(label_width,number_width+4*s+unit_width)+4*s
    widths.inline[size]=label_width+8*s+number_width+4*s+unit_width+4*s
    heights.value[size]=math.ceil(math.max(minus_height,plus_height,unit_height)+2*s)
  end
  local maximum_width,maximum_height=text_size(ctx,'Max −88.8',16*s)
  widths.maxima=maximum_width+4*s
  heights.maxima=math.ceil(maximum_height+4*s)
  local detail_number_width,detail_number_height=text_size(ctx,'−88.8',20*s)
  local detail_unit_width,detail_unit_height=text_size(ctx,'dBFS',label_size)
  widths.detail=math.max(text_width(ctx,'Target Diff (M)',label_size),
    text_width(ctx,'Crest Factor',label_size),
    detail_number_width+4*s+detail_unit_width)+4*s
  heights.detail_value=math.ceil(math.max(detail_number_height,detail_unit_height)+4*s)
  return widths,heights
end

function numeric.draw(ctx,dl,r,model,presentation)
  if not r.surface_painted then drawing.surface(dl,r) end
  local s,opts=theme.scale,model.prefs
  local alpha=R.ImGui_GetStyleVar(ctx,R.ImGui_StyleVar_Alpha())
  local secondary,tertiary=theme.fade(T.TEXT_SECONDARY,alpha),theme.fade(T.TEXT_TERTIARY,alpha)
  local widths,heights=text_metrics(ctx,s)
  -- Without a footer, leave the hover button clear and mirror its allowance on
  -- the left so the four readings remain centred even when the button is hidden.
  local gutter=math.max(0,(r.corner_size or 0)-math.floor(8*s+.5))
  local content_x,content_width=r.x+gutter,r.w-gutter*2
  local plan=compact.measure(content_width,r.h,{scale=s,extra_readings=opts.extra_readings,
    show_lra=opts.show_lra~=false,text_widths=widths,text_heights=heights})
  if not plan then
    local message='Enlarge the view to see readings.'
    local _,message_height=text_size(ctx,message,13*s)
    if r.h>=message_height then
      drawing.text(ctx,dl,content_x+8*s,r.y+(r.h-message_height)/2,
        message,tertiary,13*s,nil,math.max(0,content_width-16*s))
    end
    return
  end
  local old_x,old_y=R.ImGui_GetCursorScreenPos(ctx)
  local label_size=plan.label_size*s
  local measurement=opts.target_difference_measurement or 'Integrated'
  local selected=1
  for i,entry in ipairs(MEASUREMENTS) do if entry[2]==measurement then selected=i;break end end
  local action
  for _,item in ipairs(plan.items) do
    local key=item.key
    local x,y=content_x+item.x,r.y+item.y
    local cx=x+item.w/2
    local raw=value(model,key)
    local is_loudness=key=='m' or key=='s' or key=='i'
    local formatted=is_loudness and drawing.loudness_number(raw,opts) or drawing.number(raw)
    if (key=='target' or key=='tp') and raw and raw>=.05 then formatted='+'..formatted end
    local label=LABELS[key]
    if key=='target' then label=label..' ('..MEASUREMENTS[selected][1]..')' end
    local unit=is_loudness and scale.unit(opts) or UNITS[key]
    local colour=raw and T.ACCENT or T.TEXT_TERTIARY
    if key=='tp' and raw and warnings.active(model.warnings,'tp') then colour=T.DANGER_RED end
    local size=(item.detail and plan.detail_value_size or plan.value_size)*s
    if item.detail and raw then colour=T.TEXT_SECONDARY end
    colour=theme.fade(colour,alpha)
    local number_w=text_width(ctx,formatted,size)
    local unit_w=text_width(ctx,unit,label_size)
    local group_w=number_w+4*s+unit_w
    local number_x=cx-group_w/2
    if plan.inline then
      local label_w=text_width(ctx,label,label_size)
      local label_x=cx-(label_w+8*s+group_w)/2
      number_x=label_x+label_w+8*s
      fixed_text(ctx,dl,label_x,y,label,secondary,label_size,nil,item.h)
      fixed_text(ctx,dl,number_x,y,formatted,colour,size,nil,item.h)
      fixed_text(ctx,dl,number_x+number_w+4*s,y,unit,tertiary,label_size,nil,item.h)
    else
      local header=item.detail and plan.detail_header_height or plan.header_height
      local value_h=item.detail and plan.detail_value_height or plan.value_height
      local label_w=text_width(ctx,label,label_size)
      local header_x=cx-label_w/2
      if key=='target' and not presentation then
        R.ImGui_SetCursorScreenPos(ctx,header_x,y)
        if widgets.text_button(ctx,'##numeric_target',label,label_w,header,label_size,
            'Click to switch to '..MEASUREMENTS[selected%#MEASUREMENTS+1][2]..'.') then
          action={type='meter_set_preference',key='target_difference_measurement',value=MEASUREMENTS[selected%#MEASUREMENTS+1][2]}
        end
      else fixed_text(ctx,dl,cx,y,label,secondary,label_size,'center',header) end
      local value_y=y+header
      fixed_text(ctx,dl,number_x,value_y,formatted,colour,size,nil,value_h)
      fixed_text(ctx,dl,number_x+number_w+4*s,value_y,unit,tertiary,label_size,nil,value_h)
      if plan.show_maxima and (key=='m' or key=='s') then
        local maximum=model[key..'_max']
        local text='Max '..drawing.loudness_number(maximum,opts)
        fixed_text(ctx,dl,cx,y+header+value_h,text,secondary,
          plan.maximum_size*s,'center',plan.maximum_height)
      end
    end
    if not presentation then
      local hovered=R.ImGui_IsMouseHoveringRect(ctx,x,y,x+item.w,y+item.h)
      tips.show(ctx,hovered,(DETAILS[key] or measurement..' above (+) or below (−) target.')
        ..'\n'..formatted..' '..unit,'numeric_meter_'..key)
      -- Leave the shared hover button's corner free for its own input item.
      local corner=(r.corner_size or 0)>0 and R.ImGui_IsMouseHoveringRect(ctx,
        r.x+r.w-r.corner_size,r.y,r.x+r.w,r.y+r.corner_size)
      if not item.detail and not corner then
        R.ImGui_SetCursorScreenPos(ctx,x,y)
        if R.ImGui_InvisibleButton(ctx,'##numeric_clear_'..key,item.w,item.h) then
          action=action or {type='meter_clear_warnings'}
        end
      end
    end
  end
  R.ImGui_SetCursorScreenPos(ctx,old_x,old_y)
  return action
end

return numeric
