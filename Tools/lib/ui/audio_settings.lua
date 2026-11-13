local theme=require('ui.theme')
local widgets=require('ui.widgets')
local channels=require('ui.analysis_channels')
local notice=require('core.analysis_notice')
local audio={}

local function group(ctx,id,title,draw)
  local opened,child=widgets.begin_settings_group(ctx,'audio_'..id,title,false)
  local action
  if opened then action=draw() end
  widgets.end_settings_group(ctx,child)
  return action
end

local function draw_notice(ctx,id,description)
  if not description or not description.detail then return end
  return group(ctx,id,description.title,function()
    reaper.ImGui_TextWrapped(ctx,description.detail)
    if description.button and reaper.ImGui_Button(ctx,description.button) then
      return description.action_data or {type=description.action}
    end
  end)
end

local function draw_analysis_warning(ctx,state)
  if state.analysis_meter_start_error or state.analysis_audio_suspended and state.analysis_audio_pause_notice then
    return draw_notice(ctx,'analysis_warning',notice.channel(state))
  end
  if not state.analysis_channel_blocked or not state.analysis_channel_route_warning then return end
  local description=notice.routing(state)
  if description and description.detail then
    group(ctx,'analysis_warning',description.title,function() reaper.ImGui_TextWrapped(ctx,description.detail) end)
  end
end

local function hide_unused_scrollbar(ctx)
  local R=reaper
  if R.ImGui_GetScrollMaxY(ctx)>0 then return end
  local x,y=R.ImGui_GetWindowPos(ctx)
  local width,height=R.ImGui_GetWindowSize(ctx)
  local rail=R.ImGui_GetStyleVar(ctx,R.ImGui_StyleVar_ScrollbarSize())
  local alpha=R.ImGui_GetStyleVar(ctx,R.ImGui_StyleVar_Alpha())
  local dl=R.ImGui_GetWindowDrawList(ctx)
  R.ImGui_DrawList_PushClipRect(dl,x+width-rail,y,x+width,y+height,false)
  R.ImGui_DrawList_AddRectFilled(dl,x+width-rail,y,x+width,y+height,
    theme.fade(theme.tokens.BG_WINDOW,alpha))
  R.ImGui_DrawList_PopClipRect(dl)
end

function audio.draw(ctx,state)
  local R=reaper
  -- The whole Audio page scrolls together so the speaker card cannot crowd out settings.
  R.ImGui_PushStyleVar(ctx,R.ImGui_StyleVar_WindowPadding(),0,0)
  local opened=R.ImGui_BeginChild(ctx,'audio_settings_details',0,0,0,
    R.ImGui_WindowFlags_AlwaysVerticalScrollbar())
  R.ImGui_PopStyleVar(ctx)
  if not opened then return end
  hide_unused_scrollbar(ctx)
  local action=channels.draw_content(ctx,state)
  local profile=state.analysis_output_profile or state.analysis_channels
  local layout=state.analysis_channels
  if layout and not layout.known and not state.analysis_channel_error then
    local partial=false
    for _,role in ipairs(layout.roles or {}) do if role~='unknown' then partial=true; break end end
    if partial then
      group(ctx,'speaker_assignments','Finish Speaker Layout',function()
        R.ImGui_TextWrapped(ctx,'Assign the remaining channels in Advanced to enable the surround field and LUFS readings.')
      end)
    end
  end
  if state.analysis_channel_limit_warning then R.ImGui_TextWrapped(ctx,state.analysis_channel_limit_warning) end
  if state.analysis_output_notice then R.ImGui_TextWrapped(ctx,state.analysis_output_notice) end
  if state.analysis_preview_output_notice then R.ImGui_TextWrapped(ctx,state.analysis_preview_output_notice) end
  action=draw_notice(ctx,'legacy_cleanup',notice.legacy_cleanup(state)) or action
  action=draw_notice(ctx,'layout_save_failure',notice.layout_save_failure(state)) or action
  action=draw_analysis_warning(ctx,state) or action
  if profile then
    action=widgets.settings_foldout(ctx,'audio_advanced','Advanced',function()
      local output=channels.draw_outputs(ctx,state)
      return channels.draw_assignments(ctx,state) or output
    end) or action
  end
  R.ImGui_EndChild(ctx)
  return action
end
return audio
