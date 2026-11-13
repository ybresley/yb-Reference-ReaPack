-- Compact readings keep their full measurement model; only their arrangement changes.
local theme=require('ui.theme')
local drawing=require('ui.meter_drawing')
local compact=require('core.meter_compact')
local readings=require('core.meter_readings')
local scale=require('core.meter_scale')
local warnings=require('core.meter_warnings')
local widgets=require('ui.widgets')
local tips=require('ui.tips')
local bars=require('ui.meter_bars')
local pointer=require('ui.meter_hover')
local numeric={}
local R,T=reaper,theme.tokens
local LABELS={m='M',s='S',i='I',tp='TP',peak='Peak',lra='LRA',crest='Crest Factor',rms='RMS',target='Target Diff'}
local UNITS={tp='dBTP',peak='dBFS',lra='LU',crest='dB',rms='dBFS',target='LU'}
local DETAILS={m='Momentary · 400 ms',s='Short-term · 3 seconds',i='Integrated · this playback',
  tp='Highest true peak across all channels since reset.',peak='Highest sample peak across all channels over 400 ms.',lra='Loudness range',
  crest='Sample peak above average RMS since reset.',rms='Stereo average level over 400 ms.'}
local MEASUREMENTS={{'I','Integrated'},{'M','Momentary'},{'S','Short-Term'}}
local SHORT_NAMES={m='Momentary',s='Short-Term',i='Integrated',tp='TP Max'}

local function value(model,key)
  local values=model.values or {}
  if key=='tp' then return model.true_peak_available~=false and model.tp_max or nil end
  if key=='peak' then return readings.peak(values) end
  if model.loudness_available==false and (key=='m' or key=='s' or key=='i'
      or key=='lra' or key=='target') then return nil end
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
  local widths={tile={}}
  local heights={headers={},value={}}
  for _,size in ipairs(compact.value_sizes) do
    local label_size=compact.label_size(size)*s
    local label_width,label_height=text_size(ctx,'TP',label_size)
    local lufs_width,lufs_height=text_size(ctx,'LUFS',label_size)
    local dbtp_width,dbtp_height=text_size(ctx,'dBTP',label_size)
    local unit_width=math.max(lufs_width,dbtp_width)
    local unit_height=math.max(lufs_height,dbtp_height)
    local minus_width,minus_height=text_size(ctx,'−88.8',size*s)
    local plus_width,plus_height=text_size(ctx,'+88.8',size*s)
    local number_width=math.max(minus_width,plus_width)
    widths.tile[size]=math.max(label_width,number_width+4*s+unit_width)+4*s
    heights.headers[size]=math.ceil(math.max(label_height,unit_height)+4*s)
    heights.value[size]=math.ceil(math.max(minus_height,plus_height,unit_height)+2*s)
  end
  -- One row per reading below the stacked layouts: label, value and unit side by side.
  local inline_label=compact.label_size(16)*s
  local widest_label=0
  for _,label in ipairs({'M','S','I','TP'}) do
    widest_label=math.max(widest_label,text_width(ctx,label,inline_label))
  end
  local number_16=math.max(text_width(ctx,'−88.8',16*s),text_width(ctx,'+88.8',16*s))
  local unit_16=math.max(text_width(ctx,'LUFS',inline_label),text_width(ctx,'dBTP',inline_label))
  widths.inline=widest_label+6*s+number_16+4*s+unit_16+4*s
  widths.inline_number=number_16
  heights.inline=heights.value[16]
  local label_size=13*s
  heights.detail_header=heights.headers[26]
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
  local unavailable=model.loudness_available==false
  local basic=model.sample_rate_supported==false
  local show_hint=r.layout_hint and (not basic or r.h>=90*s)
  local hint_height=show_hint and math.min(38*s,r.h/2) or 0
  if show_hint then
    drawing.layout_hint(ctx,dl,{x=content_x,y=r.y,w=content_width,h=hint_height},model)
  end
  local layout_options={scale=s,
    primary_keys=basic and {'peak','rms'} or nil,
    extra_readings=not basic and opts.extra_readings,
    show_lra=not unavailable and opts.show_lra~=false,text_widths=widths,text_heights=heights,
    -- Without loudness, the working peak reading is the one worth keeping.
    short_keys=unavailable and {'tp'} or {opts.short_first,opts.short_second}}
  local plan=compact.measure(content_width,r.h-hint_height,layout_options)
  if not plan and unavailable and not basic then
    -- Keep the working peak reading when the complete frame cannot fit.
    layout_options.primary_keys={'tp'}
    plan=compact.measure(content_width,r.h-hint_height,layout_options)
  end
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
  local measurement=opts.target_difference_measurement or 'Integrated'
  local selected=1
  for i,entry in ipairs(MEASUREMENTS) do if entry[2]==measurement then selected=i;break end end
  local action
  local label_hovered
  for item_index,item in ipairs(plan.items) do
    label_hovered=false
    local key=item.key
    local x,y=content_x+item.x,r.y+hint_height+item.y
    local cx=x+item.w/2
    local raw=value(model,key)
    local is_loudness=key=='m' or key=='s' or key=='i'
    local formatted=is_loudness and drawing.loudness_number(raw,opts) or drawing.number(raw)
    if (key=='target' or key=='tp' or key=='peak') and raw and raw>=.05 then formatted='+'..formatted end
    local label=LABELS[key]
    if key=='target' then label=label..' ('..MEASUREMENTS[selected][1]..')' end
    local unit=is_loudness and scale.unit(opts) or UNITS[key]
    local colour=raw and T.ACCENT or T.TEXT_TERTIARY
    if is_loudness then colour=bars.loudness_colour(model,opts,key,raw) end
    if key=='tp' and raw and warnings.active(model.warnings,'tp') then colour=T.DANGER_RED end
    local size=(item.detail and plan.detail_value_size or plan.value_size)*s
    local label_size=(item.detail and plan.detail_label_size or plan.label_size)*s
    if item.detail and raw then colour=T.TEXT_SECONDARY end
    colour=theme.fade(colour,alpha)
    local number_w=text_width(ctx,formatted,size)
    local unit_w=text_width(ctx,unit,label_size)
    local group_w=number_w+4*s+unit_w
    local number_x=cx-group_w/2
    local header=item.detail and plan.detail_header_height or plan.header_height
    local value_h=item.detail and plan.detail_value_height or plan.value_height
    local label_w=text_width(ctx,label,label_size)
    local header_x=cx-label_w/2
    if plan.inline then
      -- The number sits in a fixed slot, right-aligned, so changing values
      -- never move the label or the unit.
      local slot_w=widths.inline_number
      local left=cx-(label_w+6*s+slot_w+4*s+unit_w)/2
      local slot_x=left+label_w+6*s
      if plan.choosable and not presentation then
        local shown={}
        for index,entry in ipairs(plan.items) do shown[index]=entry.key end
        local next_key=compact.next_short_key(shown,item_index)
        -- The button draws from its top edge; centre it on the row like the value.
        local _,label_h=text_size(ctx,label,label_size)
        R.ImGui_SetCursorScreenPos(ctx,left,y+(value_h-label_h)/2)
        if widgets.text_button(ctx,'##numeric_short_'..item_index,label,label_w,label_h,label_size,
            'Click to show '..SHORT_NAMES[next_key]..'.') then
          action={type='meter_set_preference',key=item_index==1 and 'short_first' or 'short_second',
            value=next_key}
        end
        label_hovered=R.ImGui_IsItemHovered(ctx)
      else fixed_text(ctx,dl,left,y,label,secondary,label_size,nil,value_h) end
      fixed_text(ctx,dl,slot_x+slot_w-number_w,y,formatted,colour,size,nil,value_h)
      fixed_text(ctx,dl,slot_x+slot_w+4*s,y,unit,tertiary,label_size,nil,value_h)
    elseif key=='target' and not presentation then
      R.ImGui_SetCursorScreenPos(ctx,header_x,y)
      if widgets.text_button(ctx,'##numeric_target',label,label_w,header,label_size,
          'Click to switch to '..MEASUREMENTS[selected%#MEASUREMENTS+1][2]..'.') then
        action={type='meter_set_preference',key='target_difference_measurement',value=MEASUREMENTS[selected%#MEASUREMENTS+1][2]}
      end
    else fixed_text(ctx,dl,cx,y,label,secondary,label_size,'center',header) end
    if not plan.inline then
      local value_y=y+header
      fixed_text(ctx,dl,number_x,value_y,formatted,colour,size,nil,value_h)
      fixed_text(ctx,dl,number_x+number_w+4*s,value_y,unit,tertiary,label_size,nil,value_h)
    end
    if plan.show_maxima and (key=='m' or key=='s') then
      local maximum=not unavailable and model[key..'_max'] or nil
      local text='Max '..drawing.loudness_number(maximum,opts)
      fixed_text(ctx,dl,cx,y+header+value_h,text,secondary,
        plan.maximum_size*s,'center',plan.maximum_height)
    end
    if not presentation then
      local hovered=pointer.rect(ctx,x,y,x+item.w,y+item.h)
      local detail=DETAILS[key] or measurement..' above (+) or below (−) target.'
      if key=='rms' and model.channel_profile
          and (model.channel_profile.count~=2 or model.channel_profile.known==false) then
        detail='Average level across all channels over 400 ms.'
      end
      if basic then detail=detail..'\nLUFS unavailable at this sample rate.' end
      if key=='tp' and model.channel_profile and model.values and model.values.channels then
        for index,entry in ipairs(model.values.channels) do
          local label=model.channel_profile.labels and model.channel_profile.labels[index] or 'Ch '..index
          detail=detail..'\n'..label..' · Peak '..drawing.number(entry.peak)
            ..' '..(readings.peak_measurement(model)=='Sample Peak' and 'dBFS' or 'dBTP')
            ..' · RMS '..drawing.number(entry.rms)..' dBFS · Crest '..drawing.number(entry.crest)..' dB'
        end
      end
      tips.show(ctx,hovered and not label_hovered,detail..'\n'..formatted..' '..unit,'numeric_meter_'..key,
        tips.rect(x,y,item.w,item.h))
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
