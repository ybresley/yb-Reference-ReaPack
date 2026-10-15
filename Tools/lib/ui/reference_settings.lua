-- Reference View choices inside Settings. This screen reads saved preferences
-- and returns intent; the entry script applies and saves each operation.
local theme = require("ui.theme")
local widgets = require("ui.widgets")
local tips = require("ui.tips")
local reference_layout = require("core.reference_layout")
local T, M = theme.tokens, theme.metrics

local reference_settings = {}

local MODES = {
  { id = "auto", label = "Auto" },
  { id = "horizontal", label = "Side by Side" },
  { id = "vertical", label = "Stacked" },
  { id = "top", label = "Wide Top" },
  { id = "bottom", label = "Wide Bottom" },
  { id = "left", label = "Tall Left" },
  { id = "right", label = "Tall Right" },
}
local PANELS = {
  { id = "waveform", label = "Waveform" },
  { id = "spectrum", label = "Spectrum" },
  { id = "stereo", label = "Stereo" },
}
local PANEL_NAMES = { waveform = "Waveform", spectrum = "Spectrum", stereo = "Stereo" }
local swap_panel

local function enabled(enabled, id)
  for _, panel in ipairs(enabled) do if panel == id then return true end end
  return false
end

local function operation(value)
  return { type = "reference_panels", operation = value }
end

local function rects(mode, count, width, height, gap, shares, order, stereo_aspect)
  local geometry = reference_layout.geometry(mode, count, width, height, shares,
    { gap = gap, min_width = 0, min_height = 0,
      stereo_aspect = stereo_aspect }, order)
  return geometry and geometry.rects or {}
end

local function draw_mini(ctx, mode, x, y, colour, stereo_stack)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local width, height = M.SET_LAYOUT_MINI_W, M.SET_LAYOUT_MINI_H
  if mode == "auto" then
    local inset = height * 0.25
    reaper.ImGui_DrawList_AddRect(dl, x + inset, y + inset,
      x + width - inset, y + height - inset, colour, 2, 0, 1)
    return
  end
  if mode == "vertical" and stereo_stack then mode = "right" end
  for _, rect in ipairs(rects(mode, 3, width, height, M.SET_LAYOUT_MINI_GAP)) do
    reaper.ImGui_DrawList_AddRectFilled(dl,
      x + rect.x, y + rect.y, x + rect.x + rect.w, y + rect.y + rect.h,
      colour, 1)
  end
end

local function layout_choice(ctx, option, selected, width, stereo_stack)
  local pushed = widgets.push_soft_active(ctx, selected)
  local clicked = reaper.ImGui_Button(ctx, "##reference_mode_" .. option.id,
    width, M.SET_LAYOUT_CHOICE_H)
  widgets.pop_soft_active(ctx, pushed)
  local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
  local x1 = select(1, reaper.ImGui_GetItemRectMax(ctx))
  local mini_y = y0 + M.FRAME_PAD_X
  local alpha = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha())
  local colour = theme.fade(selected and T.ACCENT_HOVER or T.TEXT_TERTIARY, alpha)
  draw_mini(ctx, option.id, x0 + (x1 - x0 - M.SET_LAYOUT_MINI_W) * 0.5,
    mini_y, colour, stereo_stack)
  local text_w = select(1, reaper.ImGui_CalcTextSize(ctx, option.label))
  reaper.ImGui_DrawList_AddText(reaper.ImGui_GetWindowDrawList(ctx),
    x0 + (x1 - x0 - text_w) * 0.5,
    mini_y + M.SET_LAYOUT_MINI_H + M.FRAME_PAD_Y,
    theme.fade(selected and T.ACCENT_HOVER or T.TEXT_SECONDARY, alpha), option.label)
  return clicked
end

local function intended_mode(layout, active_mode)
  local mode = active_mode or layout.mode
  if layout.orders and layout.orders[mode] then return mode end
  return "horizontal"
end

local function mode_label(mode)
  for _, option in ipairs(MODES) do
    if option.id == mode then return option.label end
  end
  return "Side by Side"
end

local function panel_choices(ctx, layout, begin_setting, setting_label)
  local action
  begin_setting(ctx)
  setting_label(ctx, "Show Panels")
  for i, panel in ipairs(PANELS) do
    if i > 1 then reaper.ImGui_SameLine(ctx, 0, M.SET_LAYOUT_GRID_GAP) end
    local shown = enabled(layout.enabled, panel.id)
    local last = shown and #layout.enabled == 1
    if last then reaper.ImGui_BeginDisabled(ctx) end
    local changed, checked = reaper.ImGui_Checkbox(ctx,
      panel.label .. "##reference_panel_" .. panel.id, shown)
    if last then reaper.ImGui_EndDisabled(ctx) end
    if changed then
      action = operation({ type = "toggle_panel", id = panel.id, enabled = checked })
    end
    local hovered = reaper.ImGui_IsItemHovered(ctx,
      reaper.ImGui_HoveredFlags_AllowWhenDisabled
      and reaper.ImGui_HoveredFlags_AllowWhenDisabled() or 0)
    tips.show(ctx, last and hovered,
      "Keep at least one panel visible.")
  end
  return action
end

local function layout_choices(ctx, layout, begin_setting, setting_label, setting_note)
  local action
  begin_setting(ctx)
  setting_label(ctx, "Panel Layout")
  local avail = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  for i, option in ipairs(MODES) do
    local columns = i <= 3 and 3 or 4
    local width = (avail - M.SET_LAYOUT_GRID_GAP * (columns - 1)) / columns
    if i > 1 and i ~= 4 then
      reaper.ImGui_SameLine(ctx, 0, M.SET_LAYOUT_GRID_GAP)
    end
    if layout_choice(ctx, option, layout.mode == option.id, width, #layout.enabled == 3) then
      action = operation({ type = "set_mode", mode = option.id })
    end
  end
  setting_note(ctx, layout.mode == "auto"
    and "Auto adapts to the available width and height."
    or "Keeps this layout when enough room is available.")
  return action
end

local function position_choices(ctx, layout, mode, stereo_aspect,
    begin_setting, setting_label, setting_note)
  local action
  begin_setting(ctx)
  local x0 = reaper.ImGui_GetCursorPosX(ctx)
  local width = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  setting_label(ctx, "Panel Positions")
  local label = mode_label(mode)
  local label_w = select(1, reaper.ImGui_CalcTextSize(ctx, label))
  reaper.ImGui_SameLine(ctx, x0 + width - label_w)
  reaper.ImGui_TextColored(ctx, T.TEXT_TERTIARY, label)

  local visible = reference_layout.panel_order(layout, mode)
  local px, py = reaper.ImGui_GetCursorScreenPos(ctx)
  reaper.ImGui_Dummy(ctx, width, M.SET_LAYOUT_PREVIEW_H)
  local shares = layout.splits and layout.splits[mode .. "_" .. #visible]
  for i, rect in ipairs(rects(mode, #visible, width,
      M.SET_LAYOUT_PREVIEW_H, M.SET_LAYOUT_GRID_GAP, shares, visible,
      stereo_aspect)) do
    local id = visible[i]
    if id then
      reaper.ImGui_SetCursorScreenPos(ctx, px + rect.x, py + rect.y)
      if #visible == 1 then reaper.ImGui_BeginDisabled(ctx) end
      local clicked = reaper.ImGui_Button(ctx,
        PANEL_NAMES[id] .. "##reference_position_" .. i, rect.w, rect.h)
      if #visible == 1 then reaper.ImGui_EndDisabled(ctx) end
      if clicked then
        swap_panel = id
        reaper.ImGui_OpenPopup(ctx, "reference_position_swap")
      end
    end
  end
  reaper.ImGui_SetCursorScreenPos(ctx, px,
    py + M.SET_LAYOUT_PREVIEW_H + M.ITEM_SPACING_Y)
  if reaper.ImGui_BeginPopup(ctx, "reference_position_swap") then
    reaper.ImGui_TextColored(ctx, T.TEXT_TERTIARY,
      "Swap " .. (PANEL_NAMES[swap_panel] or "Panel") .. " With")
    for _, panel in ipairs(PANELS) do
      if panel.id ~= swap_panel and enabled(layout.enabled, panel.id) then
        local valid = reference_layout.can_swap(layout, mode, swap_panel, panel.id)
        if not valid then reaper.ImGui_BeginDisabled(ctx) end
        local clicked = reaper.ImGui_MenuItem(ctx, panel.label)
        if not valid then reaper.ImGui_EndDisabled(ctx) end
        if clicked and valid then
          action = operation({ type = "swap", mode = mode,
            a = swap_panel, b = panel.id })
        end
        local hovered = reaper.ImGui_IsItemHovered(ctx,
          reaper.ImGui_HoveredFlags_AllowWhenDisabled
          and reaper.ImGui_HoveredFlags_AllowWhenDisabled() or 0)
        tips.show(ctx, not valid and hovered, mode == "vertical"
          and "Stereo stays beside the stacked panels." or "Stereo stays in a smaller position.")
      end
    end
    reaper.ImGui_EndPopup(ctx)
  end
  local note = "Click a panel to swap its position."
  if #visible == 3 then
    if mode == "top" or mode == "bottom" then
      note = "Stereo stays in a smaller position. Click a panel to swap positions."
    elseif mode == "vertical" then
      note = "Stereo stays beside Waveform and Spectrum. Click either stacked panel to swap them."
    end
  end
  setting_note(ctx, note)
  return action
end

function reference_settings.draw(ctx, state, begin_setting, setting_label, setting_note)
  local action
  local layout = state.reference_panels
  if not layout or not layout.enabled or not layout.orders then
    begin_setting(ctx)
    setting_note(ctx, state.reference_panels_error
      or "Panel settings are unavailable.")
    if reaper.ImGui_Button(ctx, "Reset Panel Layout") then
      return action or operation({ type = "reset" })
    end
    return action
  end
  local error_message = state.reference_panels_error
  local mode = intended_mode(layout, state.reference_panel_mode)
  if error_message then reaper.ImGui_BeginDisabled(ctx) end
  local panel_action = panel_choices(ctx, layout, begin_setting, setting_label)
  action = action or panel_action
  local layout_action = layout_choices(ctx, layout,
    begin_setting, setting_label, setting_note)
  action = action or layout_action
  local position_action = position_choices(ctx, layout, mode,
    state.stereo_view == "polar_sample" and 2 or 1,
    begin_setting, setting_label, setting_note)
  action = action or position_action
  if error_message then
    reaper.ImGui_EndDisabled(ctx)
    setting_note(ctx, error_message)
    if reaper.ImGui_Button(ctx, "Reset Panel Layout") then
      action = action or operation({ type = "reset" })
    end
  end
  return action
end

return reference_settings
