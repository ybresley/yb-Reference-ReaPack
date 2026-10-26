-- Reference View reserves the transport first; pictures fill the remaining area.
local theme = require('ui.theme')
local waveform = require('ui.waveform')
local spectrum = require('ui.spectrum')
local stereo = require('ui.stereo')
local panels = require('ui.reference_panels')
local meter_regions = require('core.reference_panels')
local meter_panel = require('ui.meter_panel')
local surface_layout = require('core.panel_surface_layout')
local analysis_panel = require('ui.analysis_panel')
local relocation_notice = require('ui.relocation_notice')
local transport = require('ui.transport')
local dropzone = require('ui.dropzone')
local walkthrough = require('core.walkthrough')
local walkthrough_ui = require('ui.walkthrough')
local M = theme.metrics
local window = {}

local HAS_RECT_HOVER = reaper.ImGui_IsMouseHoveringRect ~= nil
local HAS_WIN_HOVER_BLOCKED = reaper.ImGui_IsWindowHovered ~= nil
  and reaper.ImGui_HoveredFlags_AllowWhenBlockedByActiveItem ~= nil

local function pin_drop_target(ctx, state, x0, y0, x1, y1)
  local drag = state.drag
  if not drag or not HAS_RECT_HOVER then return nil end
  local ps = state.pins
  if ps and ps.load_error then return nil end
  if type(drag.sound_id) == 'string' and drag.sound_id:sub(1, 1) == 'p' then return nil end
  if HAS_WIN_HOVER_BLOCKED and not reaper.ImGui_IsWindowHovered(ctx,
      reaper.ImGui_HoveredFlags_AllowWhenBlockedByActiveItem()) then return nil end
  if not reaper.ImGui_IsMouseHoveringRect(ctx, x0, y0, x1, y1) then return nil end
  dropzone.draw_drop_rect(ctx, x0, y0, x1, y1, 'Pin To This Project')
  dropzone.show_hand_cursor(ctx)
  if reaper.ImGui_IsMouseReleased(ctx, 0) then
    return {type='pin_sounds', ids=drag.sound_ids or {drag.sound_id},
      progress_view='main', wins_release=true}
  end
end

function window.draw(ctx, state, res)
  local action, wave_id, wave_cols
  local analysis_x0, analysis_y0, analysis_x1, analysis_y1
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local width, height = reaper.ImGui_GetContentRegionAvail(ctx)
  action = dropzone.file_drop_over_rect(ctx, state, x, y, x+width, y+height,
    {action_type='import_and_pin', label='Add to Library and Pin To This Project'})
  action = action or pin_drop_target(ctx, state, x, y, x+width, y+height)

  local spacing = select(2, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing()))
  local bar_h = transport.measure(ctx, width, state)
  local outer_x, outer_y, outer_width = x, y, width
  local regions
  local picture_h = math.max(0, height-bar_h-spacing)
  local prototype = state.layout_prototype and require('ui.layout_prototype') or nil
  if prototype then
    regions = {bar_y=picture_h+(picture_h>0 and spacing or 0),content_h=picture_h}
  elseif state.metering then
    regions = meter_regions.measure(width,height,bar_h,spacing,theme.scale,
      state.metering.prefs.view,M.SPECTRUM_PANE_MIN_W*2+M.SPECTRUM_SPLIT_GAP)
    local pictures = regions.pictures
    x,y = outer_x+(pictures and pictures.x or 0),outer_y+(pictures and pictures.y or 0)
    width,picture_h = pictures and pictures.w or width,pictures and pictures.h or 0
  end
  local geometry
  if prototype then
    geometry = prototype.measure(ctx, state, width, picture_h)
  else
    geometry = panels.measure(width, picture_h,
      state.reference_panels, state.stereo_view,
      state.stereo_preferences and state.stereo_preferences.show_correlation)
  end
  state.layout_prototype_geometry = prototype and geometry or nil
  state.reference_panel_mode = geometry.intended
  local display_frames, prototype_meter_geometry
  if prototype then
    local ruler_users={waveform=true,spectrum=true,loudness=true}
    display_frames = surface_layout.measure(geometry.panels, 0,
      M.RULER_H, M.WAVE_MIN_H,ruler_users)
    local meter_frame, meter_splits
    if state.metering then
      for _, pane in ipairs(geometry.panels) do
        if pane.id == 'loudness' then
          local variant = state.layout_prototype.active
          meter_splits = state.layout_meter_splits and state.layout_meter_splits[variant]
          meter_frame=pane
          prototype_meter_geometry = meter_panel.measure(pane.w, pane.h,
            state.metering.prefs, nil, meter_splits, display_frames[pane.id].footer_height,ctx)
          ruler_users.loudness=not prototype_meter_geometry.numeric
          break
        end
      end
    end
    display_frames = surface_layout.measure(geometry.panels, 0,
      M.RULER_H, M.WAVE_MIN_H,ruler_users)
    if meter_frame then
      prototype_meter_geometry=meter_panel.measure(meter_frame.w,meter_frame.h,
        state.metering.prefs,nil,meter_splits,display_frames.loudness.footer_height,ctx)
      prototype_meter_geometry.surface_painted=true
    end
  end
  local stop = walkthrough.current(state.walkthrough)
  local panel_action, input = (prototype or panels).input(ctx, state, geometry, x, y, width)
  action = action or panel_action
  if input.blocked then
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_DisabledAlpha(), 1)
    reaper.ImGui_BeginDisabled(ctx)
  end

  local spectrum_visible = false
  for _, pane in ipairs(geometry.panels) do
    local display = display_frames and display_frames[pane.id] or pane
    if display.w < 1 or display.h < 1 then goto next_panel end
    local px, py = x+display.x, y+display.y
    local exclusion = input.exclusions[pane.id]
    reaper.ImGui_SetCursorScreenPos(ctx, px, py)
    reaper.ImGui_PushID(ctx, 'reference_'..pane.id)
    if prototype and geometry.temporary then
      -- Compressed panels keep drawing and mouse input inside their own frame.
      reaper.ImGui_PushClipRect(ctx, x+pane.x, y+pane.y,
        x+pane.x+pane.w, y+pane.y+pane.h, true)
    end
    if prototype then
      -- All four surfaces use their complete frame; scales stay inside that edge.
      reaper.ImGui_DrawList_AddRectFilled(reaper.ImGui_GetWindowDrawList(ctx),
        px,py,px+display.w,py+display.h-(display.footer_height or 0),
        theme.tokens.STEREO_BG,3*theme.scale)
    end
    if pane.id == 'waveform' then
      local ruler = display.h-M.RULER_H >= M.WAVE_MIN_H
      if display.footer_height ~= nil then ruler = display.footer_height > 0 end
      local picture_h = ruler and display.h-M.RULER_H or display.h
      local wave_action, wx0, wy0, wx1, wy1
      wave_action, wave_id, wave_cols, wx0, wy0, wx1, wy1 = waveform.draw(ctx, state, picture_h,
        {id=state.selected_id, waveform=state.waveform, slot='main', width=display.w,
          view=state.wave_view, detail=state.wave_detail, navigation=true,
          modifiers=state.mouse_modifiers,
          trim_db=state.selected and state.selected.trim_db or 0,
          ruler=ruler, background_painted=prototype~=nil,
          duration=state.selected and state.selected.duration or nil,
          span_edit=true, input_exclusion=exclusion,
          span_start=state.selected and state.selected.span_start or nil,
          span_end=state.selected and state.selected.span_end or nil})
      action = action or wave_action
      analysis_x0, analysis_y0, analysis_x1, analysis_y1 = wx0, wy0, wx1, wy1
      if exclusion and analysis_y0 then analysis_y0 = math.max(analysis_y0, exclusion.y1) end
    elseif pane.id == 'spectrum' then
      spectrum_visible = true
      local spectrum_action = spectrum.draw(ctx, state, display.w, display.h, res, exclusion,
        display.footer_height,prototype~=nil)
      action = action or spectrum_action
      walkthrough_ui.note_rect(ctx, state.walkthrough, 'spectrum', px, py,
        px+display.w, py+display.h)
    elseif pane.id == 'stereo' then
      local picture_h = display.h - (display.footer_height or 0)
      local background_x = x + (pane.background_x or display.x)
      local background_w = pane.background_w or display.w
      reaper.ImGui_DrawList_AddRectFilled(reaper.ImGui_GetWindowDrawList(ctx),
        background_x, py, background_x + background_w, py + picture_h,
        theme.tokens.STEREO_BG, 3 * theme.scale)
      local stereo_action = stereo.draw(ctx, state, display.w, picture_h, res, exclusion,
        background_x, background_w)
      action = action or stereo_action
    elseif pane.id == 'loudness' then
      local meter_action, mx0, my0, mx1, my1 = meter_panel.draw(ctx, state, res,
        px, py, pane.w, pane.h, prototype_meter_geometry, display.footer_height)
      action = action or meter_action
      if not analysis_x0 then
        analysis_x0, analysis_y0, analysis_x1, analysis_y1 = mx0, my0, mx1, my1
      end
    end
    if prototype and geometry.temporary then reaper.ImGui_PopClipRect(ctx) end
    reaper.ImGui_PopID(ctx)
    if not analysis_x0 then
      analysis_x0, analysis_y0, analysis_x1, analysis_y1 = px, exclusion and exclusion.y1 or py,
        px+display.w, py+display.h
    end
    ::next_panel::
  end
  if not spectrum_visible then spectrum.clear_handle_focus() end
  if input.blocked then
    reaper.ImGui_EndDisabled(ctx)
    reaper.ImGui_PopStyleVar(ctx)
  end
  (prototype or panels).paint(ctx, geometry, input, x, y, res,
    type(stop)=='table' and stop.id=='pin')
  if regions and regions.meters then
    local r=regions.meters
    local meter_geometry
    local first=geometry.panels[1]
    if regions.mode=='horizontal' and geometry.mode=='vertical' and first and first.id=='waveform' then
      local variant=state.layout_prototype and state.layout_prototype.active or 'default'
      local splits=state.layout_meter_splits and state.layout_meter_splits[variant]
      meter_geometry=meter_panel.measure(r.w,r.h,state.metering.prefs,first.h,splits,nil,ctx)
    end
    local meter_action,mx0,my0,mx1,my1=meter_panel.draw(ctx,state,res,
      outer_x+r.x,outer_y+r.y,r.w,r.h,meter_geometry)
    action=action or meter_action
    if not analysis_x0 then
      analysis_x0,analysis_y0,analysis_x1,analysis_y1=mx0,my0,mx1,my1
    end
  end
  if analysis_panel.is_visible(state, 'main', dropzone.file_drag_active()) then
    analysis_panel.draw(ctx, state.analysis_progress, analysis_x0, analysis_y0, analysis_x1, analysis_y1)
  end
  local bar_y = regions and regions.bar_y or (geometry.visual_h > 0 and geometry.visual_h+spacing or 0)
  reaper.ImGui_SetCursorScreenPos(ctx, outer_x, outer_y+bar_y)
  local bar_action = transport.draw(ctx, state, res)
  action = action or bar_action
  local notice_y = not prototype and geometry.temporary and geometry.count>0
    and y+reaper.ImGui_GetFrameHeight(ctx)+M.WINDOW_PAD+spacing or outer_y
  relocation_notice.draw(ctx, state, outer_x, notice_y, outer_x+outer_width,
    outer_y+(regions and regions.content_h or geometry.visual_h))
  reaper.ImGui_Dummy(ctx, 0, 0)
  return action, wave_id, wave_cols
end

return window
