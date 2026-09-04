-- pitchwin: the compact, persistent Pitch panel shared by the Reference View
-- and Library. It is a real window rather than an ImGui popup because the
-- user needs to leave it open while pressing the transport controls.

local theme = require("ui.theme")
local widgets = require("ui.widgets")
local pitch = require("core.pitch")
local focus = require("ui.focus")
local T = theme.tokens
local M = theme.metrics

local pitchwin = {}

local function slot_state()
  return {
    open = false,
    open_request = false,
    anchor_x = nil,
    anchor_y = nil,
    anchor_y1 = nil,
    settle = 0,
    rect = nil,
    editing = false,
    edit_active = false,
    text = "0.0",
    focus = false,
  }
end

-- View-only state. The two audition surfaces keep independent values and
-- independent panels, just as they did when these were temporary popups.
local ui = {
  main = slot_state(),
  browse = slot_state(),
}

local HAS_ENTER = reaper.ImGui_IsKeyPressed ~= nil and reaper.ImGui_Key_Enter ~= nil
local HAS_ESCAPE = reaper.ImGui_IsKeyPressed ~= nil and reaper.ImGui_Key_Escape ~= nil
local HAS_FOCUS = reaper.ImGui_IsWindowFocused ~= nil
local HAS_VIEWPORT = reaper.ImGui_GetMainViewport ~= nil
  and reaper.ImGui_Viewport_GetWorkPos ~= nil and reaper.ImGui_Viewport_GetWorkSize ~= nil
local DECIMAL = reaper.ImGui_InputTextFlags_CharsDecimal
  and reaper.ImGui_InputTextFlags_CharsDecimal() or 0
local HAS_NAV_HIGHLIGHT = reaper.ImGui_Col_NavHighlight ~= nil
local HINT = "Alt-drag for fine control"
local SCALE_LABELS = {
  st = { "-24", "-12", "0", "+12", "+24" },
  percent = { "25", "50", "100", "200", "400" },
}

local function close_slot(slot, s)
  s.open, s.open_request = false, false
  s.editing, s.edit_active, s.focus = false, false, false
  s.rect, s.settle = nil, 0
  widgets.cancel_semitone_drag("pitch_value_" .. slot)
  widgets.cancel_step_slider("pitch_slider_" .. slot)
end

function pitchwin.close()
  for slot, s in pairs(ui) do close_slot(slot, s) end
end

local function begin_edit(s, value, unit)
  s.editing = true
  s.edit_active = false
  s.text = string.format("%.1f", pitch.display(value, unit))
  s.edited = false
  s.focus = true
end

-- Called by the musical-note button. A second press is the panel's ordinary
-- close path, avoiding a separate title bar in this small panel.
function pitchwin.toggle_at(slot, x, y_top, y_bottom)
  local s = ui[slot]
  if not s then return end
  if s.open or s.open_request then
    close_slot(slot, s)
    return
  end
  s.open_request = true
  s.anchor_x, s.anchor_y, s.anchor_y1 = x, y_top, y_bottom
  s.rect, s.settle = nil, 0
  s.editing, s.edit_active, s.focus = false, false, false
end

local function position_opening_window(ctx, s)
  if not s.anchor_x or (s.settle or 0) >= 2 then return end

  local width = M.PITCH_CONTENT_W + M.WINDOW_PAD * 2
  local row_h = reaper.ImGui_GetFrameHeight(ctx) * 2 + M.GROUP_FS
  local small = theme.push_small_font(ctx)
  local hint_h = select(2,
    reaper.ImGui_CalcTextSize(ctx, HINT, nil, nil, false, M.PITCH_CONTENT_W))
  if small then reaper.ImGui_PopFont(ctx) end
  local est_h = row_h + hint_h
    + M.WINDOW_PAD * 2 + M.ITEM_SPACING_Y * 2
  if s.rect then est_h = math.max(est_h, s.rect.h) end

  local left, top, right, bottom
  if HAS_VIEWPORT then
    local viewport = reaper.ImGui_GetMainViewport(ctx)
    left, top = reaper.ImGui_Viewport_GetWorkPos(viewport)
    local vw, vh = reaper.ImGui_Viewport_GetWorkSize(viewport)
    right, bottom = left + vw, top + vh
  end

  local x = s.anchor_x
  if right and x + width > right then x = right - width end
  if left and x < left then x = left end

  local gap = M.PITCH_ANCHOR_GAP
  local y = (s.anchor_y1 or s.anchor_y) + gap
  if bottom and y + est_h > bottom and s.anchor_y - gap - est_h >= top then
    y = s.anchor_y - gap - est_h
  end
  if top and y < top then y = top end
  if bottom and y + est_h > bottom then y = bottom - est_h end

  reaper.ImGui_SetNextWindowPos(ctx, x, y, reaper.ImGui_Cond_Always())
end

local function draw_edit_frame(ctx, value_w)
  local x0, y0 = reaper.ImGui_GetCursorScreenPos(ctx)
  local h = reaper.ImGui_GetFrameHeight(ctx)
  local alpha = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha()))
  local rounding = select(1,
    reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding()))
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, x0 + value_w, y0 + h,
    theme.fade(T.FILL_TERTIARY, alpha), rounding)
  reaper.ImGui_DrawList_AddRect(dl, x0, y0, x0 + value_w, y0 + h,
    theme.fade(T.STROKE_PRIMARY, alpha), rounding, 0, 1)
end

local function draw_value(ctx, slot, s, value, unit)
  local action, escaped_edit
  if s.editing then
    if s.focus then
      reaper.ImGui_SetKeyboardFocusHere(ctx)
      s.focus = false
    end
    reaper.ImGui_SetNextItemWidth(ctx, M.PITCH_VALUE_W)
    draw_edit_frame(ctx, M.PITCH_VALUE_W)
    local frame_pad_x, frame_pad_y = reaper.ImGui_GetStyleVar(ctx,
      reaper.ImGui_StyleVar_FramePadding())
    local text_w = select(1, reaper.ImGui_CalcTextSize(ctx, s.text))
    local centred_pad_x = math.max(frame_pad_x, (M.PITCH_VALUE_W - text_w) * 0.5)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.ACCENT)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(), 0)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(), 0)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgActive(), 0)
    local color_count = 4
    if HAS_NAV_HIGHLIGHT then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_NavHighlight(), 0)
      color_count = color_count + 1
    end
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 0)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(),
      centred_pad_x, frame_pad_y)
    local changed, text = reaper.ImGui_InputText(ctx,
      "##pitch_exact_" .. slot, s.text, DECIMAL)
    reaper.ImGui_PopStyleVar(ctx, 2)
    reaper.ImGui_PopStyleColor(ctx, color_count)
    if changed then
      s.text = text
      s.edited = true
      local typed = pitch.parse(text, unit)
      if typed then
        action = { type = "set_pitch", target = slot, value = typed }
      end
    end
    local active = reaper.ImGui_IsItemActive(ctx)
    local was_active = s.edit_active
    if active then s.edit_active = true end
    local reset = widgets.wants_pitch_reset(ctx)
    local submit = active and HAS_ENTER
      and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter())
    local cancel = active and HAS_ESCAPE
      and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape())
    local deactivated = reaper.ImGui_IsItemDeactivated
      and reaper.ImGui_IsItemDeactivated(ctx)
    local clicked_elsewhere = reaper.ImGui_IsMouseClicked(ctx, 0)
      and not reaper.ImGui_IsItemHovered(ctx)
    -- The panel can briefly report unfocused while SetKeyboardFocusHere is
    -- activating the field. Only treat focus loss as dismissal after the input
    -- has survived at least one genuinely active frame.
    local lost_window_focus = was_active and HAS_FOCUS
      and not reaper.ImGui_IsWindowFocused(ctx)
    if reset then
      action = { type = "set_pitch", target = slot, value = 0 }
      s.editing, s.edit_active, s.focus = false, false, false
    elseif submit then
      local typed = s.edited and pitch.parse(s.text, unit)
      if typed then
        action = { type = "set_pitch", target = slot, value = typed }
      end
      s.editing, s.edit_active = false, false
    elseif cancel then
      s.editing, s.edit_active = false, false
      escaped_edit = true
    elseif deactivated or clicked_elsewhere or lost_window_focus then
      local typed = s.edited and pitch.parse(s.text, unit)
      if typed then
        action = { type = "set_pitch", target = slot, value = typed }
      end
      s.editing, s.edit_active = false, false
    end
  else
    local x0, y0 = reaper.ImGui_GetCursorScreenPos(ctx)
    local h = reaper.ImGui_GetFrameHeight(ctx)
    local changed, _, edit = widgets.semitone_drag(ctx,
      "pitch_value_" .. slot, value, {
        min = pitch.MIN,
        max = pitch.MAX,
        default = 0,
        width = M.PITCH_VALUE_W,
        unit = unit,
        tip = "Drag right or up to raise Pitch; left or down to lower it. Click to type. Ctrl-click or right-click to reset.",
      })
    if changed ~= nil then
      action = { type = "set_pitch", target = slot, value = changed }
    end
    if edit then
      -- This release is becoming a text-entry click, so it must keep keyboard
      -- focus here instead of scheduling the usual handoff back to REAPER.
      focus.keep_zone(x0, y0, x0 + M.PITCH_VALUE_W, y0 + h)
      begin_edit(s, value, unit)
    end
  end
  return action, escaped_edit
end

local function draw_slot(ctx, state, slot)
  local s = ui[slot]
  if s.open_request then
    s.open_request = false
    s.open = true
    s.settle = 0
  end

  local sound
  if slot == "browse" then sound = state.browse else sound = state.selected end
  local host_open = slot ~= "browse" or state.browser_open
  if not sound or not host_open then
    close_slot(slot, s)
    return nil
  end
  if not s.open then return nil end

  local unit = pitch.unit(state.pitch_unit)
  if s.sound_id ~= sound.id or s.unit ~= unit then
    s.editing, s.edit_active, s.focus = false, false, false
    widgets.cancel_semitone_drag("pitch_value_" .. slot)
    widgets.cancel_step_slider("pitch_slider_" .. slot)
    s.sound_id, s.unit = sound.id, unit
  end

  position_opening_window(ctx, s)

  local flags = reaper.ImGui_WindowFlags_NoTitleBar()
    | reaper.ImGui_WindowFlags_NoCollapse()
    | reaper.ImGui_WindowFlags_AlwaysAutoResize()
    | reaper.ImGui_WindowFlags_NoSavedSettings()
  if reaper.ImGui_WindowFlags_NoDocking then
    flags = flags | reaper.ImGui_WindowFlags_NoDocking()
  end

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), T.BG_POPUP)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(), T.STROKE_PRIMARY)
  local visible = reaper.ImGui_Begin(ctx, "##yb_pitch_" .. slot, nil, flags)
  reaper.ImGui_PopStyleColor(ctx, 2)
  if not visible then
    reaper.ImGui_End(ctx)
    return nil
  end

  local wx, wy = reaper.ImGui_GetWindowPos(ctx)
  local ww, wh = reaper.ImGui_GetWindowSize(ctx)
  s.rect = { x = wx, y = wy, w = ww, h = wh }
  s.settle = (s.settle or 0) + 1

  local row_x, row_y = reaper.ImGui_GetCursorPos(ctx)
  reaper.ImGui_Dummy(ctx, M.PITCH_CONTENT_W, 0)
  reaper.ImGui_SetCursorPos(ctx, row_x, row_y)
  local frame_h = reaper.ImGui_GetFrameHeight(ctx)
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_TextColored(ctx, T.TEXT_PRIMARY, "Pitch")
  reaper.ImGui_SetCursorPos(ctx, row_x + M.PITCH_CONTENT_W - M.PITCH_UNIT_W * 2, row_y)
  local changed_unit = widgets.pitch_units(ctx, "pitch_unit_" .. slot, unit)
  local action
  if changed_unit and changed_unit ~= unit then
    action = { type = "set_pitch_unit", value = changed_unit }
    unit, s.unit = changed_unit, changed_unit
    s.editing, s.edit_active, s.focus = false, false, false
  end

  local value = (state.pitch and state.pitch[slot]) or 0
  local slider_w = M.PITCH_CONTENT_W
  local control_y = row_y + frame_h + M.ITEM_SPACING_Y
  reaper.ImGui_SetCursorPos(ctx, row_x, control_y)
  local slider_x, slider_y = reaper.ImGui_GetCursorScreenPos(ctx)
  local changed = widgets.step_slider(ctx, "pitch_slider_" .. slot, value, {
    min = pitch.MIN, max = pitch.MAX, step = 1, tick_step = 12,
    width = slider_w, pitch = true,
  })
  if changed ~= nil then
    value = changed
    action = { type = "set_pitch", target = slot, value = changed }
    s.editing, s.edit_active, s.focus = false, false, false
  end
  -- Submit the slider first so the header value reflects its live movement.
  local value_x = row_x + (M.PITCH_CONTENT_W - M.PITCH_VALUE_W) * 0.5
  reaper.ImGui_SetCursorPos(ctx, value_x, row_y)
  local value_action, escaped_edit = draw_value(ctx, slot, s, value, unit)
  action = action or value_action

  local small = theme.push_small_font(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local labels = SCALE_LABELS[unit]
  local alpha = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha()))
  local track_x = slider_x + M.FADER_KNOB_W * 0.5
  local track_w = slider_w - M.FADER_KNOB_W
  for i = 1, #labels do
    local tw = select(1, reaper.ImGui_CalcTextSize(ctx, labels[i]))
    local tick_x = track_x + track_w * (i - 1) / (#labels - 1)
    -- Centre interior labels on their marks; keep the end labels in the window.
    local x = math.max(slider_x, math.min(slider_x + slider_w - tw, tick_x - tw * 0.5))
    reaper.ImGui_DrawList_AddText(dl, math.floor(x + 0.5), slider_y + frame_h,
      theme.fade(T.TEXT_TERTIARY, alpha), labels[i])
  end
  local hint_w = select(1, reaper.ImGui_CalcTextSize(ctx, HINT))
  reaper.ImGui_SetCursorPos(ctx, row_x + (M.PITCH_CONTENT_W - hint_w) * 0.5,
    control_y + frame_h + M.GROUP_FS + M.ITEM_SPACING_Y)
  reaper.ImGui_PushTextWrapPos(ctx, row_x + M.PITCH_CONTENT_W)
  reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY, HINT)
  reaper.ImGui_PopTextWrapPos(ctx)
  if small then reaper.ImGui_PopFont(ctx) end

  local focused = HAS_FOCUS and reaper.ImGui_IsWindowFocused(ctx)
  if focused and not escaped_edit and not s.editing and HAS_ESCAPE
    and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
    close_slot(slot, s)
    focus.request()
  end

  reaper.ImGui_End(ctx)
  return action
end

function pitchwin.draw(ctx, state)
  local action
  local main_action = draw_slot(ctx, state, "main")
  action = action or main_action
  local browse_action = draw_slot(ctx, state, "browse")
  action = action or browse_action
  return action
end

return pitchwin
