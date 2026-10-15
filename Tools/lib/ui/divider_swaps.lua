-- Divider buttons take input before panel content and paint over it afterwards.
local pairs_geometry = require('core.divider_pairs')
local theme = require('ui.theme')
local icon_motion = require('ui.icon_motion')
local tips = require('ui.tips')
local T, M = theme.tokens, theme.metrics
local swaps = {}
local remembered = {}

local function contains(x, y, left, top, right, bottom)
  return x >= left and x <= right and y >= top and y <= bottom
end

function swaps.input(ctx, id, panels, dividers, x, y, names)
  local previous, current = remembered[id] or {}, {}
  local input = {faces={}, blocked=false, highlights={}}
  local result
  local mx, my = reaper.ImGui_GetMousePos(ctx)
  local hot_window = reaper.ImGui_IsWindowHovered(ctx)
  local size = reaper.ImGui_GetFrameHeight(ctx)
  for _, segment in ipairs(pairs_geometry.measure(panels, dividers)) do
    local key = id .. '_' .. segment.key
    local face = previous[key] or {}
    current[key] = face
    local horizontal = segment.axis == 'y'
    local length = horizontal and segment.w or segment.h
    local side = math.min(size, length)
    face.x0 = x + segment.x + (segment.w-side)/2
    face.y0 = y + segment.y + (segment.h-side)/2
    face.x1, face.y1 = face.x0+side, face.y0+side
    local divider = segment.divider
    local gap_hot = hot_window and contains(mx, my, x+divider.x, y+divider.y,
      x+divider.x+divider.w, y+divider.y+divider.h)
    face.visible = gap_hot or (face.visible and hot_window
      and contains(mx, my, face.x0, face.y0, face.x1, face.y1)) or face.held == true
    face.hot, face.pressed = false, false
    face.segment, face.id = segment, key
    face.gap = {x0=x+segment.x,y0=y+segment.y,
      x1=x+segment.x+segment.w,y1=y+segment.y+segment.h}
    if face.visible then
      reaper.ImGui_SetCursorScreenPos(ctx, face.x0, face.y0)
      local clicked = reaper.ImGui_InvisibleButton(ctx, '##divider_swap_' .. key, side, side)
      face.hot, face.held = reaper.ImGui_IsItemHovered(ctx), reaper.ImGui_IsItemActive(ctx)
      face.pressed = face.hot and reaper.ImGui_IsMouseClicked(ctx, 0)
      face.label = 'Swap ' .. names[segment.a] .. ' and ' .. names[segment.b]
      input.faces[#input.faces+1] = face
      if face.hot or face.held then
        input.blocked = true
        reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Arrow())
        for _, pane in ipairs(panels) do
          if pane.id == segment.a or pane.id == segment.b then
            local top = pane.header and pane.header.y or pane.y
            input.highlights[#input.highlights+1] = {
              x0=x+pane.x, y0=y+top, x1=x+pane.x+pane.w, y1=y+pane.y+pane.h,
            }
          end
        end
      end
      if clicked then result = {a=segment.a, b=segment.b} end
    else
      face.held = false
    end
  end
  remembered[id] = current
  return result, input
end

function swaps.paint(ctx, input)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local rounding = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding())
  local alpha = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha())
  for _, face in ipairs(input.faces) do
    if face.hot or face.held then
      local gap = face.gap
      reaper.ImGui_DrawList_AddRectFilled(dl, gap.x0, gap.y0, gap.x1, gap.y1,
        theme.fade(T.FILL_SECONDARY, alpha))
    end
  end
  for _, pane in ipairs(input.highlights) do
    reaper.ImGui_DrawList_AddRect(dl, pane.x0+.5, pane.y0+.5, pane.x1-.5, pane.y1-.5,
      theme.fade(T.ACTIVE_CONTROL_BORDER, alpha), rounding, 0, theme.scale)
  end
  for _, face in ipairs(input.faces) do
    reaper.ImGui_DrawList_AddRectFilled(dl, face.x0, face.y0, face.x1, face.y1,
      theme.fade(T.BG_CHROME, alpha), rounding)
    if face.hot or face.held then
      reaper.ImGui_DrawList_AddRectFilled(dl, face.x0, face.y0, face.x1, face.y1,
        theme.fade(face.held and T.FILL_PRIMARY or T.FILL_SECONDARY, alpha), rounding)
    end
    reaper.ImGui_DrawList_AddRect(dl, face.x0, face.y0, face.x1, face.y1,
      theme.fade(face.hot and T.STROKE_PRIMARY or T.STROKE_SECONDARY, alpha), rounding, 0, theme.scale)
    icon_motion.paint(ctx, 'divider_swap_' .. face.id,
      face.segment.axis == 'y' and 'arrow-up-down' or 'arrow-left-right',
      (face.x0+face.x1)/2, (face.y0+face.y1)/2,
      face.hot and T.TEXT_PRIMARY or T.TEXT_TERTIARY,
      false, face.pressed, true, M.ICON_FS)
    tips.show(ctx, face.hot, face.label, face.id)
  end
end

return swaps
