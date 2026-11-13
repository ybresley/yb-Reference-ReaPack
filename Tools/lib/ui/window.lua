-- Reference View panels. Their controls sit in the sidebar column beside them.
local theme = require('ui.theme')
local spectrum = require('ui.spectrum')
local stereo = require('ui.stereo')
local panels = require('ui.reference_panels')
local meter_regions = require('core.reference_panels')
local meter_panel = require('ui.meter_panel')
local surface_layout = require('core.panel_surface_layout')
local analysis_panel = require('ui.analysis_panel')
local analysis_notice = require('ui.analysis_notice')
local relocation_notice = require('ui.relocation_notice')
local status_card = require('ui.status_card')
local leftover_panel = require('ui.leftover_panel')
local actions = require('core.actions')
local dropzone = require('ui.dropzone')
local walkthrough = require('core.walkthrough')
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

-- Files dropped anywhere on the Reference View are added and pinned; Library
-- sounds are pinned. The card is its own window above the panels, so it calls
-- this over its own area too.
function window.drop_targets(ctx, state, x0, y0, x1, y1)
  return dropzone.file_drop_over_rect(ctx, state, x0, y0, x1, y1,
      {action_type='import_and_pin', label='Add to Library and Pin To This Project'})
    or pin_drop_target(ctx, state, x0, y0, x1, y1)
end

-- card: the Reference card at this area's left edge, when the panels share the
-- area with it ({width, natural, minimum}, core/layout_prototype.lua's
-- measure_with_card). Returns the action and the card's height.
function window.draw(ctx, state, res, card)
  local action
  local analysis_x0, analysis_y0, analysis_x1, analysis_y1
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local width, height = reaper.ImGui_GetContentRegionAvail(ctx)
  local prototype = state.layout_prototype and require('ui.layout_prototype') or nil
  -- The card covers its corner of this area and takes the drops there.
  action = window.drop_targets(ctx, state, x, y, x+width, y+height)
  local inset = card and card.width or 0
  -- Without the arrangeable panels the card keeps a full-height column.
  if card and not prototype then x, width = x+inset, width-inset end

  local spacing = select(2, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing()))
  -- The controls live in the sidebar column, so the panels take the full height.
  local outer_x, outer_y, outer_width = x, y, width
  local regions
  local picture_h = math.max(0, height)
  if prototype then
    regions = {content_h=picture_h}
  elseif state.metering then
    regions = meter_regions.measure(width,height,0,0,theme.scale,
      state.metering.prefs.view,M.SPECTRUM_PANE_MIN_W*2+M.SPECTRUM_SPLIT_GAP)
    local pictures = regions.pictures
    x,y = outer_x+(pictures and pictures.x or 0),outer_y+(pictures and pictures.y or 0)
    width,picture_h = pictures and pictures.w or width,pictures and pictures.h or 0
  end
  local geometry
  if prototype then
    geometry = prototype.measure(ctx, state, width, picture_h, card)
  else
    geometry = panels.measure(width, picture_h,
      state.reference_panels, state.stereo_view,
      state.stereo_preferences and state.stereo_preferences.show_correlation)
  end
  state.layout_prototype_geometry = prototype and geometry or nil
  state.reference_panel_mode = geometry.intended
  local display_frames, prototype_meter_geometry
  local capture_profile=state.preview_analysis_profile or state.analysis_output_profile or state.analysis_channels
  if prototype then
    local ruler_users={spectrum=true,loudness=true}
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
            state.metering.prefs, nil, meter_splits, display_frames[pane.id].footer_height,ctx,capture_profile)
          ruler_users.loudness=not prototype_meter_geometry.numeric
          break
        end
      end
    end
    display_frames = surface_layout.measure(geometry.panels, 0,
      M.RULER_H, M.WAVE_MIN_H,ruler_users)
    if meter_frame then
      prototype_meter_geometry=meter_panel.measure(meter_frame.w,meter_frame.h,
        state.metering.prefs,nil,meter_splits,display_frames.loudness.footer_height,ctx,capture_profile)
      prototype_meter_geometry.surface_painted=true
    end
  end
  local stop = walkthrough.current(state.walkthrough)
  -- The message card sits on the panels' bottom edge, clear of the Reference
  -- card's column like the relocation notice below.
  local panels_x = outer_x + (prototype and inset or 0)
  local panels_bottom = outer_y + (regions and regions.content_h or geometry.visual_h)
  local status_handle, status_action = status_card.prepare(ctx, state, 'main',
    panels_x, outer_y, outer_x+outer_width, panels_bottom - M.WINDOW_PAD)
  action = action or status_action
  local notice_frames,stereo_frame={}
  local function with_setup_region(frame,meter_geometry)
    frame.setup_rect,frame.setup_button_rect=meter_panel.setup_regions(meter_geometry,frame.x,frame.y)
    return frame
  end
  for _,pane in ipairs(geometry.panels) do
    local display=display_frames and display_frames[pane.id] or pane
    local frame_x=pane.id=='stereo' and pane.background_x or display.x
    local frame_w=pane.id=='stereo' and pane.background_w or display.w
    local frame={id=pane.id,x=x+(frame_x or display.x),y=y+display.y,
      w=frame_w or display.w,h=math.max(0,display.h-(display.footer_height or 0))}
    if pane.id=='loudness' then with_setup_region(frame,prototype_meter_geometry) end
    notice_frames[#notice_frames+1]=frame
    if pane.id=='stereo' then stereo_frame=frame end
  end
  local legacy_meter_geometry
  if regions and regions.meters then
    local r=regions.meters
    local splits=state.layout_meter_splits and state.layout_meter_splits.default
    legacy_meter_geometry=meter_panel.measure(r.w,r.h,state.metering.prefs,nil,splits,nil,ctx,capture_profile)
    notice_frames[#notice_frames+1]=with_setup_region(
      {id='loudness',x=outer_x+r.x,y=outer_y+r.y,w=r.w,h=r.h},legacy_meter_geometry)
  end
  local analysis_h=panels_bottom-outer_y
  local analysis_w=outer_x+outer_width-panels_x
  local notice_area=analysis_h>=1 and analysis_w>=1
    and {x=panels_x,y=outer_y,w=analysis_w,h=analysis_h} or nil
  if notice_area and analysis_h<reaper.ImGui_GetFrameHeight(ctx) then
    local view=state.metering and state.metering.prefs.view
    local enabled=prototype and geometry.enabled or {}
    if not prototype then
      if view~='meters' and state.reference_panels then
        for _,id in ipairs(state.reference_panels.enabled) do enabled[#enabled+1]=id end
      end
      if state.metering and view~='pictures' then enabled[#enabled+1]='loudness' end
    end
    notice_area.enabled=enabled
  end
  local occupied=status_handle and {x=status_handle.x0,y=status_handle.y0,
    w=status_handle.x1-status_handle.x0,h=status_handle.y1-status_handle.y0}
  local notice=analysis_notice.plan(ctx,state,notice_frames,notice_area,occupied)
  analysis_notice.input(ctx,notice)
  local panel_action, input
  if analysis_notice.hovered(ctx,notice) and not reaper.ImGui_IsAnyItemActive(ctx) then
    -- A gap can sit under a card, but a resize that already began may finish.
    input={blocked=false,exclusions={}}
  else panel_action,input=(prototype or panels).input(ctx,state,geometry,x,y,width) end
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
    local divider_exclusion = input.exclusions[pane.id]
    local exclusion = divider_exclusion or notice.compact
    if not exclusion then
      for _,card in ipairs(notice.cards) do
        if card.targets[pane.id] then exclusion=card; break end
      end
    end
    reaper.ImGui_SetCursorScreenPos(ctx, px, py)
    reaper.ImGui_PushID(ctx, 'reference_'..pane.id)
    if prototype and geometry.temporary then
      -- Compressed panels keep drawing and mouse input inside their own frame.
      reaper.ImGui_PushClipRect(ctx, x+pane.x, y+pane.y,
        x+pane.x+pane.w, y+pane.y+pane.h, true)
    end
    if prototype then
      -- Panels use their complete frame; scales stay inside that edge.
      reaper.ImGui_DrawList_AddRectFilled(reaper.ImGui_GetWindowDrawList(ctx),
        px,py,px+display.w,py+display.h-(display.footer_height or 0),
        theme.tokens.STEREO_BG,3*theme.scale)
    end
    if pane.id == 'spectrum' then
      spectrum_visible = true
      local spectrum_action = spectrum.draw(ctx, state, display.w, display.h, res, exclusion,
        display.footer_height,prototype~=nil,notice.blocked.spectrum)
      action = action or spectrum_action
    elseif pane.id == 'stereo' then
      local picture_h = display.h - (display.footer_height or 0)
      local background_x = x + (pane.background_x or display.x)
      local background_w = pane.background_w or display.w
      reaper.ImGui_DrawList_AddRectFilled(reaper.ImGui_GetWindowDrawList(ctx),
        background_x, py, background_x + background_w, py + picture_h,
        theme.tokens.STEREO_BG, 3 * theme.scale)
      local stereo_action = stereo.draw(ctx, state, display.w, picture_h, res, exclusion,
        background_x, background_w,notice.blocked.stereo and {blocked=true,hovered=false} or nil)
      action = action or stereo_action
    elseif pane.id == 'loudness' then
      local meter_action, mx0, my0, mx1, my1 = meter_panel.draw(ctx, state, res,
        px, py, pane.w, pane.h, prototype_meter_geometry, display.footer_height,
        notice.blocked.loudness==true,notice.channel_layout)
      action = action or meter_action
      if not analysis_x0 then
        analysis_x0, analysis_y0, analysis_x1, analysis_y1 = mx0, my0, mx1, my1
      end
    end
    if prototype and geometry.temporary then reaper.ImGui_PopClipRect(ctx) end
    reaper.ImGui_PopID(ctx)
    if not analysis_x0 then
      analysis_x0, analysis_y0, analysis_x1, analysis_y1 = px, divider_exclusion and divider_exclusion.y1 or py,
        px+display.w, py+display.h
    end
    ::next_panel::
  end
  if not spectrum_visible then spectrum.clear_handle_focus() end
  if input.blocked then
    reaper.ImGui_EndDisabled(ctx)
    reaper.ImGui_PopStyleVar(ctx)
  end
  if input.gaps then
    (prototype or panels).paint(ctx, geometry, input, x, y, res,
      type(stop)=='table' and stop.id=='pin')
  end
  if regions and regions.meters then
    local r=regions.meters
    local meter_action,mx0,my0,mx1,my1=meter_panel.draw(ctx,state,res,
      outer_x+r.x,outer_y+r.y,r.w,r.h,legacy_meter_geometry,nil,notice.blocked.loudness==true,notice.channel_layout)
    action=action or meter_action
    if not analysis_x0 then
      analysis_x0,analysis_y0,analysis_x1,analysis_y1=mx0,my0,mx1,my1
    end
  end
  if analysis_panel.is_visible(state, 'main', dropzone.file_drag_active()) then
    analysis_panel.draw(ctx, state.analysis_progress, analysis_x0, analysis_y0, analysis_x1, analysis_y1)
  end
  local warning_action=analysis_notice.draw(ctx,notice)
  if warning_action and warning_action.type=='stereo_settings_open' then
    local anchor=stereo_frame or notice.compact
    if anchor then stereo.open_settings(anchor.x,anchor.y,anchor.w,anchor.h) end
  else action=warning_action or action end
  status_card.paint(ctx, status_handle, leftover_panel.is_open(ctx))
  local leftover_action = leftover_panel.draw(ctx, state, res, status_handle, 'main')
  -- Combined, so closing the panel is never lost to another click that frame.
  action = actions.combine(action, leftover_action)
  local notice_y = not prototype and geometry.temporary and geometry.count>0
    and y+reaper.ImGui_GetFrameHeight(ctx)+M.WINDOW_PAD+spacing or outer_y
  relocation_notice.draw(ctx, state, panels_x, notice_y, outer_x+outer_width, panels_bottom)
  reaper.ImGui_Dummy(ctx, 0, 0)
  return action, prototype and geometry.card_h or height
end

return window
