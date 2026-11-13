local core=require('core.analysis_channels')
local arrangements=require('core.speaker_arrangements')
local diagram=require('core.speaker_diagram')
local theme=require('ui.theme')
local tips=require('ui.tips')
local widgets=require('ui.widgets')
local ui={}
local ROLE_NAMES,ROLE_IDS,ROLE_LABELS={},{},{}
for i,role in ipairs(core.roles()) do
  ROLE_NAMES[i],ROLE_IDS[i]=role.label,role.id
  ROLE_LABELS[role.id]=role.label:gsub(' %(45°%)','')
end

local function combo(ctx,id,label,value,labels,values,width,disabled)
  reaper.ImGui_BeginGroup(ctx)
  reaper.ImGui_Text(ctx,label)
  reaper.ImGui_SetNextItemWidth(ctx,width)
  local selected=0
  for i,candidate in ipairs(values) do if value==candidate then selected=i-1 end end
  if disabled then reaper.ImGui_BeginDisabled(ctx) end
  local items=type(labels)=='string' and labels or table.concat(labels,'\0')..'\0'
  local changed,index=reaper.ImGui_Combo(ctx,'##channels_'..id,selected,items)
  if disabled then reaper.ImGui_EndDisabled(ctx) end
  reaper.ImGui_EndGroup(ctx)
  if changed then return {type='analysis_channels_setting',key=id,value=values[index+1]} end
end

local function all_unassigned(profile)
  for _,role in ipairs(profile.roles) do if role~='unknown' then return false end end
  return true
end

-- The Speaker Arrangement list's rows: a heading for each channel count, with
-- separators between the groups. Release demonstrations paint the same rows.
-- One list per channel count, built once.
local arrangement_lists={}
function ui.arrangement_rows(available)
  local rows=arrangement_lists[available]
  if rows then return rows end
  rows={}
  local previous_count
  for _,item in ipairs(arrangements.list(available,true)) do
    if item.count~=previous_count then
      if previous_count then rows[#rows+1]={kind='separator'} end
      rows[#rows+1]={kind='heading',text=item.count..(item.count==1 and ' Channel' or ' Channels')}
      previous_count=item.count
    end
    rows[#rows+1]={kind='item',text=item.label,id=item.id}
  end
  arrangement_lists[available]=rows
  return rows
end

local function arrangement_combo(ctx,width,profile,available,current)
  reaper.ImGui_Text(ctx,'Speaker Arrangement')
  reaper.ImGui_SetNextItemWidth(ctx,width)
  local preview=current and current.label or not all_unassigned(profile) and 'Custom Arrangement'
    or 'Unassigned'
  local action
  if reaper.ImGui_BeginCombo(ctx,'##channels_arrangement',preview) then
    for _,row in ipairs(ui.arrangement_rows(available)) do
      if row.kind=='separator' then reaper.ImGui_Separator(ctx)
      elseif row.kind=='heading' then reaper.ImGui_TextDisabled(ctx,row.text)
      elseif reaper.ImGui_Selectable(ctx,row.text,current and current.id==row.id or false) then
        action={type='analysis_channels_setting',key='arrangement',value=row.id}
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end
  return action
end

-- The card and every control slot are independent of assignments and order.
local placement_cache
local function placement(ctx,profile,x,y,width,height,preview)
  local R,T=reaper,theme.tokens
  local scale=theme.scale
  local dl=R.ImGui_GetWindowDrawList(ctx)
  local alpha=R.ImGui_GetStyleVar(ctx,R.ImGui_StyleVar_Alpha())
  local function colour(token) return theme.fade(token,alpha) end
  local rounding=R.ImGui_GetStyleVar(ctx,R.ImGui_StyleVar_FrameRounding())
  R.ImGui_DrawList_AddRectFilled(dl,x,y,x+width,y+height,colour(T.BG_WINDOW),rounding)
  R.ImGui_DrawList_AddRect(dl,x,y,x+width,y+height,colour(T.STROKE_SECONDARY),rounding)
  local font_w,font_h=R.ImGui_CalcTextSize(ctx,'MW0123456789')
  local signature=table.concat({tostring(ctx),profile and profile.signature or '',width,height,scale,
    R.ImGui_GetFontSize(ctx),font_w,font_h},':')
  if not placement_cache or placement_cache.signature~=signature then
    placement_cache={signature=signature,layout=diagram.layout(profile,
      {x=0,y=0,width=width,height=height,numbers=true},
      function(text) return R.ImGui_CalcTextSize(ctx,text) end,scale,3.4)}
  end
  local layout=placement_cache.layout
  local cx,cy,radius=x+layout.cx,y+layout.cy,layout.radius
  R.ImGui_DrawList_PushClipRect(dl,x,y,x+width,y+height,true)
  if radius>0 then
    R.ImGui_DrawList_AddCircle(dl,cx,cy,radius,colour(T.STROKE_PRIMARY),64,scale)
    R.ImGui_DrawList_AddLine(dl,cx-radius,cy,cx+radius,cy,colour(T.SPECTRUM_GRID),scale)
    R.ImGui_DrawList_AddLine(dl,cx,cy-radius,cx,cy+radius,colour(T.SPECTRUM_GRID),scale)
    R.ImGui_DrawList_AddCircleFilled(dl,cx,cy,2.3*scale,colour(T.TEXT_TERTIARY),12)
  end
  local has_height=false
  for _,point in ipairs(layout.points) do has_height=has_height or point.ring<1 end
  if has_height then R.ImGui_DrawList_AddCircle(dl,cx,cy,layout.inner_radius,colour(T.SPECTRUM_GRID),48,scale) end
  for _,point in ipairs(layout.points) do
    local leader=layout.fits and point.leader
    if leader then
      R.ImGui_DrawList_AddLine(dl,x+leader.x1,y+leader.y1,x+leader.x2,y+leader.y2,colour(T.STROKE_PRIMARY),scale)
    end
    R.ImGui_DrawList_AddCircleFilled(dl,x+point.x,y+point.y,3.4*scale,
      colour(preview and T.TEXT_TERTIARY or T.STEREO_TRACE),12)
    local label=layout.fits and point.label
    if label then
      R.ImGui_DrawList_AddText(dl,x+label.x,y+label.y,colour(preview and T.TEXT_TERTIARY or T.TEXT_SECONDARY),label.text)
    end
  end
  R.ImGui_DrawList_PopClipRect(dl)
  R.ImGui_SetCursorScreenPos(ctx,x,y)
  R.ImGui_Dummy(ctx,width,height)
  tips.show(ctx,R.ImGui_IsItemHovered(ctx),
    layout.compact and 'Enlarge the view to see diagram labels. The key still shows the channel order.'
      or 'Channel numbers show the project order. Height speakers sit on the inner ring. LFE is shown separately.',
    'audio_speaker_placement')
end

local function key(ctx,profile,x,y,width,height,preview)
  if not profile then return end
  local R,T,M=reaper,theme.tokens,theme.metrics
  local dl=R.ImGui_GetWindowDrawList(ctx)
  local alpha=R.ImGui_GetStyleVar(ctx,R.ImGui_StyleVar_Alpha())
  R.ImGui_DrawList_AddLine(dl,x,y,x+width,y,theme.fade(T.STROKE_SECONDARY,alpha),theme.scale)
  local text_colour=theme.fade(preview and T.TEXT_TERTIARY or T.TEXT_SECONDARY,alpha)
  if preview then
    R.ImGui_DrawList_AddText(dl,x,y+M.ITEM_SPACING_Y,text_colour,preview..' Preview')
  end
  -- Reserve the same caption row after confirmation so the key never moves.
  local caption_h=R.ImGui_GetTextLineHeight(ctx)+M.ITEM_SPACING_Y
  y,height=y+caption_h,height-caption_h
  local rows=math.ceil(profile.count/2)
  local line_height=R.ImGui_GetTextLineHeight(ctx)
  -- Wrap every name first, so each row is only as tall as its longest name.
  local wrapped,row_lines={},{}
  for i,role in ipairs(profile.roles) do
    local column=math.floor((i-1)/rows)
    local tx=x+column*(width+M.AUDIO_LAYOUT_KEY_GAP)/2
    local label_x=tx+M.AUDIO_LAYOUT_KEY_NUMBER_W
    local right=x+(column+1)*width/2
    local lines,current={},''
    for word in ROLE_LABELS[role]:gmatch('%S+') do
      local candidate=current=='' and word or current..' '..word
      if current~='' and R.ImGui_CalcTextSize(ctx,candidate)>right-label_x then
        lines[#lines+1]=current; current=word
      else current=candidate end
    end
    lines[#lines+1]=current
    wrapped[i]={tx=tx,label_x=label_x,right=right,lines=lines}
    local row=(i-1)%rows+1
    row_lines[row]=math.max(row_lines[row] or 1,#lines)
  end
  local row_y,next_y={},y+M.ITEM_SPACING_Y
  for row=1,rows do
    row_y[row]=next_y
    next_y=next_y+row_lines[row]*line_height+M.ITEM_SPACING_Y
  end
  local bottom=y+height
  for i,entry in ipairs(wrapped) do
    local row=(i-1)%rows+1
    local ty=row_y[row]
    R.ImGui_DrawList_PushClipRect(dl,entry.tx,ty,entry.right,math.min(bottom,ty+row_lines[row]*line_height),true)
    R.ImGui_DrawList_AddText(dl,entry.tx,ty,text_colour,tostring(i))
    for j,label in ipairs(entry.lines) do
      R.ImGui_DrawList_AddText(dl,entry.label_x,ty+(j-1)*line_height,text_colour,label)
    end
    R.ImGui_DrawList_PopClipRect(dl)
  end
end

function ui.draw_content(ctx,state)
  local R,T,M=reaper,theme.tokens,theme.metrics
  local profile=state.analysis_channels
  local available=state.analysis_channel_available_count or profile and profile.count
  local suggestion=profile and all_unassigned(profile) and not state.analysis_channel_error
    and state.analysis_channel_suggestion or nil
  local suggested=suggestion and arrangements.get(suggestion.arrangement)
  local suggestion_label=suggested and suggested.label
  if not suggestion_label or not suggestion.profile then suggestion=nil end
  local x,y=R.ImGui_GetCursorScreenPos(ctx)
  local width=R.ImGui_GetContentRegionAvail(ctx)
  local small=theme.push_small_font(ctx)
  local count=available and string.format('%d master channels',available) or 'No active project'
  local count_w=R.ImGui_CalcTextSize(ctx,count)
  R.ImGui_DrawList_AddText(R.ImGui_GetWindowDrawList(ctx),x+width-M.WINDOW_PAD-count_w,y,
    theme.fade(T.TEXT_TERTIARY,R.ImGui_GetStyleVar(ctx,R.ImGui_StyleVar_Alpha())),count)
  if small then R.ImGui_PopFont(ctx) end
  local line_h=R.ImGui_GetTextLineHeight(ctx)
  local field_h=line_h+M.ITEM_SPACING_Y+R.ImGui_GetFrameHeight(ctx)+M.AUDIO_LAYOUT_FIELD_GAP
  -- Every state reserves a caption and four two-line key rows at the normal font.
  local key_h=4*(2*line_h+M.ITEM_SPACING_Y)+M.ITEM_SPACING_Y
  local card_h=math.max(M.AUDIO_LAYOUT_H,2*M.WINDOW_PAD+2*field_h+line_h+M.ITEM_SPACING_Y+key_h)
  local opened,child=widgets.begin_settings_group(ctx,'audio_project_speakers','Project Speakers',true,card_h)
  local action
  if opened then
    local card_x,card_y=R.ImGui_GetCursorScreenPos(ctx)
    local card_w,card_h=R.ImGui_GetContentRegionAvail(ctx)
    local plot_w=(card_w-M.AUDIO_LAYOUT_GAP)*.465
    local side_x=card_x+plot_w+M.AUDIO_LAYOUT_GAP
    local side_w=card_w-plot_w-M.AUDIO_LAYOUT_GAP
    local current,order
    if profile then current,order=arrangements.identify(profile.roles) end
    local shown=profile
    if suggestion then shown=suggestion.profile end
    if state.analysis_channel_error then shown=nil end
    placement(ctx,shown,card_x,card_y,plot_w,card_h,suggestion~=nil)
    R.ImGui_SetCursorScreenPos(ctx,side_x,card_y)
    -- A group keeps each new line in this column after labels advance the cursor.
    R.ImGui_BeginGroup(ctx)
    if not profile then
      R.ImGui_Text(ctx,'Speaker Arrangement')
      R.ImGui_TextWrapped(ctx,'Open a project to see its speakers.')
      combo(ctx,'order','Channel Order','unavailable',{'Unavailable'},{'unavailable'},side_w,true)
    elseif state.analysis_channel_error then
      R.ImGui_Text(ctx,'Speaker Arrangement')
      R.ImGui_TextWrapped(ctx,state.analysis_channel_error)
      if R.ImGui_Button(ctx,'Reset Channel Settings') then action={type='analysis_channels_reset'} end
      combo(ctx,'order','Channel Order','unavailable',{'Unavailable'},{'unavailable'},side_w,true)
    else
      action=arrangement_combo(ctx,side_w,profile,available,current)
      local next_y=card_y+R.ImGui_GetTextLineHeight(ctx)+M.ITEM_SPACING_Y+R.ImGui_GetFrameHeight(ctx)+M.AUDIO_LAYOUT_FIELD_GAP
      R.ImGui_SetCursorScreenPos(ctx,side_x,next_y)
      if current then
        local labels,ids={},{}
        for i,option in ipairs(current.orders) do labels[i],ids[i]=option.label,option.id end
        action=combo(ctx,'order','Channel Order',order.id,labels,ids,side_w,#current.orders<2) or action
        tips.show(ctx,R.ImGui_IsItemHovered(ctx),'Match the project output order. References play in their existing channel order; this setting does not move audio between speakers.')
      elseif not current and not all_unassigned(profile) then
        combo(ctx,'order','Channel Order','custom',{'Custom'},{'custom'},side_w,true)
      else
        combo(ctx,'order','Channel Order','unassigned',{'Unassigned'},{'unassigned'},side_w,true)
      end
      local key_y=next_y+R.ImGui_GetTextLineHeight(ctx)+M.ITEM_SPACING_Y+R.ImGui_GetFrameHeight(ctx)+M.AUDIO_LAYOUT_FIELD_GAP
      key(ctx,shown,side_x,key_y,side_w,card_y+card_h-key_y,suggestion and suggestion_label)
      -- Draw-list text does not reserve layout space, including an empty order slot.
      R.ImGui_SetCursorScreenPos(ctx,side_x,key_y)
      R.ImGui_Dummy(ctx,side_w,card_y+card_h-key_y)
    end
    R.ImGui_EndGroup(ctx)
  end
  widgets.end_settings_group(ctx,child)
  if suggestion then
    reaper.ImGui_TextColored(ctx,T.TEXT_SECONDARY,'Recommended: '..suggestion_label)
    if reaper.ImGui_Button(ctx,'Use Recommendation') then
      action={type='analysis_channels_setting',key='suggestion'}
    end
  end
  return action
end

local output_values={}
for i=0,128 do output_values[i+1]=i end
local output_available,output_items
local function output_choices(available)
  if output_available~=available then
    local labels={'Unassigned'}
    for i=1,128 do labels[i+1]='Output '..i..(i>available and ' (Unavailable)' or '') end
    output_available,output_items=available,table.concat(labels,'\0')..'\0'
  end
  return output_items
end

function ui.draw_outputs(ctx,state)
  local R,M=reaper,theme.metrics
  local profile=state.analysis_channels
  if not profile then return end
  local bold=theme.push_bold_font(ctx)
  R.ImGui_TextColored(ctx,theme.tokens.TEXT_PRIMARY,'Audio Outputs')
  if bold then R.ImGui_PopFont(ctx) end
  R.ImGui_TextWrapped(ctx,'Used for meters and visualizers. Playback stays unchanged.')
  R.ImGui_TextWrapped(ctx,'References play through outputs 1, 2, 3… in order.')
  local width=R.ImGui_GetContentRegionAvail(ctx)
  local available=state.analysis_output_available_count or 0
  local mode=state.analysis_output_mode or 'auto'
  local action=combo(ctx,'output_mode','Output Selection',mode,
    {'Follow Reaper','Choose Outputs'},{'auto','manual'},width,
    state.analysis_output_error~=nil)
  local field_w=(width-M.AUDIO_LAYOUT_GAP)/2
  local row_h=R.ImGui_GetTextLineHeight(ctx)+M.ITEM_SPACING_Y+R.ImGui_GetFrameHeight(ctx)+M.ITEM_SPACING_Y
  local x,y=R.ImGui_GetCursorScreenPos(ctx)
  local map=state.analysis_output_map or {}
  local items=output_choices(available)
  for i=1,profile.count do
    R.ImGui_SetCursorScreenPos(ctx,x+((i-1)%2)*(field_w+M.AUDIO_LAYOUT_GAP),y+math.floor((i-1)/2)*row_h)
    local selected=map[i] or 0
    local chosen=combo(ctx,'output_'..i,'Channel '..i,selected,items,output_values,field_w,
      mode~='manual' or state.analysis_output_error~=nil)
    if chosen then chosen.key='output'; chosen.channel=i; action=chosen end
  end
  R.ImGui_SetCursorScreenPos(ctx,x,y+math.ceil(profile.count/2)*row_h)
  R.ImGui_Dummy(ctx,0,0)
  if state.analysis_output_error then
    R.ImGui_TextWrapped(ctx,state.analysis_output_error)
    if R.ImGui_Button(ctx,'Reset Output Settings') then
      action={type='analysis_channels_setting',key='output_reset'}
    end
  end
  R.ImGui_Dummy(ctx,0,M.ITEM_SPACING_Y)
  R.ImGui_Separator(ctx)
  R.ImGui_Dummy(ctx,0,M.ITEM_SPACING_Y)
  return action
end

function ui.draw_assignments(ctx,state)
  local R,M=reaper,theme.metrics
  local profile=state.analysis_channels
  if not profile then return end
  local bold=theme.push_bold_font(ctx)
  R.ImGui_TextColored(ctx,theme.tokens.TEXT_PRIMARY,'Custom Channel Assignments')
  if bold then R.ImGui_PopFont(ctx) end
  R.ImGui_PushStyleColor(ctx,R.ImGui_Col_Text(),theme.tokens.TEXT_TERTIARY)
  R.ImGui_TextWrapped(ctx,'Rows follow the project’s master channel count, up to 8 channels.')
  R.ImGui_PopStyleColor(ctx)
  local count=math.min(8,state.analysis_channel_available_count or profile.count)
  local x,y=R.ImGui_GetCursorScreenPos(ctx)
  local width=R.ImGui_GetContentRegionAvail(ctx)
  local field_w=(width-M.AUDIO_LAYOUT_GAP)/2
  local row_h=R.ImGui_GetTextLineHeight(ctx)+M.ITEM_SPACING_Y+R.ImGui_GetFrameHeight(ctx)+M.ITEM_SPACING_Y
  local action
  if state.analysis_channel_error then R.ImGui_BeginDisabled(ctx) end
  for i=1,count do
    R.ImGui_SetCursorScreenPos(ctx,x+((i-1)%2)*(field_w+M.AUDIO_LAYOUT_GAP),y+math.floor((i-1)/2)*row_h)
    local chosen=combo(ctx,'role_'..i,'Channel '..i,profile.roles[i] or 'unknown',ROLE_NAMES,ROLE_IDS,field_w)
    if chosen then chosen.key='role'; chosen.channel=i; action=chosen end
  end
  if state.analysis_channel_error then R.ImGui_EndDisabled(ctx) end
  R.ImGui_SetCursorScreenPos(ctx,x,y+math.ceil(count/2)*row_h)
  R.ImGui_PushStyleColor(ctx,R.ImGui_Col_Text(),theme.tokens.TEXT_TERTIARY)
  R.ImGui_TextWrapped(ctx,'If another channel already uses this speaker, the two speaker assignments swap. These settings only affect yb-Reference’s displays and measurements.')
  R.ImGui_PopStyleColor(ctx)
  return action
end
return ui
