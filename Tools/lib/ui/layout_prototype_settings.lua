-- Reference View arrangement controls report changes for the entry script to save.
local theme = require('ui.theme')
local widgets = require('ui.widgets')
local tips = require('ui.tips')
local core = require('core.layout_prototype')
local T, M = theme.tokens, theme.metrics

local prototype_settings = {}
local PANELS = {
  {id='reference', label='Reference', icon='audio-waveform'},
  {id='spectrum', label='Spectrum', icon='chart-no-axes-column'},
  {id='stereo', label='Scope', icon='diamond'},
  {id='loudness', label='Loudness', icon='gauge'},
}
-- Longest first. A preview panel can be far narrower than its name, so the
-- preview takes the longest form that fits instead of letting the name clip.
local NAME_FORMS = {
  reference={'Reference', 'Ref', 'Rf'},
  spectrum={'Spectrum', 'Spec', 'Sp'},
  stereo={'Scope', 'Scp', 'Sc'},
  loudness={'Loudness', 'Loud', 'Ld'},
  library={'Library', 'Lib', 'Lb'},
}
local NAMES = {}
for id, forms in pairs(NAME_FORMS) do NAMES[id] = forms[1] end
local SHAPES = {
  {id='auto', label='Auto'},
  {id='row', label='Side By Side'},
  {id='stack', label='Stacked'},
  {id='grid', label='Grid'},
  {id='top', label='Wide Top'},
  {id='bottom', label='Wide Bottom'},
  {id='left', label='Tall Left'},
  {id='right', label='Tall Right'},
}
-- Two panels can only sit side by side or stacked, so every other shape draws
-- as one of these.
local TWO_PANEL_SHAPES = {SHAPES[1], SHAPES[2], SHAPES[3]}
local TWO_PANEL = {grid='row', left='row', right='row', top='stack', bottom='stack'}
local POSITIONS_NOTE = 'Drag a panel onto another to swap them, or click a panel to choose.'
local FIXED_NOTES = {
  [1] = POSITIONS_NOTE .. ' Reference stays in place.',
  [2] = POSITIONS_NOTE .. ' Library stays in place.',
  [3] = POSITIONS_NOTE .. ' Reference and Library stay in place.',
}
local swap_source, map_drag
-- Reused every frame: the preview's panel and fixed rectangles.
local rects, fixed = {}, {}

local function fitted_name(ctx, id, width)
  local forms = NAME_FORMS[id]
  if not forms then return NAMES[id] or id end
  for _, form in ipairs(forms) do
    if reaper.ImGui_CalcTextSize(ctx, form) + M.FRAME_PAD_X*2 <= width then return form end
  end
  return forms[#forms]
end

local function action(operation)
  return {type='layout_prototype', operation=operation}
end

local function visible(prefs)
  local result = {}
  local enabled = {}
  for _, id in ipairs(prefs.enabled or {}) do enabled[id] = true end
  for _, id in ipairs(prefs.order or {}) do
    if enabled[id] then result[#result+1] = id end
  end
  return result
end

local function measure_options(state)
  return {
    scale=theme.scale, gap=M.SPECTRUM_SPLIT_GAP,
    min_width=M.SPECTRUM_PANE_MIN_W, min_height=M.REFERENCE_PANE_MIN_H,
    stereo_side_width=state.stereo_preferences and state.stereo_preferences.show_correlation
      and M.STEREO_CORRELATION_W or 0,
  }
end

local function representative(prefs, state, mode)
  local copy = {mode=mode or prefs.mode, order=prefs.order,
    enabled=prefs.enabled, shares=prefs.shares}
  -- Enough room for every shape at every UI Size, so thumbnails do not show a
  -- fallback arrangement instead of the option they represent.
  local width, height = 2200*theme.scale, 1600*theme.scale
  local geometry = core.measure(width, height, copy, measure_options(state))
  geometry.width, geometry.visual_h = width, height
  return geometry
end

-- The shape Auto uses in the panels' current space.
local function auto_choice(prefs, state)
  local live = state.layout_prototype_geometry
  if live and live.intended == 'auto' and not live.temporary then return live.mode end
  local width = live and live.width or 1600*theme.scale
  local height = live and live.visual_h or 900*theme.scale
  return core.measure(width, height, {mode='auto', order=prefs.order,
    enabled=prefs.enabled, shares=prefs.shares}, measure_options(state)).mode
end

-- `auto_mode`: the Auto tile outlines the shape Auto picks right now.
local function shape_choice(ctx, state, prefs, choice, selected, width, auto_mode)
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
  local is_auto = choice.id == 'auto'
  local geometry = representative(prefs, state, is_auto and auto_mode or choice.id)
  local sx, sy = M.SET_LAYOUT_MINI_W/geometry.width, M.SET_LAYOUT_MINI_H/geometry.visual_h
  for _, rect in ipairs(geometry.panels) do
    -- Keep the parts distinguishable after reducing the full layout.
    local inset = math.min(M.SET_LAYOUT_MINI_GAP/4, rect.w*sx/4, rect.h*sy/4)
    local ax, ay = mini_x+rect.x*sx+inset, mini_y+rect.y*sy+inset
    local bx, by = mini_x+(rect.x+rect.w)*sx-inset, mini_y+(rect.y+rect.h)*sy-inset
    if is_auto then
      reaper.ImGui_DrawList_AddRect(dl, ax, ay, bx, by, colour, theme.scale, 0, theme.scale)
    else
      reaper.ImGui_DrawList_AddRectFilled(dl, ax, ay, bx, by, colour, theme.scale)
    end
  end
  local tw = select(1, reaper.ImGui_CalcTextSize(ctx, choice.label))
  reaper.ImGui_DrawList_AddText(dl, x0+(x1-x0-tw)*0.5,
    mini_y+M.SET_LAYOUT_MINI_H+M.FRAME_PAD_Y,
    theme.fade(selected and T.ACCENT_HOVER or T.TEXT_SECONDARY, alpha), choice.label)
  return clicked
end

local function panel_choices(ctx, state, prefs, count, begin_setting, setting_label, icon_font)
  begin_setting(ctx)
  setting_label(ctx, 'Show Panels')
  local width = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local gap = M.SET_CONTENT_GAP
  local min_width = 0
  for _, panel in ipairs(PANELS) do
    local label_width = reaper.ImGui_CalcTextSize(ctx, panel.label)
    min_width = math.max(min_width, label_width)
  end
  min_width = min_width + M.FRAME_PAD_X*4
  -- One row when every choice fits, then two columns, then one.
  local n = #PANELS
  local columns = 1
  for _, candidate in ipairs({n, 2}) do
    if width >= min_width*candidate+gap*(candidate-1) then columns = candidate; break end
  end
  local button_width = (width-gap*(columns-1))/columns
  local result
  for i, panel in ipairs(PANELS) do
    if (i-1)%columns ~= 0 then reaper.ImGui_SameLine(ctx, 0, gap) end
    local checked, last = false, false
    if panel.id == 'reference' then
      checked = prefs.reference ~= false
    else
      for _, id in ipairs(prefs.enabled or {}) do
        if id == panel.id then checked = true; break end
      end
      last = checked and count == 1
    end
    local changed = widgets.icon_label_toggle(ctx, icon_font,
      'prototype_panel_' .. panel.id, panel.label, panel.icon, checked, button_width, not last)
    if changed then
      result = panel.id == 'reference' and action({type='reference', value=not checked})
        or action({type='toggle', id=panel.id})
    end
    local hovered = reaper.ImGui_IsItemHovered(ctx,
      reaper.ImGui_HoveredFlags_AllowWhenDisabled
        and reaper.ImGui_HoveredFlags_AllowWhenDisabled() or 0)
    -- The last visible panel explains why it can't be hidden; the others
    -- show their Show / Hide hotkey when one is assigned.
    tips.show(ctx, hovered, last and core.LAST_PANEL
      or tips.with_shortcut(state, 'panel_' .. panel.id,
        'Show or hide the ' .. panel.label .. ' panel'))
  end
  return result
end

local function arrangement(ctx, state, prefs, count, begin_setting, setting_label, setting_note)
  begin_setting(ctx)
  setting_label(ctx, 'Arrangement')
  if count < 2 then
    setting_note(ctx, 'Show two or more panels to choose an arrangement.')
    return nil
  end
  local shapes = count == 2 and TWO_PANEL_SHAPES or SHAPES
  local columns = #shapes == 3 and 3 or 4
  local selected = count == 2 and TWO_PANEL[prefs.mode] or prefs.mode
  local auto_mode = auto_choice(prefs, state)
  local width = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local tile_width = (width-M.SET_LAYOUT_GRID_GAP*(columns-1))/columns
  local result
  for i, shape in ipairs(shapes) do
    if (i-1)%columns ~= 0 then reaper.ImGui_SameLine(ctx, 0, M.SET_LAYOUT_GRID_GAP) end
    if shape_choice(ctx, state, prefs, shape, selected == shape.id, tile_width, auto_mode) then
      result = action({type='mode', value=shape.id})
    end
  end
  if count == 2 then
    setting_note(ctx, 'Grid, wide and tall arrangements need all three panels.')
  elseif prefs.mode == 'auto' then
    setting_note(ctx, 'Auto picks the arrangement that best fits the window.')
  end
  return result
end

local function put(list, index, id, x, y, w, h)
  local rect = list[index] or {}
  rect.id, rect.x, rect.y, rect.w, rect.h = id, x, y, w, h
  list[index] = rect
  return index
end

-- Fills `fixed` and `rects` in the Reference View's own coordinates from this
-- frame's placement (ui/library_host.lua) and panel arrangement
-- (ui/layout_prototype.lua). Returns the view's size and the fixed count, or
-- nothing when the view has not been drawn yet.
local function live_view(state, prefs)
  local view, live = state.reference_view_layout, state.layout_prototype_geometry
  if not view or not view.width or view.width < 1 or view.height < 1 then return nil end
  local nf = 0
  if view.reference then
    local r = view.reference
    nf = put(fixed, nf+1, 'reference', r.x, r.y, r.w, math.min(r.h, view.height))
  end
  if view.library then
    local l = view.library
    nf = put(fixed, nf+1, 'library', l.x, l.y, l.w, l.h)
  end
  local area, n = view.panels, 0
  if live and not live.temporary then
    for _, pane in ipairs(live.panels) do
      n = put(rects, n+1, pane.id, area.x+pane.x, area.y+pane.y, pane.w, pane.h)
    end
  else
    -- The window is too small to show the arrangement, so show it as it
    -- would be, in the space beside the card.
    local x0, w = area.x, area.w
    if view.shared and view.reference then
      x0 = view.reference.x + view.reference.w + view.gap
      w = area.x + area.w - x0
    end
    local g = representative(prefs, state)
    local sx, sy = w/g.width, area.h/g.visual_h
    for _, pane in ipairs(g.panels) do
      n = put(rects, n+1, pane.id, x0+pane.x*sx, area.y+pane.y*sy, pane.w*sx, pane.h*sy)
    end
  end
  for i = n+1, #rects do rects[i] = nil end
  for i = nf+1, #fixed do fixed[i] = nil end
  return view.width, view.height
end

local function position_map(ctx, state, prefs, count)
  local source_w, source_h = live_view(state, prefs)
  if not source_w then
    local g = representative(prefs, state)
    source_w, source_h = g.width, g.visual_h
    for i, pane in ipairs(g.panels) do put(rects, i, pane.id, pane.x, pane.y, pane.w, pane.h) end
    for i = #g.panels+1, #rects do rects[i] = nil end
    for i = 1, #fixed do fixed[i] = nil end
  end
  -- The preview takes the view's shape, within limits that keep it readable.
  local width = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local height = math.max(M.SET_LAYOUT_PREVIEW_H,
    math.min(M.SET_LAYOUT_PREVIEW_MAX_H, width*source_h/source_w))
  local sx = math.min(width, height*source_w/source_h)/source_w
  local sy = height/source_h
  local px, py = reaper.ImGui_GetCursorScreenPos(ctx)
  reaper.ImGui_Dummy(ctx, width, height)

  -- The card and the docked Library are shown for context; they never swap.
  reaper.ImGui_BeginDisabled(ctx)
  for i, rect in ipairs(fixed) do
    local name = fitted_name(ctx, rect.id, rect.w*sx)
    reaper.ImGui_SetCursorScreenPos(ctx, px+rect.x*sx, py+rect.y*sy)
    reaper.ImGui_Button(ctx, name .. '##prototype_fixed_' .. i, rect.w*sx, rect.h*sy)
  end
  reaper.ImGui_EndDisabled(ctx)

  local result
  local mx, my = reaper.ImGui_GetMousePos(ctx)
  local can_swap = count > 1
  for i, rect in ipairs(rects) do
    local x, y, w, h = px+rect.x*sx, py+rect.y*sy, rect.w*sx, rect.h*sy
    reaper.ImGui_SetCursorScreenPos(ctx, x, y)
    if not can_swap then reaper.ImGui_BeginDisabled(ctx) end
    local clicked = reaper.ImGui_Button(ctx,
      fitted_name(ctx, rect.id, w) .. '##prototype_position_' .. i, w, h)
    if not can_swap then reaper.ImGui_EndDisabled(ctx) end
    if can_swap and reaper.ImGui_IsItemActivated(ctx) then
      map_drag = {id=rect.id, x=mx, y=my, moving=false}
    end
    if clicked and not (map_drag and map_drag.moving) then
      swap_source = rect.id
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
        local x, y = px+rect.x*sx, py+rect.y*sy
        if rect.id ~= map_drag.id and mx >= x and mx <= x+rect.w*sx
            and my >= y and my <= y+rect.h*sy then
          target = rect
          break
        end
      end
    end
    if target then
      local dl = reaper.ImGui_GetWindowDrawList(ctx)
      local alpha = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha())
      local x, y = px+target.x*sx, py+target.y*sy
      reaper.ImGui_DrawList_AddRect(dl, x, y, x+target.w*sx, y+target.h*sy,
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
      if rect.id ~= swap_source and reaper.ImGui_MenuItem(ctx, NAMES[rect.id]) then
        result = action({type='swap', a=swap_source, b=rect.id})
      end
    end
    reaper.ImGui_EndPopup(ctx)
  end
  return result
end

local function positions(ctx, state, prefs, count, begin_setting, setting_label, setting_note)
  begin_setting(ctx)
  setting_label(ctx, 'Panel Positions')
  local result = position_map(ctx, state, prefs, count)
  local live = state.layout_prototype_geometry
  if count < 2 then
    setting_note(ctx, 'Show two or more panels to change their positions.')
  elseif live and live.temporary then
    setting_note(ctx, 'The window is too small for this arrangement. It returns when there is room.')
  else
    local key = 0
    for _, rect in ipairs(fixed) do key = key + (rect.id == 'reference' and 1 or 2) end
    setting_note(ctx, FIXED_NOTES[key] or POSITIONS_NOTE)
  end
  return result
end

function prototype_settings.draw(ctx, state, begin_setting, setting_label, setting_note, icon_font)
  local prefs = state.layout_prototype
  if not prefs then return nil, false end
  if state.panel_layout_error then
    begin_setting(ctx)
    setting_note(ctx, state.panel_layout_error)
    if reaper.ImGui_Button(ctx, 'Reset Panel Layout') then
      return action({type='reset_all'}), true
    end
    return nil, true
  end
  local count = #visible(prefs)
  local result = panel_choices(ctx, state, prefs, count, begin_setting, setting_label, icon_font)
  result = arrangement(ctx, state, prefs, count, begin_setting, setting_label, setting_note)
    or result
  result = positions(ctx, state, prefs, count, begin_setting, setting_label, setting_note)
    or result
  begin_setting(ctx)
  if reaper.ImGui_Button(ctx, 'Reset Panel Layout', M.SET_ACTION_W*1.5) then
    result = action({type='reset'})
  end
  return result, true
end

return prototype_settings
