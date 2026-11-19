-- Divider drags and gap swap buttons around the existing display painters.
local core = require('core.layout_prototype')
local theme = require('ui.theme')
local divider_swaps = require('ui.divider_swaps')
local T, M = theme.tokens, theme.metrics
local prototype = {}
local names = {spectrum='Spectrum', stereo='Scope', loudness='Loudness'}
-- The last shape Auto chose, so resizing near a ratio boundary does not flicker.
local previous_mode
local divider_drag
-- A press on a divider is only a drag once the pointer has really moved, so a
-- plain click never rewrites the saved proportion.
local DIVIDER_DRAG_THRESHOLD = 3
local PANEL_NUMBER = {waveform=1, spectrum=2, stereo=3, loudness=4}

-- Changes whenever the panel order or the visible set does, without building a
-- string on every frame.
local function panel_signature(prefs)
  local signature = 0
  for _, list in ipairs({prefs.order, prefs.enabled}) do
    for _, id in ipairs(list) do signature = signature*5 + (PANEL_NUMBER[id] or 0) end
    signature = signature*5 + #list
  end
  return signature
end

local function action(operation)
  return {type='layout_prototype', operation=operation}
end

-- card: the Reference card sharing this area (ui/window.lua), or nil.
function prototype.measure(ctx, state, width, height, card)
  local prefs = state.layout_prototype
  local meter_prefs = state.metering and state.metering.prefs or {}
  local meter_history = meter_prefs.show_history ~= false and meter_prefs.show_meters ~= false
    and (meter_prefs.show_loudness ~= false or meter_prefs.show_lr ~= false)
  local previous=state.layout_prototype_geometry
  local arrangement=panel_signature(prefs)
  local same_arrangement=previous and previous.arrangement==arrangement
    and previous.intended==prefs.mode
  -- Each plot fits inside its frame; changing views must not move dividers.
  local options = {
    scale=theme.scale, gap=M.SPECTRUM_SPLIT_GAP,
    min_width=M.SPECTRUM_PANE_MIN_W, min_height=M.REFERENCE_PANE_MIN_H,
    stereo_hide_height=M.STEREO_HIDE_H,
    -- Dock resizing can briefly report a taller viewport while shrinking.
    -- Require extra room to restore a scope that has already yielded its space.
    stereo_restore_height=M.STEREO_RESTORE_H,
    stereo_hidden=same_arrangement and previous.hidden and previous.hidden.stereo or false,
    loudness_min_height=meter_history and 228*theme.scale or 200*theme.scale,
    previous_mode=previous_mode,
    stereo_side_width=state.stereo_preferences and state.stereo_preferences.show_correlation
      and M.STEREO_CORRELATION_W or 0,
  }
  local geometry
  if card then
    geometry = core.measure_with_card(width, height, prefs, options, card)
  else
    geometry = core.measure(width, height, prefs, options)
  end
  if not geometry.temporary then previous_mode=geometry.mode end
  geometry.frame_h = reaper.ImGui_GetFrameHeight(ctx)
  geometry.visual_h, geometry.count = height, #geometry.panels
  geometry.width = width
  geometry.arrangement=arrangement
  geometry.intended = prefs.mode
  return geometry
end

function prototype.input(ctx, state, geometry, x, y, width)
  local result
  local input = {blocked=false, exclusions={}, gaps={}}
  local mx, my = reaper.ImGui_GetMousePos(ctx)

  local swap_action, swap_input = divider_swaps.input(ctx, 'prototype',
    geometry.panels, geometry.dividers or {}, x, y, names)
  input.swaps = swap_input
  input.blocked = input.blocked or swap_input.blocked
  if swap_action then result = result or action({type='swap',a=swap_action.a,b=swap_action.b}) end

  for i, divider in ipairs(geometry.dividers or {}) do
    local key=divider.key or tostring(i)
    local hot, held, activated = false, false, false
    if not swap_input.blocked then
      reaper.ImGui_SetCursorScreenPos(ctx,x+divider.x,y+divider.y)
      reaper.ImGui_InvisibleButton(ctx,'##prototype_divider_'..key,math.max(1,divider.w),math.max(1,divider.h))
      hot, held = reaper.ImGui_IsItemHovered(ctx),reaper.ImGui_IsItemActive(ctx)
      activated = reaper.ImGui_IsItemActivated(ctx)
    end
    input.gaps[i]={hot=hot,held=held}
    if activated then
      local pos=divider.axis=='x' and mx-x or my-y
      local centre=divider.axis=='x' and divider.x+divider.w/2 or divider.y+divider.h/2
      divider_drag={key=key,offset=pos-centre,
        start=divider.axis=='x' and mx or my,moved=false}
    end
    if hot or held then
      input.blocked=true
      reaper.ImGui_SetMouseCursor(ctx,divider.axis=='x'
        and reaper.ImGui_MouseCursor_ResizeEW() or reaper.ImGui_MouseCursor_ResizeNS())
    end
    if held and divider_drag and divider_drag.key==key then
      local travelled=math.abs((divider.axis=='x' and mx or my)-divider_drag.start)
      if travelled>=DIVIDER_DRAG_THRESHOLD*theme.scale then divider_drag.moved=true end
    end
    -- A divider squeezed to a single allowed position has nothing to move.
    local movable=(divider.min_share or 0)<(divider.max_share or 1)
    if held and divider_drag and divider_drag.key==key and divider_drag.moved and movable then
      local pointer=(divider.axis=='x' and mx-x or my-y)-divider_drag.offset
      local span=divider.span or (divider.axis=='x' and width or geometry.visual_h)
      local gap=divider.axis=='x' and divider.w or divider.h
      local value=(pointer-(divider.origin or 0)-gap/2)/math.max(1,span)
      value=math.max(divider.min_share or 0,math.min(divider.max_share or 1,value))
      result=result or action({type='split',key=divider.key,axis=divider.axis,value=value})
    end
  end
  if not reaper.ImGui_IsMouseDown(ctx,0) then divider_drag=nil end
  return result,input
end

function prototype.paint(ctx,geometry,input,x,y)
  local dl=reaper.ImGui_GetWindowDrawList(ctx)
  for i, divider in ipairs(geometry.dividers or {}) do
    local face=input.gaps[i]
    if face and (face.hot or face.held) then
      reaper.ImGui_DrawList_AddRectFilled(dl,x+divider.x,y+divider.y,
        x+divider.x+divider.w,y+divider.y+divider.h,
        face.held and T.FILL_PRIMARY or T.FILL_SECONDARY)
    end
  end
  divider_swaps.paint(ctx,input.swaps)
end

return prototype
