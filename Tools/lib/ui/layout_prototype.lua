-- Arrangement controls around the existing display painters.
local core = require('core.layout_prototype')
local theme = require('ui.theme')
local widgets = require('ui.widgets')
local tips = require('ui.tips')
local divider_swaps = require('ui.divider_swaps')
local T, M = theme.tokens, theme.metrics
local prototype = {}
local names = {waveform='Waveform', spectrum='Spectrum', stereo='Stereo', loudness='Loudness'}
local modes = {{'auto','Auto'}, {'grid','Grid'}, {'top','Wide Top'}, {'left','Tall Left'}}
local previous_modes = {}
local header_drag, divider_drag, swap_panel

local function action(operation)
  return {type='layout_prototype', operation=operation}
end

function prototype.measure(ctx, state, width, height)
  local model, prefs = state.layout_prototype, core.current(state.layout_prototype)
  local frame = reaper.ImGui_GetFrameHeight(ctx)
  local meter_prefs = state.metering and state.metering.prefs or {}
  local meter_history = meter_prefs.show_history ~= false and meter_prefs.show_meters ~= false
    and (meter_prefs.show_loudness ~= false or meter_prefs.show_lr ~= false)
  local toolbar = model.editing and frame + M.ITEM_SPACING_Y or 0
  local header = model.editing and frame + M.ITEM_SPACING_Y or 0
  local previous=state.layout_prototype_geometry
  local arrangement=prefs.mode..'/'..table.concat(prefs.order,',')..'/'..table.concat(prefs.enabled,',')
  local same_arrangement=previous and previous.prototype_variant==model.active
    and previous.arrangement==arrangement and not model.editing and not previous.editing
  -- Each plot fits inside its frame; changing views must not move dividers.
  local geometry = core.measure(width, math.max(0, height-toolbar), prefs, {
    scale=theme.scale, gap=M.SPECTRUM_SPLIT_GAP,
    min_width=M.SPECTRUM_PANE_MIN_W, min_height=M.REFERENCE_PANE_MIN_H,
    header_height=header,
    stereo_hide_height=M.STEREO_HIDE_H,
    -- Dock resizing can briefly report a taller viewport while shrinking.
    -- Require extra room to restore a scope that has already yielded its space.
    stereo_restore_height=M.STEREO_RESTORE_H,
    stereo_hidden=same_arrangement and previous.hidden and previous.hidden.stereo or false,
    loudness_min_height=meter_history and 228*theme.scale or 200*theme.scale,
    previous_mode=previous_modes[model.active],
    stereo_side_width=state.stereo_preferences and state.stereo_preferences.show_correlation
      and M.STEREO_CORRELATION_W or 0,
  })
  if not geometry.temporary then previous_modes[model.active]=geometry.mode end
  geometry.toolbar_h, geometry.frame_h = toolbar, frame
  geometry.visual_h, geometry.count = height, #geometry.panels
  geometry.width, geometry.prototype_variant = width, model.active
  geometry.arrangement=arrangement
  geometry.intended = prefs.mode
  geometry.editing = model.editing
  for _, pane in ipairs(geometry.panels) do
    pane.y = pane.y + toolbar
    if model.editing and pane.h > header then
      pane.header = {x=pane.x, y=pane.y, w=pane.w, h=frame}
      pane.y, pane.h = pane.y+header, pane.h-header
    end
  end
  for _, divider in ipairs(geometry.dividers or {}) do
    divider.y = divider.y + toolbar
  end
  return geometry
end

local function toolbar(ctx, state, x, y, width)
  local prefs = core.current(state.layout_prototype)
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  if width >= M.SET_WIN_W then
    reaper.ImGui_AlignTextToFramePadding(ctx)
    reaper.ImGui_Text(ctx, 'Arrange Panels')
    reaper.ImGui_SameLine(ctx)
  end
  local result
  if reaper.ImGui_Button(ctx, 'Done##layout_prototype') then
    result = action({type='edit', value=false})
  end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, 'Auto##layout_prototype') then
    result = result or action({type='mode', value='auto'})
  end
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, M.REFERENCE_PICKER_W)
  local label = 'Auto'
  for _, mode in ipairs(modes) do if mode[1]==prefs.mode then label=mode[2] end end
  if reaper.ImGui_BeginCombo(ctx, '##prototype_arrangement', label) then
    for _, mode in ipairs(modes) do
      if reaper.ImGui_Selectable(ctx, mode[2], mode[1]==prefs.mode) then
        result = result or action({type='mode', value=mode[1]})
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end
  return result
end

local function inside(r, mx, my, x, y)
  return mx>=x+r.x and mx<=x+r.x+r.w and my>=y+r.y and my<=y+r.y+r.h
end

function prototype.input(ctx, state, geometry, x, y, width)
  local model, prefs = state.layout_prototype, core.current(state.layout_prototype)
  local result
  local input = {blocked=model.editing, exclusions={}, gaps={}, highlight=nil}
  local mx, my = reaper.ImGui_GetMousePos(ctx)
  local window_hot = reaper.ImGui_IsWindowHovered(ctx,
    reaper.ImGui_HoveredFlags_AllowWhenBlockedByActiveItem())
  if model.editing then result=toolbar(ctx,state,x,y,width) end

  local swap_action, swap_input = divider_swaps.input(ctx, 'prototype_'..model.active,
    geometry.panels, geometry.dividers or {}, x, y, names)
  input.swaps = swap_input
  input.blocked = input.blocked or swap_input.blocked
  if swap_action then result = result or action({type='swap',a=swap_action.a,b=swap_action.b}) end

  if header_drag and (header_drag.variant~=model.active or not model.editing) then header_drag=nil end
  for _, pane in ipairs(geometry.panels) do
    local h=pane.header
    if h then
      reaper.ImGui_SetCursorScreenPos(ctx,x+h.x,y+h.y)
      local clicked=reaper.ImGui_Button(ctx,names[pane.id]..'##prototype_header_'..pane.id,h.w,h.h)
      if reaper.ImGui_IsItemActivated(ctx) then
        header_drag={id=pane.id,x=mx,y=my,variant=model.active,moving=false}
      end
      if clicked and not (header_drag and header_drag.moving) then
        swap_panel=pane.id
        reaper.ImGui_OpenPopup(ctx,'prototype_panel_swap')
      end
      tips.show(ctx,reaper.ImGui_IsItemHovered(ctx),
        'Drag onto another panel to swap, or click to choose.', 'prototype_header_'..pane.id)
    end
  end
  if header_drag then
    if math.abs(mx-header_drag.x)+math.abs(my-header_drag.y)>M.SPECTRUM_SPLIT_GAP then
      header_drag.moving=true
    end
    if header_drag.moving then
      for _, pane in ipairs(geometry.panels) do
        if pane.id~=header_drag.id and window_hot
            and (inside(pane,mx,my,x,y) or (pane.header and inside(pane.header,mx,my,x,y))) then
          input.highlight=pane
        end
      end
    end
    if not reaper.ImGui_IsMouseDown(ctx,0) then
      if input.highlight then
        result=action({type='swap',a=header_drag.id,b=input.highlight.id})
      end
      header_drag=nil
    end
  end
  if reaper.ImGui_BeginPopup(ctx,'prototype_panel_swap') then
    reaper.ImGui_TextColored(ctx,T.TEXT_TERTIARY,'Swap '..(names[swap_panel] or 'Panel')..' With')
    for _, id in ipairs(prefs.enabled) do
      if id~=swap_panel and reaper.ImGui_MenuItem(ctx,names[id]) then
        result=action({type='swap',a=swap_panel,b=id})
      end
    end
    reaper.ImGui_EndPopup(ctx)
  end

  if divider_drag and divider_drag.variant~=model.active then divider_drag=nil end
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
      local pos=divider.axis=='x' and mx-x or my-y-geometry.toolbar_h
      local centre=divider.axis=='x' and divider.x+divider.w/2
        or divider.y-geometry.toolbar_h+divider.h/2
      divider_drag={variant=model.active,key=key,offset=pos-centre}
    end
    if hot or held then
      input.blocked=true
      reaper.ImGui_SetMouseCursor(ctx,divider.axis=='x'
        and reaper.ImGui_MouseCursor_ResizeEW() or reaper.ImGui_MouseCursor_ResizeNS())
    end
    if held and divider_drag and divider_drag.key==key then
      local pointer=(divider.axis=='x' and mx-x or my-y-geometry.toolbar_h)-divider_drag.offset
      local span=divider.span or (divider.axis=='x' and width or geometry.visual_h-geometry.toolbar_h)
      local gap=divider.axis=='x' and divider.w or divider.h
      local value=(pointer-(divider.origin or 0)-gap/2)/math.max(1,span)
      value=math.max(divider.min_share or 0,math.min(divider.max_share or 1,value))
      result=result or action({type='split',key=divider.key,axis=divider.axis,value=value})
    end
  end
  if not reaper.ImGui_IsMouseDown(ctx,0) then divider_drag=nil end
  input.dragging=header_drag and header_drag.moving or false
  return result,input
end

function prototype.paint(ctx,geometry,input,x,y)
  if input.dragging then widgets.request_grab_cursor() end
  local dl=reaper.ImGui_GetWindowDrawList(ctx)
  for i, divider in ipairs(geometry.dividers or {}) do
    local face=input.gaps[i]
    if face and (face.hot or face.held or geometry.editing) then
      reaper.ImGui_DrawList_AddRectFilled(dl,x+divider.x,y+divider.y,
        x+divider.x+divider.w,y+divider.y+divider.h,
        face.held and T.FILL_PRIMARY or T.FILL_SECONDARY)
    end
  end
  if input.highlight then
    local pane=input.highlight
    local top=pane.header and pane.header.y or pane.y
    reaper.ImGui_DrawList_AddRect(dl,x+pane.x,y+top,
      x+pane.x+pane.w,y+pane.y+pane.h,T.ACCENT,0,0,theme.scale*2)
  end
  divider_swaps.paint(ctx,input.swaps)
end

return prototype
