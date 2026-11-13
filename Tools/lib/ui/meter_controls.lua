local widgets = require('ui.widgets')
local tips = require('ui.tips')
local settings = require('ui.meter_settings')
local theme = require('ui.theme')

local controls = {}
local R = reaper

function controls.draw(ctx, model, x, y, width, res, history_hidden, bounds, readings_hidden)
  local size = R.ImGui_GetFrameHeight(ctx)
  local open = settings.is_open()
  local hovered_panel = R.ImGui_IsWindowHovered(ctx,
    R.ImGui_HoveredFlags_AllowWhenBlockedByActiveItem())
    and R.ImGui_IsMouseHoveringRect(ctx,bounds.x,bounds.y,
      bounds.x+bounds.w,bounds.y+bounds.h)
  if not (hovered_panel or open or model.hold or model.preference_error) then return end
  R.ImGui_SetCursorScreenPos(ctx, x + width - size, y)
  local clicked, hovered = widgets.plot_settings_button(ctx, res and res.icon_font,
    'meter_menu', open)
  local left, top = R.ImGui_GetItemRectMin(ctx)
  local right, bottom = R.ImGui_GetItemRectMax(ctx)
  settings.update_anchor({left=left, top=top, right=right, bottom=bottom})
  if clicked then
    settings.toggle()
  end
  local hint = 'Loudness Settings'
  if model.preference_error then
    local radius = theme.metrics.UPDATE_DOT_R
    R.ImGui_DrawList_AddCircleFilled(R.ImGui_GetWindowDrawList(ctx),
      right-radius, top+radius, radius, theme.tokens.TEXT_PRIMARY)
    hint = hint..'. Using default settings.'
  elseif history_hidden and readings_hidden then
    hint = hint..'. Enlarge the view to show history and extra readings.'
  elseif history_hidden then
    hint = hint..'. Enlarge the view to show history.'
  elseif readings_hidden then
    hint = hint..'. Enlarge the view to show extra readings.'
  end
  tips.show(ctx, hovered and not settings.is_open(), hint, 'meter_controls',
    tips.rect(left, top, right - left, bottom - top))
end

function controls.draw_panel(ctx, model, res)
  return settings.draw_panel(ctx, model, res)
end

return controls
