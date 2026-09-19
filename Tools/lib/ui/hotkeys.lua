-- Hotkeys page for Settings. The REAPER-facing adapter owns shortcut discovery
-- and changes; this module only draws the current mappings and returns intent.

local theme = require("ui.theme")
local icons = require("ui.icons")
local filter = require("core.monitor_filter")
local band_icon = require("ui.filter_band_icon")
local tips = require("ui.tips")
local widgets = require("ui.widgets")
local T = theme.tokens
local M = theme.metrics

local hotkeys = {}

local HAS_WRAP_POS = reaper.ImGui_PushTextWrapPos ~= nil
  and reaper.ImGui_PopTextWrapPos ~= nil
local COMMAND_ICONS = {
  play = "play", pause = "pause", latch = "link", loop = "repeat",
  next = "chevron-right", previous = "chevron-left",
  library = "library", settings = "settings",
}

local SECTION_NAMES = { reference = "Reference View", filters = "Filter Bands", windows = "Windows" }
local function command_is_in_section(command, section)
  return command.section == SECTION_NAMES[section]
end

-- Shortcut fields open the native editor and keep long combinations readable.
local function shortcut_field(ctx, id, shown, detail, width, unassigned)
  local height = reaper.ImGui_GetFrameHeight(ctx)
  local clicked = reaper.ImGui_InvisibleButton(ctx, "##shortcut_field_" .. id, width, height)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
  local x1, y1 = reaper.ImGui_GetItemRectMax(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local rounding = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding())
  local alpha = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha())
  reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, x1, y1,
    theme.fade(hovered and T.FILL_SECONDARY or T.FILL_QUATERNARY, alpha), rounding)
  reaper.ImGui_DrawList_AddRect(dl, x0 + 0.5, y0 + 0.5, x1 - 0.5, y1 - 0.5,
    theme.fade(T.STROKE_SECONDARY, alpha), rounding, 0, 1)

  local text_w = math.max(0, width - M.FRAME_PAD_X * 2)
  local visible = widgets.ellipsize(ctx, shown, text_w)
  local visible_w, text_h = reaper.ImGui_CalcTextSize(ctx, visible)
  reaper.ImGui_DrawList_AddText(dl, math.floor((x0 + x1 - visible_w) * 0.5 + 0.5),
    math.floor((y0 + y1 - text_h) * 0.5 + 0.5),
    theme.fade(unassigned and T.TEXT_QUATERNARY or T.TEXT_PRIMARY, alpha), visible)
  tips.show(ctx, hovered, visible ~= shown and detail or "Click to assign a shortcut")
  return clicked
end

local function command_row(ctx, command, available, first, font, state)
  if not first then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Separator(), T.STROKE_SECONDARY)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_PopStyleColor(ctx)
  end

  local shortcuts = command.shortcuts or {}
  local x0, y0 = reaper.ImGui_GetCursorPos(ctx)
  local sx, sy = reaper.ImGui_GetCursorScreenPos(ctx)
  local avail = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local gap = M.ITEM_SPACING_X
  local row_h = reaper.ImGui_GetFrameHeight(ctx)
  local field_w = math.max(1, math.min(M.FIELD_W - M.FRAME_PAD_X * 6,
    math.floor(avail * 0.4)))
  local command_w = math.max(1, avail - field_w - row_h - gap * 2)
  local icon_w = row_h
  local label_gap = M.ITEM_SPACING_X + M.FRAME_PAD_Y
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local rounding = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding())
  -- These faces identify the toolbar controls; only the shortcut field is editable.
  reaper.ImGui_DrawList_AddRectFilled(dl, sx, sy, sx + icon_w, sy + row_h,
    reaper.ImGui_GetStyleColor(ctx, reaper.ImGui_Col_Button()), rounding)
  reaper.ImGui_DrawList_AddRect(dl, sx + 0.5, sy + 0.5,
    sx + icon_w - 0.5, sy + row_h - 0.5, T.STROKE_SECONDARY, rounding, 0, 1)
  local band_id = command.id:match("^filter_(.+)$")
  if band_id then
    local band = state.monitor_filter and state.monitor_filter.presets[band_id]
    if not band then
      for _, preset in ipairs(filter.PRESETS) do
        if preset.id == band_id then band = preset; break end
      end
    end
    reaper.ImGui_Dummy(ctx, icon_w, row_h)
    if band then band_icon.paint(ctx, band.low_hz, band.high_hz, T.TEXT_SECONDARY) end
  elseif command.id == "mono" then
    -- The transport's Mono face is the same pair of overlapping circles.
    local cx, cy = sx + icon_w * 0.5, sy + row_h * 0.5
    local radius, separation = row_h * 0.2, row_h * 0.13
    reaper.ImGui_DrawList_AddCircle(dl, cx - separation, cy, radius, T.TEXT_SECONDARY, 20, 1.5)
    reaper.ImGui_DrawList_AddCircle(dl, cx + separation, cy, radius, T.TEXT_SECONDARY, 20, 1.5)
  else
    icons.paint_glyph(ctx, font, COMMAND_ICONS[command.id],
      sx + icon_w * 0.5, sy + row_h * 0.5, T.TEXT_SECONDARY,
      M.ICON_FS + M.FRAME_PAD_Y * 0.5)
  end
  local bold = theme.push_bold_font(ctx)
  local full_label = tostring(command.label or command.id or "")
  local label = widgets.ellipsize(ctx, full_label, command_w - icon_w - label_gap)
  local _, text_h = reaper.ImGui_CalcTextSize(ctx, label)
  reaper.ImGui_SetCursorPos(ctx, x0 + icon_w + label_gap,
    y0 + math.floor((row_h - text_h) * 0.5 + 0.5))
  reaper.ImGui_TextColored(ctx, T.TEXT_PRIMARY, label)
  if bold then reaper.ImGui_PopFont(ctx) end
  tips.show(ctx, reaper.ImGui_IsItemHovered(ctx) and label ~= full_label, full_label)

  local action
  for i = 1, math.max(1, #shortcuts) do
    local shortcut = shortcuts[i]
    local id = tostring(command.id) .. "_" .. i
    local y = y0 + (i - 1) * (row_h + M.ITEM_SPACING_Y)
    local description = shortcut and shortcut.description or "Not Assigned"
    reaper.ImGui_SetCursorPos(ctx, x0 + command_w + gap, y)
    if not available then reaper.ImGui_BeginDisabled(ctx) end
    local clicked = shortcut_field(ctx, id, description, description, field_w, not shortcut)
    if not available then reaper.ImGui_EndDisabled(ctx) end
    if clicked and available then
      action = { type = "hotkey_edit", id = command.id,
        index = shortcut and shortcut.index or -1,
        expected_description = shortcut and shortcut.description }
    end

    reaper.ImGui_SetCursorPos(ctx, x0 + command_w + field_w + gap * 2, y)
    local enabled = available and shortcut ~= nil
    if not enabled then reaper.ImGui_BeginDisabled(ctx) end
    local cleared = reaper.ImGui_Button(ctx, "##clear_hotkey_" .. id, row_h, row_h)
    if not icons.paint_over_item(ctx, font, "x",
        { color = T.DANGER_RED, glyph_size = M.ICON_FS + M.FRAME_PAD_Y }) then
      local bx, by = reaper.ImGui_GetItemRectMin(ctx)
      local inset = row_h * 0.3
      local alpha = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha())
      local colour = theme.fade(T.DANGER_RED, alpha)
      reaper.ImGui_DrawList_AddLine(dl, bx + inset, by + inset,
        bx + row_h - inset, by + row_h - inset, colour, M.FRAME_PAD_Y * 0.5)
      reaper.ImGui_DrawList_AddLine(dl, bx + row_h - inset, by + inset,
        bx + inset, by + row_h - inset, colour, M.FRAME_PAD_Y * 0.5)
    end
    if not enabled then reaper.ImGui_EndDisabled(ctx) end
    tips.show(ctx, reaper.ImGui_IsItemHovered(ctx), "Clear shortcut")
    if cleared and enabled then
      action = { type = "hotkey_remove", id = command.id, index = shortcut.index,
        expected_description = shortcut.description }
    end
  end
  return action
end

local function draw_section(ctx, commands, section, title, available, first_group, font, state)
  local action
  local opened, child = widgets.begin_settings_group(ctx,
    "settings_group_hotkeys_" .. section, title, first_group)
  if opened then
    local row_index = 0
    for _, command in ipairs(commands) do
      if command_is_in_section(command, section) then
        row_index = row_index + 1
        local row_action = command_row(ctx, command, available, row_index == 1, font, state)
        action = action or row_action
      end
    end
    widgets.end_settings_group(ctx, child)
  end
  return action
end

function hotkeys.draw(ctx, state, font)
  local hotkey_state = state.hotkeys or {}
  local commands = hotkey_state.commands or {}
  local available = hotkey_state.available == true
  local action

  if not available then
    reaper.ImGui_TextColored(ctx, T.DANGER_RED, "Hotkeys are unavailable.")
    if hotkey_state.error and hotkey_state.error ~= "" then
      local x = reaper.ImGui_GetCursorPosX(ctx)
      local avail = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
      if HAS_WRAP_POS then reaper.ImGui_PushTextWrapPos(ctx, x + avail) end
      reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY, tostring(hotkey_state.error))
      if HAS_WRAP_POS then reaper.ImGui_PopTextWrapPos(ctx) end
    end
  end

  action = draw_section(ctx, commands, "reference", "Reference View", available, true, font, state)
  local filter_action = draw_section(ctx, commands, "filters", "Filter Bands", available, false, font, state)
  action = action or filter_action
  local windows_action = draw_section(ctx, commands, "windows", "Windows", available, false, font, state)
  action = action or windows_action

  reaper.ImGui_SetCursorPosY(ctx,
    reaper.ImGui_GetCursorPosY(ctx) + M.ITEM_SPACING_Y)
  local x = reaper.ImGui_GetCursorPosX(ctx)
  local avail = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  if HAS_WRAP_POS then reaper.ImGui_PushTextWrapPos(ctx, x + avail) end
  reaper.ImGui_TextColored(ctx, T.TEXT_TERTIARY,
    "Click a shortcut to change it in Reaper. Changes stay in sync with the Actions list.")
  if HAS_WRAP_POS then reaper.ImGui_PopTextWrapPos(ctx) end

  return action
end

return hotkeys
