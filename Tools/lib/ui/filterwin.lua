-- Shared Spectrum / Filter settings stay open without blocking playback.
local theme = require("ui.theme")
local widgets = require("ui.widgets")
local filter = require("core.monitor_filter")
local entry = require("ui.filter_entry")
local icons = require("ui.icons")
local focus = require("ui.focus")
local actions = require("core.actions")
local helper_status = require("core.monitor_helper_status")
local hover_peaks = require("ui.spectrum_hover")
local tips = require("ui.tips")
local anchored_panel = require("ui.anchored_panel")
local release_settings_layout = require("core.release_settings_layout")
local T, M = theme.tokens, theme.metrics
local filterwin = {}
local ui = { open = false, drafts = {}, tab = "spectrum" }
local first_group = true

local SPECTRUM_GROUPS = {
  { id = "frequency", title = "Frequency", items = {
    { "resolution", "Resolution" }, { "smoothing", "Smoothing" } } },
  { id = "time", title = "Time", items = {
    { "speed", "Speed" }, { "average", "Average" }, { "hover_peaks", "Hover Peaks" } } },
  { id = "levels", title = "Levels", items = {
    { "range", "Range" }, { "tilt", "Tilt" } } },
}

local OPTIONS = {
  resolution = { "Responsive", "Balanced", "Detailed", values = { "responsive", "balanced", "detailed" } },
  speed = { "Fast", "Balanced", "Smooth", values = { "fast", "balanced", "smooth" } },
  smoothing = { "Off", "1/24 octave", "1/12 octave", "1/6 octave", values = { "off", "1/24", "1/12", "1/6" } },
  average = { "Off", "1 s", "3 s", "Infinite", values = { "off", "1s", "3s", "infinite" } },
  hover_peaks = { "On", "Off", values = { "hold", "off" } },
  range = { "60 dB", "90 dB", "120 dB", values = { 60, 90, 120 } },
  tilt = { "Flat", "3 dB/oct", "4.5 dB/oct", values = { 0, 3, 4.5 } },
  slope = { "12 dB/oct", "24 dB/oct", "36 dB/oct", "48 dB/oct", values = { 12, 24, 36, 48 } },
}
-- One terminator per item; an extra terminator becomes a blank menu option.
for _, option in pairs(OPTIONS) do option.items = table.concat(option, "\0") .. "\0" end

local LABEL_TIPS = {
  resolution = "Sets how finely nearby frequencies are separated.\n"
    .. "More detail needs a longer slice of audio, so it reacts less quickly.",
  smoothing = "Smooths differences between neighbouring frequencies.\n"
    .. "Wider smoothing makes the shape easier to read but hides narrow peaks.",
  speed = "Sets how quickly the live trace falls after levels drop.",
  average = "Adds an averaged trace. Longer times smooth out brief changes.\n"
    .. "Infinite accumulates until history is cleared or the source changes.",
  hover_peaks = "Holds and highlights peaks while you hover over the spectrum.",
  range = "Sets the lowest displayed level, from -60 to -120 dB.\n"
    .. "A larger range reveals quieter detail without changing the audio.",
  tilt = "Adjusts the displayed balance between low and high frequencies.\n"
    .. "Higher values emphasise highs without changing the audio.",
}

function filterwin.is_open() return ui.open or entry.is_open() end
function filterwin.panel_is_open() return ui.open end
function filterwin.close() ui.open, ui.closing = false, nil end
function filterwin.toggle_at(x, y_top, y_bottom)
  if ui.open then ui.closing = true; return end
  entry.close()
  ui.open, ui.opening, ui.x = true, true, x
  ui.y_top, ui.y_bottom = y_top, y_bottom or y_top
  ui.drafts, ui.error, ui.closing = {}, nil, nil
end

local function combo(ctx, key, value, width, fixed, targets)
  if key == "hover_peaks" and not fixed then value = hover_peaks.get_mode() end
  reaper.ImGui_SetNextItemWidth(ctx, width)
  local options, selected = OPTIONS[key], 0
  for i, candidate in ipairs(options.values) do if value == candidate then selected = i - 1 end end
  local changed, index = reaper.ImGui_Combo(ctx, "##spectrum_setting_" .. key, selected, options.items)
  if targets then
    local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
    local x1, y1 = reaper.ImGui_GetItemRectMax(ctx)
    local point = targets[key]
    if not point then point = {}; targets[key] = point end
    point.x, point.y = (x0 + x1) * 0.5, (y0 + y1) * 0.5
    point.x0, point.y0, point.x1, point.y1 = x0, y0, x1, y1
  end
  if key == "hover_peaks" then
    tips.show(ctx, reaper.ImGui_IsItemHovered(ctx),
      "Hold the pointer over the spectrum to highlight its peaks.", "spectrum_hover_peaks")
  end
  if changed and not fixed then
    if key == "hover_peaks" then hover_peaks.set_mode(options.values[index + 1]); return end
    return { type = "set_spectrum_preference", key = key, value = options.values[index + 1] }
  end
end

local function settings_group(ctx, id, title, draw)
  local opened, child = widgets.begin_settings_group(ctx, "spectrum_settings_group_" .. id,
    title, first_group)
  first_group = false
  local result
  if opened then result = draw() end
  widgets.end_settings_group(ctx, child)
  return result
end

local function option_row(ctx, key, label, value, width, control_width, fixed, targets)
  control_width = control_width or M.SPECTRUM_OPTION_W
  local x = reaper.ImGui_GetCursorPosX(ctx)
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY, label)
  tips.show(ctx, reaper.ImGui_IsItemHovered(ctx), LABEL_TIPS[key])
  reaper.ImGui_SameLine(ctx, x + width - control_width)
  return combo(ctx, key, value, control_width, fixed, targets)
end

local function spectrum_tab(ctx, prefs, fixed, targets)
  first_group = true
  local action
  for _, group in ipairs(SPECTRUM_GROUPS) do
    local group_action = settings_group(ctx, group.id, group.title, function()
      local width = reaper.ImGui_GetContentRegionAvail(ctx)
      local result
      for _, item in ipairs(group.items) do
        result = actions.combine(result,
          option_row(ctx, item[1], item[2], prefs[item[1]], width, nil, fixed, targets))
      end
      return result
    end)
    action = actions.combine(action, group_action)
  end
  return action
end

local function commit_preset(value, preset_id, drafts)
  local next_value, err = filter.edit_preset(value, preset_id, drafts.low.text, drafts.high.text)
  ui.error = err
  if next_value then
    local edited = next_value.presets[preset_id]
    entry.accept(drafts.low, edited.low_hz)
    entry.accept(drafts.high, edited.high_hz)
    return { type = "edit_monitor_filter_preset", id = preset_id,
      low_hz = edited.low_hz, high_hz = edited.high_hz }
  end
end

local function finish_preset_focus(value)
  -- A tab switch stops submitting the old tab's fields. Commit its active
  -- draft here so leaving via a tab has the same meaning as ordinary blur.
  for _, preset in ipairs(filter.PRESETS) do
    local drafts = ui.drafts[preset.id]
    if drafts and ((drafts.low.active and drafts.low.dirty)
        or (drafts.high.active and drafts.high.dirty)) then
      drafts.low.active, drafts.high.active = false, false
      return commit_preset(value, preset.id, drafts)
    end
  end
end

local function filter_tab(ctx, value, draft_store)
  draft_store = draft_store or ui.drafts
  first_group = true
  local action
  action = actions.combine(action, settings_group(ctx, "presets", "Presets", function()
    local frame = reaper.ImGui_GetFrameHeight(ctx)
    local x, y = reaper.ImGui_GetCursorPos(ctx)
    local width = reaper.ImGui_GetContentRegionAvail(ctx)
    local high_x = x + width - M.FILTER_FIELD_W
    local low_x = high_x - M.ITEM_SPACING_X - M.FILTER_FIELD_W
    local reset_x = low_x - M.ITEM_SPACING_X - M.FILTER_RESTORE_W
    local heading = reaper.ImGui_GetTextLineHeight(ctx) + M.ITEM_SPACING_Y
    local heading_font = theme.push_bold_font(ctx)
    reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY, "Preset")
    reaper.ImGui_SetCursorPos(ctx, low_x, y)
    reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY, "Low (Hz)")
    reaper.ImGui_SetCursorPos(ctx, high_x, y)
    reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY, "High (Hz)")
    if heading_font then reaper.ImGui_PopFont(ctx) end
    reaper.ImGui_SetCursorPos(ctx, x, y + heading)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Separator(), T.STROKE_SECONDARY)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_PopStyleColor(ctx)
    heading = reaper.ImGui_GetCursorPosY(ctx) - y
    local result
    for i, preset in ipairs(filter.PRESETS) do
      local row_y = y + heading + (i - 1) * (frame + M.ITEM_SPACING_Y)
      local saved = value.presets[preset.id]
      local drafts = draft_store[preset.id] or { low = {}, high = {} }
      draft_store[preset.id] = drafts
      reaper.ImGui_SetCursorPos(ctx, x, row_y + M.FRAME_PAD_Y)
      reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY, preset.label)
      if filter.preset_changed(value, preset.id) then
        reaper.ImGui_SetCursorPos(ctx, reset_x, row_y)
        if icons.button(ctx, nil, "restore_preset_" .. preset.id, "rotate-ccw", {
            size = M.FILTER_RESTORE_W, fallback = icons.draw_reset,
            tip = "Restore " .. preset.label .. " default" }) then
          result = actions.combine(result,
            { type = "restore_monitor_filter_preset", id = preset.id })
          ui.drafts[preset.id], ui.error = nil, nil
        end
      end
      reaper.ImGui_SetCursorPos(ctx, low_x, row_y)
      local low_submit = entry.field(ctx, "preset_" .. preset.id .. "_low",
        drafts.low, saved.low_hz, M.FILTER_FIELD_W)
      reaper.ImGui_SetCursorPos(ctx, high_x, row_y)
      local high_submit = entry.field(ctx, "preset_" .. preset.id .. "_high",
        drafts.high, saved.high_hz, M.FILTER_FIELD_W)
      if (low_submit or high_submit) and draft_store[preset.id] then
        result = actions.combine(result, commit_preset(value, preset.id, drafts))
      end
    end
    reaper.ImGui_SetCursorPos(ctx, x,
      y + heading + #filter.PRESETS * (frame + M.ITEM_SPACING_Y) - M.ITEM_SPACING_Y)
    return result
  end))
  action = actions.combine(action, settings_group(ctx, "filter", "Settings", function()
    local width = reaper.ImGui_GetContentRegionAvail(ctx)
    local slope_action = option_row(ctx, "slope", "Slope", value.slope, width,
      M.FILTER_FIELD_W * 2 + M.ITEM_SPACING_X)
    return slope_action and { type = "set_monitor_filter_slope", slope = slope_action.value }
  end))
  return action
end

local function draw_panel_shell(ctx, width, height, tab)
  local content_w = reaper.ImGui_GetContentRegionAvail(ctx)
  local tab_w = (content_w - M.SPECTRUM_BAND_GAP) / 2
  local tab_h = reaper.ImGui_GetFrameHeight(ctx) + M.WINDOW_PAD
  local tab_x, tab_y = reaper.ImGui_GetCursorPos(ctx)
  local wx, wy = reaper.ImGui_GetWindowPos(ctx)
  local body_y = tab_y + tab_h
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local rounding = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding())
  -- Match Settings: lighter subject groups sit on the main content surface,
  -- with the darker navigation surface behind the tabs.
  reaper.ImGui_DrawList_PushClipRect(dl, wx + 1, wy + body_y,
    wx + width - 1, wy + height - 1, false)
  reaper.ImGui_DrawList_AddRectFilled(dl, wx + 1, wy + body_y, wx + width - 1,
    wy + height - 1, T.BG_WINDOW, rounding, reaper.ImGui_DrawFlags_RoundCornersBottom())
  local selected_x = wx + tab_x
    + (tab == "filter" and tab_w + M.SPECTRUM_BAND_GAP or 0)
  reaper.ImGui_DrawList_AddLine(dl, wx + 1, wy + body_y, selected_x,
    wy + body_y, T.STROKE_SECONDARY, 1)
  reaper.ImGui_DrawList_AddLine(dl, selected_x + tab_w, wy + body_y,
    wx + width - 1, wy + body_y, T.STROKE_SECONDARY, 1)
  reaper.ImGui_DrawList_PopClipRect(dl)
  local spectrum_clicked = widgets.attached_tab(ctx, "Spectrum", "##spectrum_filter_spectrum",
    tab == "spectrum", tab_w, tab_h)
  reaper.ImGui_SameLine(ctx, 0, M.SPECTRUM_BAND_GAP)
  local filter_clicked = widgets.attached_tab(ctx, "Filter", "##spectrum_filter_filter",
    tab == "filter", tab_w, tab_h)
  return spectrum_clicked, filter_clicked, body_y
end

-- Release demonstrations share the production content in a scaled window inside
-- the canvas. Inputs are disabled while their normal colours are retained.
local function gallery_flags()
  local flags = reaper.ImGui_WindowFlags_NoTitleBar() | reaper.ImGui_WindowFlags_NoResize()
    | reaper.ImGui_WindowFlags_NoCollapse() | reaper.ImGui_WindowFlags_NoSavedSettings()
    | reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse()
  if reaper.ImGui_WindowFlags_NoDocking then flags = flags | reaper.ImGui_WindowFlags_NoDocking() end
  if reaper.ImGui_WindowFlags_NoInputs then flags = flags | reaper.ImGui_WindowFlags_NoInputs() end
  if reaper.ImGui_WindowFlags_NoNav then flags = flags | reaper.ImGui_WindowFlags_NoNav() end
  if reaper.ImGui_WindowFlags_NoFocusOnAppearing then
    flags = flags | reaper.ImGui_WindowFlags_NoFocusOnAppearing()
  end
  return flags
end

-- Scale the shared controls together, without changing the application's UI Size.
local PREVIEW_METRICS = {
  "BASE_FS", "SETTINGS_TAB_FS", "WINDOW_PAD", "FRAME_PAD_X", "FRAME_PAD_Y",
  "ITEM_SPACING_X", "ITEM_SPACING_Y", "SPECTRUM_SETTINGS_W", "SPECTRUM_SETTINGS_H",
  "SPECTRUM_OPTION_W", "SPECTRUM_BAND_GAP", "FILTER_FIELD_W", "FILTER_RESTORE_W",
}

local function begin_gallery_scale(ctx, preview)
  local scale = preview.scale or 1
  preview.saved_metrics = preview.saved_metrics or {}
  for _, key in ipairs(PREVIEW_METRICS) do
    preview.saved_metrics[key] = M[key]
    M[key] = M[key] * scale
  end
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), M.FRAME_PAD_X, M.FRAME_PAD_Y)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), M.ITEM_SPACING_X, M.ITEM_SPACING_Y)
  return theme.push_release_font(ctx, M.BASE_FS)
end

local function end_gallery_scale(ctx, preview, font)
  if font then reaper.ImGui_PopFont(ctx) end
  reaper.ImGui_PopStyleVar(ctx, 2)
  for _, key in ipairs(PREVIEW_METRICS) do M[key] = preview.saved_metrics[key] end
end

function filterwin.gallery_size()
  -- Size from the same rows we draw, never from a previous scaled frame.
  return M.SPECTRUM_SETTINGS_W, release_settings_layout.content_height(SPECTRUM_GROUPS,
    M.BASE_FS + M.FRAME_PAD_Y * 2, M.BASE_FS, M.WINDOW_PAD, M.ITEM_SPACING_Y)
end

local function paint_gallery_pointer(ctx, preview)
  if not (preview.pointer_x and preview.paint_pointer) then return end
  local x, y = reaper.ImGui_GetWindowPos(ctx)
  local width, height = reaper.ImGui_GetWindowSize(ctx)
  local dl = reaper.ImGui_GetForegroundDrawList(ctx)
  reaper.ImGui_DrawList_PushClipRect(dl, x, y, x + width, y + height, true)
  preview.paint_pointer(dl, preview.pointer_x, preview.pointer_y, preview.pointer_pulse)
  reaper.ImGui_DrawList_PopClipRect(dl)
end

local function gallery_combo_popup(ctx, key, id, preview)
  local options = OPTIONS[key]
  local anchor = preview.targets and preview.targets[key]
  if not (options and anchor and preview.open_combo == key) then return end
  local row_height = reaper.ImGui_GetTextLineHeight(ctx)
  local width = math.max(1, anchor.x1 - anchor.x0)
  local height = M.WINDOW_PAD * 2 + #options * row_height
    + math.max(0, #options - 1) * M.ITEM_SPACING_Y
  local x, y = anchor.x0, anchor.y1
  local work = preview.work
  if work then
    x = math.max(work.left, math.min(x, work.right - width))
    if y + height > work.bottom then y = anchor.y0 - height end
    y = math.max(work.top, math.min(y, work.bottom - height))
  end
  reaper.ImGui_SetNextWindowPos(ctx, x, y, reaper.ImGui_Cond_Always())
  reaper.ImGui_SetNextWindowSize(ctx, width, height, reaper.ImGui_Cond_Always())
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), T.BG_POPUP)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(), T.STROKE_SECONDARY)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(),
    M.WINDOW_PAD, M.WINDOW_PAD)
  local opened = reaper.ImGui_Begin(ctx,
    "##filterwin_gallery_combo_" .. tostring(id or "preview") .. "_" .. key,
    nil, gallery_flags())
  reaper.ImGui_PopStyleVar(ctx)
  reaper.ImGui_PopStyleColor(ctx, 2)
  if opened then
    for index, label in ipairs(options) do
      local value = options.values[index]
      local highlighted = value == preview.selected_value
        or value == preview.highlight_value
      reaper.ImGui_Selectable(ctx, label .. "##gallery_" .. key .. "_" .. index,
        highlighted)
      local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
      local x1, y1 = reaper.ImGui_GetItemRectMax(ctx)
      local target_key = key .. "_" .. tostring(value)
      local point = preview.targets[target_key]
      if not point then point = {}; preview.targets[target_key] = point end
      point.x, point.y = (x0 + x1) * .5, (y0 + y1) * .5
    end
    paint_gallery_pointer(ctx, preview)
    reaper.ImGui_End(ctx)
  end
end

function filterwin.gallery_preview(ctx, state, tab, x, y, id, preview)
  preview = preview or {}
  preview.drafts = preview.drafts or {}
  preview.targets = preview.targets or {}
  local font = begin_gallery_scale(ctx, preview)
  local width, height = M.SPECTRUM_SETTINGS_W, preview.height or M.SPECTRUM_SETTINGS_H
  reaper.ImGui_SetNextWindowPos(ctx, x, y, reaper.ImGui_Cond_Always())
  reaper.ImGui_SetNextWindowSize(ctx, width, height, reaper.ImGui_Cond_Always())
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(), T.STROKE_SECONDARY)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), T.BG_CHROME)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(),
    M.WINDOW_PAD, M.WINDOW_PAD)
  local opened = reaper.ImGui_Begin(ctx,
    "##filterwin_gallery_" .. tostring(id or "preview"), nil, gallery_flags())
  reaper.ImGui_PopStyleVar(ctx)
  reaper.ImGui_PopStyleColor(ctx, 2)
  if opened then
    local normal_alpha = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha())
    reaper.ImGui_BeginDisabled(ctx, true)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_Alpha(), normal_alpha)
    local _, _, body_y = draw_panel_shell(ctx, width, height, tab)
    reaper.ImGui_SetCursorPos(ctx, M.WINDOW_PAD, body_y + M.WINDOW_PAD * 2)
    if tab == "filter" then
      filter_tab(ctx, state.monitor_filter, preview.drafts)
    else
      spectrum_tab(ctx, state.spectrum.prefs, true, preview.targets)
    end
    reaper.ImGui_PopStyleVar(ctx)
    reaper.ImGui_EndDisabled(ctx)
    paint_gallery_pointer(ctx, preview)
    reaper.ImGui_End(ctx)
  end
  gallery_combo_popup(ctx, preview.open_combo, id, preview)
  end_gallery_scale(ctx, preview, font)
  return width, height
end

function filterwin.draw(ctx, state, res)
  local action = entry.draw(ctx, state, res)
  if not ui.open then return action end
  local width, height = M.SPECTRUM_SETTINGS_W, M.SPECTRUM_SETTINGS_H
  local frame_height = reaper.ImGui_GetFrameHeight(ctx)
  if ui.measured_frame == frame_height and ui.measured_pad == M.WINDOW_PAD then
    height = ui.spectrum_height or height
  end
  local system = state.monitor_filter.system or {}
  local recovery = helper_status.describe(system)
  local preference_error = ui.error or state.spectrum.preference_error
    or state.monitor_filter.preference_error
  local show_status = preference_error or not system.available or system.range_error
  local show_recovery = recovery and recovery.button
  -- Both tabs fit the Spectrum content; only real errors need a footer.
  if show_status then height = height + M.FILTER_STATUS_H + M.ITEM_SPACING_Y end
  if show_recovery then
    height = height + reaper.ImGui_GetFrameHeight(ctx) + M.ITEM_SPACING_Y
  end
  if ui.opening then
    entry.position(ctx, res, ui.x, ui.y_top, ui.y_bottom, width, height)
    ui.opening = false
  end
  reaper.ImGui_SetNextWindowSize(ctx, width, height, reaper.ImGui_Cond_Always())
  local flags = reaper.ImGui_WindowFlags_NoTitleBar() | reaper.ImGui_WindowFlags_NoResize()
    | reaper.ImGui_WindowFlags_NoCollapse() | reaper.ImGui_WindowFlags_NoSavedSettings()
    | reaper.ImGui_WindowFlags_NoDocking() | reaper.ImGui_WindowFlags_NoScrollbar()
    | reaper.ImGui_WindowFlags_NoScrollWithMouse()
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), T.BG_CHROME)
  local visible = reaper.ImGui_Begin(ctx, "##yb_spectrum_filter_settings", nil, flags)
  reaper.ImGui_PopStyleColor(ctx)
  if visible then
    local dismiss = anchored_panel.dismissed(ctx, ui)
    local spectrum_clicked, filter_clicked, body_y =
      draw_panel_shell(ctx, width, height, ui.tab)
    if spectrum_clicked and ui.tab ~= "spectrum" then
      action = actions.combine(action, finish_preset_focus(state.monitor_filter))
      ui.tab = "spectrum"
    elseif filter_clicked then
      ui.tab = "filter"
    end
    reaper.ImGui_SetCursorPos(ctx, M.WINDOW_PAD, body_y + M.WINDOW_PAD * 2)
    if ui.tab == "spectrum" then
      action = actions.combine(action, spectrum_tab(ctx, state.spectrum.prefs))
      -- Use the last group's actual bottom, including its font and child padding.
      -- Keep this height on Filter so switching tabs never resizes the panel.
      local _, content_bottom = reaper.ImGui_GetItemRectMax(ctx)
      local _, window_y = reaper.ImGui_GetWindowPos(ctx)
      ui.spectrum_height = math.ceil(content_bottom - window_y + M.WINDOW_PAD)
      ui.measured_frame, ui.measured_pad = frame_height, M.WINDOW_PAD
    else
      action = actions.combine(action, filter_tab(ctx, state.monitor_filter))
    end
    local footer_y = height - M.WINDOW_PAD
    if show_recovery then footer_y = footer_y - reaper.ImGui_GetFrameHeight(ctx) end
    if show_status then
      reaper.ImGui_SetCursorPos(ctx, M.WINDOW_PAD,
        footer_y - M.FILTER_STATUS_H - (show_recovery and M.ITEM_SPACING_Y or 0))
      local child = reaper.ImGui_BeginChild(ctx, "##spectrum_filter_status",
        width - M.WINDOW_PAD * 2, M.FILTER_STATUS_H, 0)
      if child then
        reaper.ImGui_PushTextWrapPos(ctx, 0)
        reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY, preference_error
          or (recovery and (recovery.title .. ". " .. recovery.detail)) or system.range_error or "")
        reaper.ImGui_PopTextWrapPos(ctx)
        reaper.ImGui_EndChild(ctx)
      end
    end
    if show_recovery then
      reaper.ImGui_SetCursorPos(ctx, M.WINDOW_PAD, footer_y)
      if reaper.ImGui_Button(ctx, recovery.button .. "##spectrum_helper") then
        action = actions.combine(action, { type = recovery.action })
      end
    end
    if ui.closing or dismiss then
      action = actions.combine(action, finish_preset_focus(state.monitor_filter))
      ui.open, ui.closing = false, nil
    end
    if reaper.ImGui_IsWindowFocused(ctx) and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
      filterwin.close(); focus.request()
    end
    reaper.ImGui_End(ctx)
  end
  return action
end

return filterwin
