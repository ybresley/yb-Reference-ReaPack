local notices=require('core.analysis_notice')
local layout=require('core.analysis_notice_layout')
local status_panel=require('ui.spectrum_status')
local theme=require('ui.theme')
local popups=require('ui.popups')
local tips=require('ui.tips')
local widgets=require('ui.widgets')
local ui={}
local OUTPUT_PANELS={'stereo','spectrum','loudness'}
local recovery_popup='##analysis_recovery'

local function same_message(a,b)
  return a.title==b.title and a.detail==b.detail and a.button==b.button and a.action==b.action
    and a.recommendation==b.recommendation
    and a.secondary_button==b.secondary_button and a.secondary_action==b.secondary_action
end

local function intersects(x,y,w,h,other)
  return x<other.x+other.w and x+w>other.x and y<other.y+other.h and y+h>other.y
end

local function has_channel_layout(cards)
  for _,card in ipairs(cards) do
    if card.message.channel_layout then return true end
  end
  return false
end

local function compact_trigger(area,cards,height)
  if not area or area.w<1 or area.h<1 then return end
  local w,h=math.min(area.w,height),math.min(area.h,height)
  local center=area.x+(area.w-w)/2
  local middle=area.y+(area.h-h)/2
  local best,distance
  local function consider(x,y)
    if x<area.x or x+w>area.x+area.w then return end
    if y<area.y or y+h>area.y+area.h then return end
    for _,card in ipairs(cards) do
      if intersects(x,y,w,h,card) then return end
    end
    local offset=math.abs(x-center)+math.abs(y-middle)
    if not distance or offset<distance then best,distance={x=x,y=y},offset end
  end
  consider(center,middle)
  for _,card in ipairs(cards) do
    consider(card.x-w,middle)
    consider(card.x+card.w,middle)
    consider(center,card.y-h)
    consider(center,card.y+card.h)
  end
  if not best then return end
  return {x=best.x,y=best.y,w=w,h=h,x0=best.x,y0=best.y,x1=best.x+w,y1=best.y+h}
end

local function setup_meter_trigger(ctx,area,cards,message)
  local M=theme.metrics
  local button_h=status_panel.minimum_height(ctx)
  local h=math.min(button_h,area.h)
  local inset=math.min(M.WINDOW_PAD,math.max(0,(area.w-button_h)/2))
  local room=area.w-2*inset
  if h<1 or room<h then return end
  local label=message.title
  local text_w,text_h=reaper.ImGui_CalcTextSize(ctx,label)
  local label_w=text_w+2*M.FRAME_PAD_X
  -- A short plot may fit the text without the normal button padding.
  local labelled=text_h+2*theme.scale<=h and label_w<=room
  local w=labelled and label_w or h
  local x,y=area.x+(area.w-w)/2,area.y+(area.h-h)/2
  for _,card in ipairs(cards) do
    if intersects(x,y,w,h,card) then return end
  end
  return {x=x,y=y,w=w,h=h,x0=x,y0=y,x1=x+w,y1=y+h,label=labelled and label or nil}
end

function ui.plan(ctx,state,frames,area,status_rect)
  local result={blocked={},frames=frames,cards={},
    output_notice=state.analysis_preview_output_notice
      or state.analysis_output_reason~='automatic_fallback' and state.analysis_output_notice or nil}
  local profile=state.analysis_output_profile or state.analysis_channels
  -- Unknown roles never need the old local layout hint, even in a numeric fallback.
  result.channel_layout=profile and profile.known==false or nil
  local groups,visible={},{}
  for _,frame in ipairs(frames) do
    if frame.w>=1 and frame.h>=1 then visible[frame.id]=frame end
  end
  local stereo_message=visible.stereo and notices.describe(state,'stereo')
  local surround_setup=stereo_message and stereo_message.setup
  local meter_frame=visible.loudness
  local meter_message=meter_frame and meter_frame.setup_rect and notices.describe(state,'loudness')
  local visible_setup=surround_setup or meter_message and meter_message.setup
  local function add(id,paint,frame)
    local message=notices.describe(state,id)
    if not message then return end
    if message.save_failure and visible_setup then return end
    if message.setup then
      -- Only an actual surround field or LUFS meter can ask for speaker roles.
      if not frame or id=='loudness' and (surround_setup or not frame.setup_rect) then
        message=notices.layout_save_failure(state)
        if not message or visible_setup then return end
      elseif id=='loudness' then
        message=setmetatable({compact_setup=true},{__index=message})
      end
    end
    local group
    for _,card in ipairs(groups) do
      if same_message(message,card.message) then group=card; break end
    end
    if not group then
      group={message=message,blocked={},targets={},id=id,setup_rect=message.setup and frame.setup_rect,
        setup_button_rect=message.setup and frame.setup_button_rect}
      groups[#groups+1]=group
    end
    if paint then
      group.targets[id]=true
      if not message.setup and not message.nonblocking then
        group.blocked[id]=true
        result.blocked[id]=true
      end
    end
  end
  for _,frame in ipairs(frames) do
    if frame.w>=1 and frame.h>=1 then
      add(frame.id,true,frame)
    end
  end
  if area and area.enabled then
    for _,id in ipairs(area.enabled) do
      if not visible[id] then add(id,false) end
    end
  end
  if #groups==0 then return result end
  local alerts={}
  local M=theme.metrics
  local button_h=status_panel.minimum_height(ctx)
  for _,card in ipairs(groups) do
    local a=card.setup_rect or layout.anchor(frames,card.targets)
    if a then
      local pad=math.min(M.ANALYSIS_NOTICE_PAD,a.w/8,a.h/8)
      local inset=a.h<button_h and 0 or 2*pad
      card.w=math.min(M.ANALYSIS_NOTICE_W,a.w-inset)
      card.h=math.min(a.h,status_panel.measure(ctx,card.message,card.w-2*pad)+2*pad)
      card.x,card.y=a.x+(a.w-card.w)/2,a.y+(a.h-card.h)/2
      card.x0,card.y0,card.x1,card.y1=card.x,card.y,card.x+card.w,card.y+card.h
      card.pad=math.min(pad,math.max(0,(card.h-button_h)/2))
    end
    if card.message.compact_setup or area and (not a or status_rect and intersects(card.x,card.y,card.w,card.h,status_rect)
      or not status_panel.compact_fits(ctx,card.message,
      card.w-2*card.pad,card.h-2*card.pad)) then
      alerts[#alerts+1]=card
    elseif a then
      result.cards[#result.cards+1]=card
    end
  end
  if #alerts>0 then
    local affected={}
    for _,alert in ipairs(alerts) do
      for id in pairs(alert.targets) do affected[id]=true end
    end
    local preferred=#alerts==1 and alerts[1].setup_rect or layout.anchor(frames,affected)
    local blockers={status_rect}
    for _,card in ipairs(result.cards) do blockers[#blockers+1]=card end
    local meter_setup=#alerts==1 and alerts[1].message.compact_setup
    local setup_only=meter_setup or #alerts==1 and alerts[1].message.setup and not state.analysis_channel_save_error
    local trigger
    if meter_setup and preferred then
      trigger=setup_meter_trigger(ctx,alerts[1].setup_button_rect or preferred,blockers,alerts[1].message)
      if not trigger and state.analysis_channel_save_error then
        -- Save recovery belongs to unavailable LUFS rather than working channels.
        alerts[1].message=notices.layout_save_failure(state)
        trigger=compact_trigger(preferred,blockers,button_h)
      end
    elseif preferred then trigger=compact_trigger(preferred,blockers,button_h) end
    if not trigger and not setup_only then trigger=compact_trigger(area,blockers,button_h) end
    if not trigger and not setup_only then
      result.cards,alerts={},groups
      preferred=layout.anchor(frames,affected)
      blockers={status_rect}
      trigger=preferred and compact_trigger(preferred,blockers,button_h)
        or compact_trigger(area,blockers,button_h)
    end
    if not trigger and status_rect and not setup_only then
      -- A wide status card can leave only its bottom margin free in a short dock.
      local y=status_rect.y+status_rect.h
      local h=area.y+area.h-y
      if h>=1 then trigger=compact_trigger({x=area.x,y=y,w=area.w,h=h},{},button_h) end
    end
    if trigger then
      trigger.alerts=alerts
      result.compact=trigger
    end
  end
  result.channel_layout=result.channel_layout or has_channel_layout(result.cards)
    or result.compact~=nil and has_channel_layout(result.compact.alerts)
  return result
end

function ui.hovered(ctx,plan)
  local r=plan.compact
  if r and reaper.ImGui_IsMouseHoveringRect(ctx,r.x0,r.y0,r.x1,r.y1) then return true end
  for _,card in ipairs(plan.cards) do
    if reaper.ImGui_IsMouseHoveringRect(ctx,card.x,card.y,card.x+card.w,card.y+card.h) then
      return true
    end
  end
  return false
end

function ui.input(ctx,plan)
  local r=plan.compact
  if not r then return end
  -- Claim the click before a neighbouring plot can submit a full-size gear.
  local R=reaper
  local old_x,old_y=R.ImGui_GetCursorScreenPos(ctx)
  R.ImGui_SetCursorScreenPos(ctx,r.x,r.y)
  local shallow=r.label and r.h<status_panel.minimum_height(ctx)
  if shallow then
    local _,text_h=R.ImGui_CalcTextSize(ctx,r.label)
    R.ImGui_PushStyleVar(ctx,R.ImGui_StyleVar_FramePadding(),theme.metrics.FRAME_PAD_X,
      math.max(0,(r.h-text_h)/2))
  end
  local clicked=widgets.panel_button_frame(ctx,(r.label or '')..'##analysis_recovery_button',r.w,r.h,R.ImGui_IsPopupOpen(ctx,recovery_popup))
  if shallow then R.ImGui_PopStyleVar(ctx) end
  if clicked then
    R.ImGui_OpenPopup(ctx,recovery_popup)
  end
  r.hovered,r.held=R.ImGui_IsItemHovered(ctx),R.ImGui_IsItemActive(ctx)
  R.ImGui_SetCursorScreenPos(ctx,old_x,old_y)
end

local function draw_compact(ctx,r)
  local R,T=reaper,theme.tokens
  local open=R.ImGui_IsPopupOpen(ctx,recovery_popup)
  local dl=R.ImGui_GetWindowDrawList(ctx)
  local radius=theme.metrics.ANALYSIS_CARD_RADIUS
  local fill=open and (r.held and T.ACTIVE_CONTROL_HELD or r.hovered and T.ACTIVE_CONTROL_HOVER or T.ACTIVE_CONTROL_FILL)
    or (r.held and T.FILL_PRIMARY or r.hovered and T.FILL_SECONDARY or T.FILL_TERTIARY)
  R.ImGui_DrawList_AddRectFilled(dl,r.x0,r.y0,r.x1,r.y1,T.BG_POPUP,radius)
  R.ImGui_DrawList_AddRectFilled(dl,r.x0,r.y0,r.x1,r.y1,fill,radius)
  R.ImGui_DrawList_AddRect(dl,r.x0,r.y0,r.x1,r.y1,open and T.ACTIVE_CONTROL_BORDER or T.STROKE_SECONDARY,radius)
  local cx,cy=r.x+r.w/2,r.y+r.h/2
  local mark=math.min(r.w,r.h)*.4
  local colour,setup=T.TEXT_SECONDARY,true
  for _,card in ipairs(r.alerts) do
    if not card.message.setup then
      setup=false
      if not card.message.pending then colour=T.DANGER_RED end
    end
  end
  if r.label then
    local text_w,text_h=R.ImGui_CalcTextSize(ctx,r.label)
    local alpha=R.ImGui_GetStyleVar(ctx,R.ImGui_StyleVar_Alpha())
    R.ImGui_DrawList_AddText(dl,r.x+(r.w-text_w)/2,r.y+(r.h-text_h)/2,
      theme.fade(T.TEXT_SECONDARY,alpha),r.label)
  elseif setup then
    -- A neutral speaker-layout mark keeps first-time setup distinct from faults.
    R.ImGui_DrawList_AddRect(dl,cx-mark,cy-mark,cx+mark,cy+mark,colour,theme.scale)
    R.ImGui_DrawList_AddLine(dl,cx-mark,cy,cx+mark,cy,colour,theme.scale)
    R.ImGui_DrawList_AddLine(dl,cx,cy-mark,cx,cy+mark,colour,theme.scale)
  else
    R.ImGui_DrawList_AddTriangle(dl,cx,cy-mark,cx-mark,cy+mark,cx+mark,cy+mark,colour,theme.scale)
    R.ImGui_DrawList_AddLine(dl,cx,cy-mark*.25,cx,cy+mark*.24,colour,theme.scale)
    R.ImGui_DrawList_AddCircleFilled(dl,cx,cy+mark*.58,theme.scale*.55,colour)
  end
  local tip=#r.alerts==1 and r.alerts[1].message.title or 'Analysis Warnings'
  tips.show(ctx,r.hovered and not open and not r.label,tip,'analysis_recovery',tips.rect(r.x,r.y,r.w,r.h))
  if not open then return end
  local widest,width='',0
  for _,card in ipairs(r.alerts) do
    local message=card.message
    for _,line in ipairs({message.title,message.detail,message.recommendation or '',
        message.button or '',message.secondary_button or ''}) do
      local tw=R.ImGui_CalcTextSize(ctx,line)
      if tw>width then widest,width=line,tw end
    end
  end
  popups.fit_width(ctx,widest)
  if not R.ImGui_BeginPopup(ctx,recovery_popup) then return end
  local action
  for i,card in ipairs(r.alerts) do
    local message=card.message
    if i>1 then R.ImGui_Separator(ctx) end
    local x,y=R.ImGui_GetCursorScreenPos(ctx)
    local width=R.ImGui_GetContentRegionAvail(ctx)
    width=math.max(1,width)
    local full=setmetatable({compact_setup=false},{__index=message})
    local height=status_panel.measure(ctx,full,width)
    local selected=status_panel.draw(ctx,nil,x,y,width,height,full)
    R.ImGui_SetCursorScreenPos(ctx,x,y)
    R.ImGui_Dummy(ctx,width,height)
    if selected then
      action=selected
      R.ImGui_CloseCurrentPopup(ctx)
    end
  end
  R.ImGui_EndPopup(ctx)
  return action
end

local function draw_output_notice(ctx,plan)
  local R,T,M=reaper,theme.tokens,theme.metrics
  local pad, inset=M.ITEM_SPACING_X,M.WINDOW_PAD
  local control=R.ImGui_GetFrameHeight(ctx)
  local small=theme.push_small_font(ctx)
  local text=plan.output_notice
  local text_w,text_h=R.ImGui_CalcTextSize(ctx,text)
  local anchor,room
  for _,id in ipairs(OUTPUT_PANELS) do
    for _,frame in ipairs(plan.frames) do
      if frame.id==id and not plan.blocked[id] and frame.h>=text_h+2*inset then
        -- Keep clear of the scope buttons and Spectrum's level ruler.
        local corner=id=='stereo' and 2*control+pad
          or id=='spectrum' and M.SPECTRUM_LEVEL_W+control+pad or control
        local available=frame.w-2*(inset+pad)-corner
        if available>0 and (not room or available>room) then anchor,room=frame,available end
      end
    end
    if room and room>=text_w then break end
  end
  if anchor then
    local shown=room<text_w and widgets.ellipsize(ctx,text,room) or text
    local w=R.ImGui_CalcTextSize(ctx,shown)+2*pad
    local x,y=anchor.x+inset,anchor.y+inset
    if anchor.id=='spectrum' then x=anchor.x+anchor.w-M.SPECTRUM_LEVEL_W-inset-w end
    local dl=R.ImGui_GetWindowDrawList(ctx)
    R.ImGui_DrawList_AddRectFilled(dl,x,y,x+w,y+text_h+pad,T.BG_POPUP,M.CLOSE_ROUNDING)
    R.ImGui_DrawList_AddText(dl,x+pad,y+pad/2,T.TEXT_SECONDARY,shown)
    if shown~=text then
      tips.show(ctx,R.ImGui_IsMouseHoveringRect(ctx,x,y,x+w,y+text_h+pad),text,'analysis_output_notice',tips.rect(x,y,w,text_h+pad))
    end
  end
  if small then R.ImGui_PopFont(ctx) end
end


function ui.draw(ctx,plan)
  if plan.output_notice then draw_output_notice(ctx,plan) end
  if #plan.cards==0 and not plan.compact and not next(plan.blocked) then return end
  local R,T=reaper,theme.tokens
  local dl=R.ImGui_GetWindowDrawList(ctx)
  local old_x,old_y=R.ImGui_GetCursorScreenPos(ctx)
  for _,r in ipairs(plan.frames) do
    if plan.blocked[r.id] then
      R.ImGui_DrawList_AddRectFilled(dl,r.x,r.y,r.x+r.w,r.y+r.h,T.ANALYSIS_PAUSED_DIM,3*theme.scale)
    end
  end
  local action
  local radius=4*theme.scale
  for _,card in ipairs(plan.cards) do
    local x,y,w,h,pad=card.x,card.y,card.w,card.h,card.pad
    R.ImGui_DrawList_AddRectFilled(dl,x,y,x+w,y+h,T.BG_POPUP,radius)
    R.ImGui_DrawList_AddRect(dl,x,y,x+w,y+h,T.STROKE_PRIMARY,radius)
    R.ImGui_PushID(ctx,'shared_analysis_notice_'..card.id..'_'..card.message.title)
    local selected=status_panel.draw(ctx,nil,x+pad,y+pad,w-2*pad,h-2*pad,card.message)
    action=action or selected
    R.ImGui_PopID(ctx)
  end
  if plan.compact then
    local selected=draw_compact(ctx,plan.compact)
    action=action or selected
  end
  R.ImGui_SetCursorScreenPos(ctx,old_x,old_y)
  R.ImGui_Dummy(ctx,0,0)
  return action
end
return ui
