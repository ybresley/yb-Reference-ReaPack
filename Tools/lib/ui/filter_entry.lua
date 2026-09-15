-- Exact listening-range entry shared by the pencil and spectrum handles.
local theme = require("ui.theme")
local tips = require("ui.tips")
local icons = require("ui.icons")
local filter = require("core.monitor_filter")
local focus = require("ui.focus")
local anchored_panel = require("ui.anchored_panel")
local numeric_input = require("ui.numeric_input")
local T, M = theme.tokens, theme.metrics
local entry = {}
local ui = { open = false }

function entry.open_at(x, y_top, y_bottom, boundary)
  ui = { open = true, opening = true, x = x, y_top = y_top, y_bottom = y_bottom or y_top,
    boundary = boundary or "low", low = {}, high = {} }
end

function entry.is_open() return ui.open end
function entry.close() ui.open = false end

-- Plain InputText keeps the live buffer available for both Enter and blur
-- commits. Whole-Hz boundaries reject every non-digit as it is entered.
function entry.field(ctx, id, draft, current, width, take_focus)
  if not draft.dirty and not draft.active then draft.text = tostring(current) end
  if take_focus then reaper.ImGui_SetKeyboardFocusHere(ctx) end
  reaper.ImGui_SetNextItemWidth(ctx, width)
  local changed, text = numeric_input.text(ctx, "##" .. id, draft.text, "digits")
  if changed then draft.text, draft.dirty = text, true end
  local active = reaper.ImGui_IsItemActive(ctx)
  local enter = active and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter())
  local submit = draft.dirty and (enter or (draft.active and not active))
  draft.active = active
  tips.show(ctx, reaper.ImGui_IsItemHovered(ctx), "Enter a whole number of Hz, for example 700.", id)
  return submit
end

function entry.accept(draft, value)
  draft.text, draft.dirty = tostring(value), false
end

function entry.position(ctx, res, x, y_top, y_bottom, width, height)
  local work = anchored_panel.work_area(ctx, res, {
    left = x,
    top = y_top,
    right = x,
    bottom = y_bottom,
  })
  x = math.max(work.left, math.min(x, work.right - width))
  local y = math.max(work.top,
    math.min(y_bottom + M.FILTER_ANCHOR_GAP, work.bottom - height))
  reaper.ImGui_SetNextWindowPos(ctx, x, y, reaper.ImGui_Cond_Always())
end

local function draw_contents(ctx, value, res, view)
  local width = M.FILTER_ENTRY_W
  local reset_size = M.ICON_FS + 4 * theme.scale
  local system = value.system or {}
  local current_low = value.on and value.low_hz or filter.MIN_HZ
  local current_high = value.on and value.high_hz or (system.max_filter_hz or filter.MAX_HZ)
  local action, closed
  reaper.ImGui_TextColored(ctx, T.TEXT_PRIMARY, "Filter Range")
  reaper.ImGui_SameLine(ctx, width - M.WINDOW_PAD - reset_size)
  local reset = false
  if value.on then
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), 0, 0)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 0)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), T.FILL_QUATERNARY)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), T.FILL_TERTIARY)
    reset = icons.button(ctx, res and res.icon_font, "filter_range_reset", "rotate-ccw", {
      size = reset_size, glyph_size = M.ICON_FS, color = T.ACCENT,
      fallback = icons.draw_reset, tip = "Return to Full" })
    reaper.ImGui_PopStyleColor(ctx, 3)
    reaper.ImGui_PopStyleVar(ctx, 2)
  else
    reaper.ImGui_Dummy(ctx, reset_size, reset_size)
  end
  local field_w = (width - M.WINDOW_PAD * 2 - M.ITEM_SPACING_X) / 2
  -- Submit matching rows together so an input's text baseline cannot shift
  -- the neighbouring column's label and field downwards.
  reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY, "Low (Hz)")
  reaper.ImGui_SameLine(ctx, M.WINDOW_PAD + field_w + M.ITEM_SPACING_X)
  reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY, "High (Hz)")
  local low_submit = entry.field(ctx, "filter_range_low", view.low, current_low,
    field_w, view.opening and view.boundary == "low")
  reaper.ImGui_SameLine(ctx, 0, M.ITEM_SPACING_X)
  local high_submit = entry.field(ctx, "filter_range_high", view.high, current_high,
    field_w, view.opening and view.boundary == "high")
  view.opening = false
  if low_submit or high_submit then
    local next_value = filter.set_range(value, view.low.text, view.high.text)
    if next_value and system.max_filter_hz and next_value.high_hz > system.max_filter_hz then
      next_value = nil
    end
    if next_value and system.available then
      action = { type = "set_monitor_filter_range", low_hz = next_value.low_hz,
        high_hz = next_value.high_hz }
      entry.accept(view.low, next_value.low_hz)
      entry.accept(view.high, next_value.high_hz)
    else
      -- Invalid entries return to the active range. A helper failure is
      -- already described by the spectrum's helper-status surface.
      entry.accept(view.low, current_low)
      entry.accept(view.high, current_high)
    end
  end
  if reset then
    -- Reset wins over a field's blur commit from the same click.
    action = { type = "monitor_filter_full_range" }
    view.low, view.high = {}, {}
  end
  reaper.ImGui_SetCursorPosX(ctx, width - M.WINDOW_PAD - M.POPUP_BTN_W)
  if reaper.ImGui_Button(ctx, "Done##filter_range", M.POPUP_BTN_W) then closed = true end
  return action, closed
end

local function window_height(ctx)
  local line = reaper.ImGui_GetTextLineHeight(ctx)
  local frame = reaper.ImGui_GetFrameHeight(ctx)
  local title_h = math.max(M.ICON_FS + 4 * theme.scale, line)
  return title_h + line + 2 * frame + 3 * M.ITEM_SPACING_Y + 2 * M.WINDOW_PAD
end

function entry.draw(ctx, state, res)
  if not ui.open then return end
  local value = state.monitor_filter
  local system = value.system or {}
  local width = M.FILTER_ENTRY_W
  local height = window_height(ctx)
  local current_low = value.on and value.low_hz or filter.MIN_HZ
  local current_high = value.on and value.high_hz or (system.max_filter_hz or filter.MAX_HZ)
  if ui.opening then
    entry.position(ctx, res, ui.x, ui.y_top, ui.y_bottom, width, height)
    entry.accept(ui.low, current_low)
    entry.accept(ui.high, current_high)
  end
  reaper.ImGui_SetNextWindowSize(ctx, width, 0, reaper.ImGui_Cond_Always())
  local flags = reaper.ImGui_WindowFlags_NoTitleBar() | reaper.ImGui_WindowFlags_NoResize()
    | reaper.ImGui_WindowFlags_NoCollapse() | reaper.ImGui_WindowFlags_NoSavedSettings()
    | reaper.ImGui_WindowFlags_NoDocking() | reaper.ImGui_WindowFlags_AlwaysAutoResize()
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), T.BG_POPUP)
  local visible = reaper.ImGui_Begin(ctx, "##yb_filter_range", nil, flags)
  reaper.ImGui_PopStyleColor(ctx)
  local action
  if visible then
    local dismiss = anchored_panel.dismissed(ctx, ui)
    local closed
    action, closed = draw_contents(ctx, value, res, ui)
    if closed then entry.close() end
    if dismiss then entry.close() end
    if reaper.ImGui_IsWindowFocused(ctx) and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
      entry.close(); focus.request()
    end
    reaper.ImGui_End(ctx)
  end
  return action
end

return entry
