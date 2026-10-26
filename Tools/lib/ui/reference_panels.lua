-- Shared gaps own pointer input before the pictures underneath them. Painting
-- the faces afterwards keeps the controls above both neighbouring views.
local core = require('core.reference_layout')
local theme = require('ui.theme')
local icons = require('ui.icons')
local icon_motion = require('ui.icon_motion')
local tips = require('ui.tips')
local T, M = theme.tokens, theme.metrics
local panels = {}
local names = {waveform='Waveform', spectrum='Spectrum', stereo='Stereo'}
local faces, drag, last_mode = {}, nil, nil
local metrics = {}

local function action(operation, commit)
  return {type='reference_panels', operation=operation, commit=commit}
end

local function contains(r, x, y)
  return x >= r.x0 and x <= r.x1 and y >= r.y0 and y <= r.y1
end

function panels.measure(width, height, prefs, _stereo_view, show_correlation)
  metrics.gap = M.SPECTRUM_SPLIT_GAP
  metrics.min_width, metrics.min_height = M.SPECTRUM_PANE_MIN_W, M.REFERENCE_PANE_MIN_H
  metrics.hide_height = M.WAVE_HIDE_H
  metrics.footer_height = M.RULER_H
  metrics.stereo_side_width = show_correlation and M.STEREO_CORRELATION_W or 0
  local geometry = core.measure(width, height, prefs, last_mode, metrics,
    drag and drag.intended)
  if not geometry.temporary and geometry.count > 1 then last_mode = geometry.intended end
  return geometry
end

function panels.input(ctx, state, geometry, x, y, width)
  local result, blocked, highlight
  local controls, exclusions = {}, {}
  local mx, my = reaper.ImGui_GetMousePos(ctx)
  local window_hot = reaper.ImGui_IsWindowHovered(ctx)
  local size = reaper.ImGui_GetFrameHeight(ctx)
  local active_faces = {}
  for di, gap in ipairs(geometry.dividers) do
    for pi, pair in ipairs(gap.pairs) do
      local a, b = geometry.panels[pair[1]].id, geometry.panels[pair[2]].id
      if geometry.temporary or core.can_swap(state.reference_panels, geometry.intended, a, b) then
        local id = geometry.mode .. '_' .. geometry.count .. '_' .. di .. '_' .. pi
        local face = faces[id] or {}
        faces[id], active_faces[id] = face, true
        local vertical = gap.axis == 'y'
        local next_pane = geometry.panels[pair[2]]
        local along = #gap.pairs > 1 and (vertical and next_pane.x or next_pane.y)
          or (vertical and gap.x or gap.y)
        face.x0 = x + (vertical and along + M.WINDOW_PAD or gap.x + (gap.w - size) / 2)
        face.y0 = y + (vertical and gap.y + (gap.h - size) / 2 or along + M.WINDOW_PAD)
        face.x1, face.y1 = face.x0 + size, face.y0 + size
        local gap_hot = window_hot and mx >= x + gap.x and mx <= x + gap.x + gap.w
          and my >= y + gap.y and my <= y + gap.y + gap.h
        face.visible = gap_hot or (face.visible and window_hot and contains(face, mx, my))
          or face.held == true
        face.hot, face.pressed = false, false
        if face.visible then
          reaper.ImGui_SetCursorScreenPos(ctx, face.x0, face.y0)
          local clicked = reaper.ImGui_InvisibleButton(ctx, '##reference_swap_' .. id, size, size)
          face.hot, face.held = reaper.ImGui_IsItemHovered(ctx), reaper.ImGui_IsItemActive(ctx)
          face.pressed = face.hot and reaper.ImGui_IsMouseClicked(ctx, 0)
          face.id, face.axis, face.pair = id, gap.axis, pair
          face.label = 'Swap ' .. names[a] .. ' and ' .. names[b]
          controls[#controls + 1] = face
          if face.hot or face.held then blocked, highlight = true, pair end
          if clicked then
            result = action({type=geometry.temporary and 'fallback_swap' or 'swap',
              mode=geometry.intended, a=a, b=b})
          end
        else face.held = false end
      end
    end
  end
  for id in pairs(faces) do if not active_faces[id] then faces[id] = nil end end

  -- A temporary layout selects which enabled views occupy its remaining slots.
  -- Its choices never rewrite the full arrangement's remembered positions.
  if geometry.temporary then
    for i, pane in ipairs(geometry.panels) do
      local face = {x0=x+pane.x+M.WINDOW_PAD, y0=y+pane.y+M.WINDOW_PAD,
        id='reference_picker_'..i, picker=true, label=names[pane.id]}
      face.x1 = math.min(x + pane.x + pane.w - M.WINDOW_PAD, face.x0 + M.REFERENCE_PICKER_W)
      face.y1 = math.min(y + pane.y + pane.h, face.y0 + size)
      if face.x1 > face.x0 and face.y1 > face.y0 then
        exclusions[pane.id] = face
        reaper.ImGui_SetCursorScreenPos(ctx, face.x0, face.y0)
        if reaper.ImGui_InvisibleButton(ctx, '##'..face.id, face.x1-face.x0, face.y1-face.y0) then
          reaper.ImGui_OpenPopup(ctx, face.id)
        end
        face.hot, face.held = reaper.ImGui_IsItemHovered(ctx), reaper.ImGui_IsItemActive(ctx)
        blocked = blocked or face.hot or face.held
        controls[#controls + 1] = face
        if reaper.ImGui_BeginPopup(ctx, face.id) then
          for _, id in ipairs(state.reference_panels.enabled) do
            if reaper.ImGui_MenuItem(ctx, names[id], nil, pane.id == id) and id ~= pane.id then
              result = action({type='fallback_swap', a=pane.id, b=id})
            end
          end
          reaper.ImGui_EndPopup(ctx)
        end
      end
    end
  end

  local gap_states = {}
  for i, gap in ipairs(geometry.dividers) do
    local hot, held, activated = false, false, false
    if not blocked and gap.resizable ~= false then
      reaper.ImGui_SetCursorScreenPos(ctx, x + gap.x, y + gap.y)
      reaper.ImGui_InvisibleButton(ctx, '##reference_gap_'..geometry.mode..'_'..geometry.count..'_'..i,
        gap.w, gap.h)
      hot, held = reaper.ImGui_IsItemHovered(ctx), reaper.ImGui_IsItemActive(ctx)
      activated = reaper.ImGui_IsItemActivated(ctx)
    end
    local pointer = gap.axis == 'x' and mx - x or my - y
    if activated then
      local centre = gap.axis == 'x' and gap.x + gap.w / 2 or gap.y + gap.h / 2
      drag = {mode=geometry.mode, intended=geometry.intended, count=geometry.count,
        share=gap.share, offset=pointer-centre, divider=i}
    end
    if hot or held then
      reaper.ImGui_SetMouseCursor(ctx, gap.axis == 'x'
        and reaper.ImGui_MouseCursor_ResizeEW() or reaper.ImGui_MouseCursor_ResizeNS())
    end
    if held and drag and drag.mode == geometry.mode and drag.count == geometry.count then
      local shares = core.drag_shares(geometry, gap.share,
        pointer-drag.offset, width, metrics)
      drag.operation = {type='split', mode=geometry.split_mode or geometry.mode,
        count=geometry.count, share=gap.share, shares=shares, value=shares[gap.share]}
      result = result or action(drag.operation, false)
    end
    gap_states[i] = {hot=hot, held=held}
  end
  if drag and (not reaper.ImGui_IsMouseDown(ctx, 0) or drag.mode ~= geometry.mode
      or drag.count ~= geometry.count) and not result then
    if drag.operation then result = action(drag.operation, true) end
    drag = nil
  end
  return result, {faces=controls, gaps=gap_states, blocked=blocked, highlight=highlight,
    exclusions=exclusions}
end

function panels.paint(ctx, geometry, input, x, y, res, walkthrough_active)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local rounding = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding())
  for i, gap in ipairs(geometry.dividers) do
    local value = input.gaps[i]
    local visible = value.hot or value.held or walkthrough_active
    for _, face in ipairs(input.faces) do
      if not face.picker and face.id:match('_'..i..'_%d+$') then visible = true end
    end
    if visible then
      reaper.ImGui_DrawList_AddRectFilled(dl, x+gap.x, y+gap.y,
        x+gap.x+gap.w, y+gap.y+gap.h, value.held and T.FILL_PRIMARY or T.FILL_SECONDARY)
    end
  end
  if input.highlight then
    for _, index in ipairs(input.highlight) do
      local r = geometry.panels[index]
      reaper.ImGui_DrawList_AddRect(dl, x+r.x+0.5, y+r.y+0.5,
        x+r.x+r.w-0.5, y+r.y+r.h-0.5, T.ACTIVE_CONTROL_BORDER, rounding, 0, 1)
    end
  end
  for _, face in ipairs(input.faces) do
    reaper.ImGui_DrawList_AddRectFilled(dl, face.x0, face.y0, face.x1, face.y1, T.BG_CHROME, rounding)
    if face.hot or face.held then
      reaper.ImGui_DrawList_AddRectFilled(dl, face.x0, face.y0, face.x1, face.y1,
        face.held and T.FILL_PRIMARY or T.FILL_SECONDARY, rounding)
    end
    reaper.ImGui_DrawList_AddRect(dl, face.x0, face.y0, face.x1, face.y1,
      face.hot and T.STROKE_PRIMARY or T.STROKE_SECONDARY, rounding, 0, 1)
    local colour = face.hot and T.TEXT_PRIMARY or T.TEXT_TERTIARY
    local cy = (face.y0 + face.y1) / 2
    if face.picker then
      local _, th = reaper.ImGui_CalcTextSize(ctx, face.label)
      reaper.ImGui_DrawList_AddText(dl, face.x0+M.WINDOW_PAD, cy-th/2, T.TEXT_SECONDARY, face.label)
      icons.paint_glyph(ctx, res and res.icon_font, 'chevron-down',
        face.x1-M.WINDOW_PAD-M.ICON_SM_FS/2, cy, colour, M.ICON_SM_FS)
    else
      icon_motion.paint(ctx, 'reference_swap_'..face.id,
        face.axis == 'y' and 'arrow-up-down' or 'arrow-left-right',
        (face.x0+face.x1)/2, cy, colour, false, face.pressed, true, M.ICON_FS)
    end
    tips.show(ctx, face.hot, face.picker and 'Choose a panel for this position.' or face.label, face.id)
  end
end

return panels
