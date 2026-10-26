-- Reference View arrangement controls report changes for the entry script to save.
local theme = require('ui.theme')
local widgets = require('ui.widgets')
local tips = require('ui.tips')
local core = require('core.layout_prototype')
local T, M = theme.tokens, theme.metrics

local prototype_settings = {}
local PANELS = {
  {id='waveform', label='Waveform', icon='audio-waveform'},
  {id='spectrum', label='Spectrum', icon='chart-no-axes-column'},
  {id='stereo', label='Stereo', icon='diamond'},
  {id='loudness', label='Loudness', icon='gauge'},
}
local NAMES = {waveform='Waveform', spectrum='Spectrum', stereo='Stereo', loudness='Loudness'}
local APPROACHES = {
  {id='automatic', label='Automatic'},
  {id='map', label='Layout Map'},
  {id='direct', label='Arrange In Place'},
}
local SHAPES = {
  {id='auto', label='Auto'},
  {id='row', label='Side by Side'},
  {id='stack', label='Stacked'},
  {id='grid', label='Grid'},
  {id='top', label='Wide Top'},
  {id='bottom', label='Wide Bottom'},
  {id='left', label='Tall Left'},
  {id='right', label='Tall Right'},
}
local swap_source, map_drag, last_active

local function action(operation)
  return {type='layout_prototype', operation=operation}
end

local function visible(variant)
  local result = {}
  local enabled = {}
  for _, id in ipairs(variant.enabled or {}) do enabled[id] = true end
  for _, id in ipairs(variant.order or {}) do
    if enabled[id] and NAMES[id] then
      result[#result+1] = id
    end
  end
  return result
end

local function representative(variant, state, mode)
  local prefs = {mode=mode or variant.mode, order=variant.order,
    enabled=variant.enabled, shares=variant.shares}
  -- Enough room for every shape at every UI Size, so thumbnails do not show a
  -- fallback arrangement instead of the option they represent.
  local width, height = 2200*theme.scale, 1600*theme.scale
  local geometry = core.measure(width, height, prefs, {
    scale=theme.scale, gap=M.SPECTRUM_SPLIT_GAP,
    min_width=M.SPECTRUM_PANE_MIN_W, min_height=M.REFERENCE_PANE_MIN_H,
    stereo_side_width=state.stereo_preferences and state.stereo_preferences.show_correlation
      and M.STEREO_CORRELATION_W or 0,
  })
  geometry.width, geometry.visual_h = width, height
  return geometry
end

local function shape_choice(ctx, state, variant, choice, selected, width)
  local pushed = widgets.push_soft_active(ctx, selected)
  local clicked = reaper.ImGui_Button(ctx, '##prototype_shape_' .. choice.id,
    width, M.SET_LAYOUT_CHOICE_H)
  widgets.pop_soft_active(ctx, pushed)
  local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
  local x1 = select(1, reaper.ImGui_GetItemRectMax(ctx))
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local alpha = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha())
  local colour = theme.fade(selected and T.ACCENT_HOVER or T.TEXT_TERTIARY, alpha)
  local mini_x = x0 + (x1-x0-M.SET_LAYOUT_MINI_W)*0.5
  local mini_y = y0 + M.FRAME_PAD_X
  if choice.id == 'auto' then
    reaper.ImGui_DrawList_AddRect(dl,
      mini_x+M.FRAME_PAD_Y, mini_y+M.FRAME_PAD_Y,
      mini_x+M.SET_LAYOUT_MINI_W-M.FRAME_PAD_Y,
      mini_y+M.SET_LAYOUT_MINI_H-M.FRAME_PAD_Y,
      colour, theme.scale*2, 0, theme.scale)
  else
    local geometry = representative(variant, state, choice.id)
    local sx, sy = M.SET_LAYOUT_MINI_W/geometry.width, M.SET_LAYOUT_MINI_H/geometry.visual_h
    for _, rect in ipairs(geometry.panels) do
      -- Keep the four parts distinguishable after reducing the full layout.
      local inset = math.min(M.SET_LAYOUT_MINI_GAP/4, rect.w*sx/4, rect.h*sy/4)
      reaper.ImGui_DrawList_AddRectFilled(dl,
        mini_x+rect.x*sx+inset,
        mini_y+rect.y*sy+inset,
        mini_x+(rect.x+rect.w)*sx-inset,
        mini_y+(rect.y+rect.h)*sy-inset,
        colour, theme.scale)
    end
  end
  local tw = select(1, reaper.ImGui_CalcTextSize(ctx, choice.label))
  reaper.ImGui_DrawList_AddText(dl, x0+(x1-x0-tw)*0.5,
    mini_y+M.SET_LAYOUT_MINI_H+M.FRAME_PAD_Y,
    theme.fade(selected and T.ACCENT_HOVER or T.TEXT_SECONDARY, alpha), choice.label)
  return clicked
end

local function panel_choices(ctx, variant, begin_setting, setting_label, icon_font, guide)
  begin_setting(ctx)
  setting_label(ctx, 'Show Panels')
  local count = #visible(variant)
  local width = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local gap = M.SET_CONTENT_GAP
  local min_width = 0
  for _, panel in ipairs(PANELS) do
    local label_width = reaper.ImGui_CalcTextSize(ctx, panel.label)
    min_width = math.max(min_width, label_width)
  end
  min_width = min_width + M.FRAME_PAD_X*4
  local columns = width >= min_width*4+gap*3 and 4
    or (width >= min_width*2+gap and 2 or 1)
  local button_width = (width-gap*(columns-1))/columns
  local result
  for i, panel in ipairs(PANELS) do
    if (i-1)%columns ~= 0 then reaper.ImGui_SameLine(ctx, 0, gap) end
    local checked = false
    for _, id in ipairs(variant.enabled or {}) do
      if id == panel.id then checked = true; break end
    end
    local last = checked and count == 1
    local changed = widgets.icon_label_toggle(ctx, icon_font,
      'prototype_panel_' .. panel.id, panel.label, panel.icon, checked, button_width, not last)
    if guide then
      local x0,y0 = reaper.ImGui_GetItemRectMin(ctx)
      local x1,y1 = reaper.ImGui_GetItemRectMax(ctx)
      guide.targets['toggle_' .. panel.id] = {x=x0,y=y0,w=x1-x0,h=y1-y0}
    end
    if changed then result = action({type='toggle', id=panel.id}) end
    if not guide then
      local hovered = reaper.ImGui_IsItemHovered(ctx,
        reaper.ImGui_HoveredFlags_AllowWhenDisabled
          and reaper.ImGui_HoveredFlags_AllowWhenDisabled() or 0)
      tips.show(ctx, last and hovered, 'Keep at least one panel visible.')
    end
  end
  return result
end

local function position_map(ctx, state, active, variant, compact, guide)
  local live = state.layout_prototype_geometry
  local matched = live and live.prototype_variant == active
  local temporary = matched and live.temporary
  local geometry = not guide and matched and not temporary and live
    or representative(variant, state)
  local source_width = math.max(1, geometry.width or 1600)
  local source_height = math.max(1, geometry.visual_h or 900)
  local width = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local height = compact and M.SET_LAYOUT_PREVIEW_H*0.75 or M.SET_LAYOUT_PREVIEW_H
  local px, py = reaper.ImGui_GetCursorScreenPos(ctx)
  reaper.ImGui_Dummy(ctx, width, height)
  local rects = {}
  for _, pane in ipairs(geometry.panels or {}) do
    rects[#rects+1] = {id=pane.id,
      x=px+pane.x*width/source_width, y=py+pane.y*height/source_height,
      w=pane.w*width/source_width, h=pane.h*height/source_height}
  end
  if guide then
    guide.targets = guide.targets or {}
    for _, panel in ipairs(PANELS) do
      guide.targets['map_' .. panel.id] = nil
    end
    for _, rect in ipairs(rects) do
      guide.targets['map_' .. rect.id] = {
        x=rect.x, y=rect.y, w=rect.w, h=rect.h,
      }
    end
    local target_entered = true
    if guide.progress then
      local source = guide.targets['map_' .. tostring(guide.source)]
      local target = guide.targets['map_' .. tostring(guide.target)]
      target_entered = false
      if source and target then
        local sx,sy = source.x+source.w*.5,source.y+source.h*.5
        local mx = sx+(target.x+target.w*.5-sx)*guide.progress
        local my = sy+(target.y+target.h*.5-sy)*guide.progress
        target_entered = mx>=target.x and mx<=target.x+target.w
          and my>=target.y and my<=target.y+target.h
      end
    end
    for i, rect in ipairs(rects) do
      reaper.ImGui_SetCursorScreenPos(ctx, rect.x, rect.y)
      reaper.ImGui_Button(ctx,
        NAMES[rect.id] .. '##prototype_position_' .. i, rect.w, rect.h)
      if guide.dragging and target_entered and guide.target == rect.id then
        local dl = reaper.ImGui_GetWindowDrawList(ctx)
        local alpha = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha())
        reaper.ImGui_DrawList_AddRect(dl, rect.x, rect.y,
          rect.x+rect.w, rect.y+rect.h,
          theme.fade(T.ACCENT, alpha), 0, 0, theme.scale*2)
      end
    end
    reaper.ImGui_SetCursorScreenPos(ctx, px, py+height+M.ITEM_SPACING_Y)
    return nil, false
  end
  local result
  local mx, my = reaper.ImGui_GetMousePos(ctx)
  if map_drag and map_drag.variant ~= active then map_drag = nil end
  for i, rect in ipairs(rects) do
    local id = rect.id
    reaper.ImGui_SetCursorScreenPos(ctx, rect.x, rect.y)
    local can_swap = #rects > 1 and not compact
    if not can_swap then reaper.ImGui_BeginDisabled(ctx) end
    local clicked = reaper.ImGui_Button(ctx,
      NAMES[id] .. '##prototype_position_' .. i, rect.w, rect.h)
    if not can_swap then reaper.ImGui_EndDisabled(ctx) end
    if can_swap and reaper.ImGui_IsItemActivated(ctx) then
      map_drag = {variant=active, id=id, x=mx, y=my, moving=false}
    end
    if clicked and not (map_drag and map_drag.moving) then
      swap_source = id
      reaper.ImGui_OpenPopup(ctx, 'prototype_position_swap')
    end
  end
  if map_drag then
    if math.abs(mx-map_drag.x)+math.abs(my-map_drag.y) > M.SPECTRUM_SPLIT_GAP then
      map_drag.moving = true
    end
    local target
    if map_drag.moving then
      if reaper.ImGui_IsMouseDown(ctx,0) then widgets.request_grab_cursor() end
      for _, rect in ipairs(rects) do
        if rect.id ~= map_drag.id and mx >= rect.x and mx <= rect.x+rect.w
            and my >= rect.y and my <= rect.y+rect.h then
          target = rect
          break
        end
      end
    end
    if target then
      local dl = reaper.ImGui_GetWindowDrawList(ctx)
      local alpha = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha())
      reaper.ImGui_DrawList_AddRect(dl, target.x, target.y,
        target.x+target.w, target.y+target.h,
        theme.fade(T.ACCENT, alpha), 0, 0, theme.scale*2)
    end
    if not reaper.ImGui_IsMouseDown(ctx, 0) then
      if target then result = action({type='swap', a=map_drag.id, b=target.id}) end
      map_drag = nil
    end
  end
  reaper.ImGui_SetCursorScreenPos(ctx, px, py+height+M.ITEM_SPACING_Y)
  if reaper.ImGui_BeginPopup(ctx, 'prototype_position_swap') then
    reaper.ImGui_TextColored(ctx, T.TEXT_TERTIARY,
      'Swap ' .. (NAMES[swap_source] or 'Panel') .. ' With')
    for _, rect in ipairs(rects) do
      local id = rect.id
      if id ~= swap_source and reaper.ImGui_MenuItem(ctx, NAMES[id]) then
        result = action({type='swap', a=swap_source, b=id})
      end
    end
    reaper.ImGui_EndPopup(ctx)
  end
  return result, temporary
end

local function map_heading(ctx, state, active, setting_label, guide)
  local x0 = reaper.ImGui_GetCursorPosX(ctx)
  local width = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  setting_label(ctx, 'Panel Positions')
  local live = state.layout_prototype_geometry
  if not guide and live and live.prototype_variant == active and live.temporary then
    local text = 'Full Layout'
    local tw = select(1, reaper.ImGui_CalcTextSize(ctx, text))
    reaper.ImGui_SameLine(ctx, x0+width-tw)
    reaper.ImGui_TextColored(ctx, T.TEXT_TERTIARY, text)
  end
end

function prototype_settings.draw(ctx, state, begin_setting, setting_label, setting_note, icon_font, guide)
  local model = state.layout_prototype
  if not model then return nil, false end
  if state.panel_layout_error and not guide then
    begin_setting(ctx)
    setting_note(ctx, state.panel_layout_error)
    if reaper.ImGui_Button(ctx, 'Reset Panel Layout') then
      return action({type='reset_all'}), true
    end
    return nil, true
  end
  local active = guide and 'automatic' or model.active or 'automatic'
  if not guide and active ~= last_active then
    map_drag, swap_source = nil, nil
    last_active = active
  end
  -- The gallery submits the real settings controls without letting them receive input.
  if guide then
    guide.targets = guide.targets or {}
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_DisabledAlpha(), 1)
    reaper.ImGui_BeginDisabled(ctx)
  end
  local function finish(result)
    if guide then
      reaper.ImGui_EndDisabled(ctx)
      reaper.ImGui_PopStyleVar(ctx)
      return nil, true
    end
    return result, true
  end
  local result

  begin_setting(ctx)
  setting_label(ctx, 'Layout Controls')
  local preview = 'Automatic'
  for _, approach in ipairs(APPROACHES) do
    if approach.id == active then preview = approach.label; break end
  end
  reaper.ImGui_SetNextItemWidth(ctx, -1)
  if reaper.ImGui_BeginCombo(ctx, '##layout_prototype', preview) then
    for _, approach in ipairs(APPROACHES) do
      if reaper.ImGui_Selectable(ctx, approach.label, active == approach.id) then
        result = action({type='variant', id=approach.id})
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end
  setting_note(ctx, 'Panel positions and sizes are remembered between sessions.')

  local variant = model.variants and model.variants[active]
  if not variant then
    setting_note(ctx, 'Panel settings are unavailable.')
    return finish(result)
  end
  local panel_action = panel_choices(ctx, variant, begin_setting, setting_label, icon_font, guide)
  result = result or panel_action

  if active == 'automatic' then
    begin_setting(ctx)
    map_heading(ctx, state, active, setting_label, guide)
    local map_action = position_map(ctx, state, active, variant, false, guide)
    result = result or map_action
    setting_note(ctx, 'Drag a panel to swap, or click to choose. Layout adapts to the available space.')
  elseif active == 'map' then
    begin_setting(ctx)
    setting_label(ctx, 'Panel Layout')
    local width = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
    for i, shape in ipairs(SHAPES) do
      if (i-1)%4 ~= 0 then reaper.ImGui_SameLine(ctx, 0, M.SET_LAYOUT_GRID_GAP) end
      if shape_choice(ctx, state, variant, shape, variant.mode == shape.id,
          (width-M.SET_LAYOUT_GRID_GAP*3)/4) then
        result = result or action({type='mode', value=shape.id})
      end
    end
    begin_setting(ctx)
    map_heading(ctx, state, active, setting_label)
    local map_action = position_map(ctx, state, active, variant, false)
    result = result or map_action
    setting_note(ctx, 'Drag a panel to swap, or click to choose.')
  elseif active == 'direct' then
    begin_setting(ctx)
    local x0 = reaper.ImGui_GetCursorPosX(ctx)
    local width = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
    if reaper.ImGui_AlignTextToFramePadding then
      reaper.ImGui_AlignTextToFramePadding(ctx)
    end
    setting_label(ctx, 'Auto Layout')
    reaper.ImGui_SameLine(ctx, x0+width-M.SET_SWITCH_W)
    if widgets.switch(ctx, 'prototype_auto_layout', variant.mode == 'auto') then
      result = result or action({type='mode', value=variant.mode == 'auto' and 'grid' or 'auto'})
    end
    begin_setting(ctx)
    map_heading(ctx, state, active, setting_label)
    position_map(ctx, state, active, variant, true)
    if reaper.ImGui_Button(ctx, model.editing and 'Done Arranging' or 'Arrange Panels',
        M.SET_ACTION_W*1.5) then
      result = result or action({type='edit', value=not model.editing})
    end
  end
  begin_setting(ctx)
  if reaper.ImGui_Button(ctx, 'Reset This Layout', M.SET_ACTION_W*1.5) then
    result = result or action({type='reset'})
  end
  return finish(result)
end

return prototype_settings
