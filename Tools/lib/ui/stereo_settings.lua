local theme = require('ui.theme')
local widgets = require('ui.widgets')
local icons = require('ui.icons')
local tips = require('ui.tips')
local anchored_panel = require('ui.anchored_panel')
local focus = require('ui.focus')
local preferences = require('core.stereo_preferences')
local T, M = theme.tokens, theme.metrics
local settings = {}
local defaults = preferences.defaults()
local ui = {open=false}
local groups = {display={rows=2}, appearance={rows=4}, meters={rows=3}}
local preview_targets

local function record_target(ctx, key)
  if not preview_targets then return end
  local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
  local x1, y1 = reaper.ImGui_GetItemRectMax(ctx)
  local centre_y = (y0+y1)*.5
  if key == 'brightness' then
    local half_knob = M.FADER_KNOB_W*.5
    preview_targets.brightness_100 = {x=(x0+x1)*.5, y=centre_y}
    preview_targets.brightness_150 = {x=x1-half_knob, y=centre_y}
  else
    preview_targets[key] = {x=(x0+x1)*.5, y=centre_y}
  end
end

local function update_anchor(x, y, width, height)
  local anchor = ui.anchor
  if not anchor or anchor.left ~= x or anchor.top ~= y
      or anchor.right ~= x + width or anchor.bottom ~= y + height then
    ui.anchor = {left=x, top=y, right=x + width, bottom=y + height}
    ui.reposition = true
  end
end

local VIEWS = {
  {value='polar_sample', draw=icons.draw_stereo_polar, tip='Polar Sample'},
  {value='lissajous', draw=icons.draw_stereo_lissajous, tip='Lissajous'},
}

local OPTIONS = {
  trail = {labels={'Short', 'Medium', 'Long'}, values={'short', 'medium', 'long'}},
  trace = {labels={'Dots', 'Connected Dots'}, values={'dots', 'lines'}},
  clip_hold = {labels={'0.5 s', '1 s', '2 s', 'Until Cleared'}, values={0.5, 1, 2, 0}},
}
for _, option in pairs(OPTIONS) do option.items = table.concat(option.labels, '\0') .. '\0' end

local HINTS = {
  brightness = 'Adjusts the brightness of all dots without changing their positions.',
  history = 'Lower values make older dots fainter so the newest paths stand out.',
  trail = 'Sets how long older dots remain visible.',
  trace = 'Shows separate dots or joins nearby dots with lines. Available in Lissajous; Polar Sample always uses dots.',
  clip_hold = 'Keeps red marks after clipping stops. Click the scope to clear them.',
}

local function row_label(ctx, label, key, control_width)
  local x = reaper.ImGui_GetCursorPosX(ctx)
  local width = reaper.ImGui_GetContentRegionAvail(ctx)
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY, label)
  tips.show(ctx, reaper.ImGui_IsItemHovered(ctx), HINTS[key], 'stereo_hint_' .. key)
  reaper.ImGui_SameLine(ctx, x + width - control_width)
end

local function option_row(ctx, key, label, value, view, disabled)
  row_label(ctx, label, key, M.SPECTRUM_OPTION_W)
  if disabled then reaper.ImGui_BeginDisabled(ctx) end
  reaper.ImGui_SetNextItemWidth(ctx, M.SPECTRUM_OPTION_W)
  local option, selected = OPTIONS[key], 0
  for i, candidate in ipairs(option.values) do
    if candidate == value then selected = i - 1 end
  end
  local changed, index = reaper.ImGui_Combo(ctx, '##stereo_setting_' .. key, selected, option.items)
  record_target(ctx, key)
  if disabled then reaper.ImGui_EndDisabled(ctx) end
  if changed then
    return {type='stereo_setting', view=view, key=key, value=option.values[index + 1]}
  end
end

local function brightness_row(ctx, key, label, value, view)
  row_label(ctx, label, key, M.SPECTRUM_OPTION_W)
  local number_w = reaper.ImGui_CalcTextSize(ctx, '150%')
  local next_value, commit = widgets.step_slider(ctx, 'stereo_' .. view .. '_' .. key,
    value * 100, {min=50, max=150, step=5, tick_step=25,
      width=M.SPECTRUM_OPTION_W - number_w - M.ITEM_SPACING_X})
  record_target(ctx, key)
  local reset = widgets.wants_reset(ctx)
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_TextColored(ctx, T.TEXT_PRIMARY, string.format('%d%%', math.floor((next_value or value * 100) + 0.5)))
  if reset then next_value, commit = 100, true end
  if next_value then
    return {type='stereo_setting', view=view, key=key, value=next_value / 100, commit=commit}
  end
end

local function switch_row(ctx, key, label, on, hint)
  row_label(ctx, label, key, M.SET_SWITCH_W)
  local clicked = widgets.switch(ctx, 'stereo_' .. key, on, hint)
  record_target(ctx, key)
  if clicked then
    return {type='stereo_setting', key=key, value=not on}
  end
end

local function draw_content(ctx, state)
  local prefs = state.stereo_preferences or defaults
  local view = state.stereo_view == 'polar_sample' and 'polar_sample' or 'lissajous'
  local appearance = prefs.views[view]
  local action
  local failed = state.stereo_preferences_error ~= nil
  local function accept(result) action = result or action end
  local opened, child = widgets.begin_settings_group(ctx, 'stereo_display', 'Display', true, nil, groups.display)
  if opened then
    row_label(ctx, 'View', 'view', M.SPECTRUM_OPTION_W)
    local selected = widgets.two_way_switch(ctx, 'stereo_view_switch', view, VIEWS,
      M.SPECTRUM_OPTION_W, nil, true)
    if selected and selected ~= view then action = {type='stereo_view', value=selected} end
    if failed then reaper.ImGui_BeginDisabled(ctx) end
    accept(option_row(ctx, 'trace', 'Drawing Style', appearance.trace, view, view ~= 'lissajous'))
    if failed then reaper.ImGui_EndDisabled(ctx) end
  end
  widgets.end_settings_group(ctx, child)
  if failed then reaper.ImGui_BeginDisabled(ctx) end
  opened, child = widgets.begin_settings_group(ctx, 'stereo_appearance', 'Appearance', false, nil, groups.appearance)
  if opened then
    accept(brightness_row(ctx, 'brightness', 'Current Brightness', appearance.brightness, view))
    accept(brightness_row(ctx, 'history', 'History Brightness', appearance.history, view))
    accept(option_row(ctx, 'trail', 'Trail Length', appearance.trail, view))
    if reaper.ImGui_Button(ctx, 'Reset Appearance', (reaper.ImGui_GetContentRegionAvail(ctx))) then
      action = {type='stereo_reset_settings', view=view}
    end
    tips.show(ctx, reaper.ImGui_IsItemHovered(ctx), 'Restores the appearance of this view only.')
  end
  widgets.end_settings_group(ctx, child)
  opened, child = widgets.begin_settings_group(ctx, 'stereo_meters', 'Meters', false, nil, groups.meters)
  if opened then
    accept(switch_row(ctx, 'show_clipping', 'Show Clipping', prefs.show_clipping,
      'Marks samples that reach full scale in red.'))
    accept(option_row(ctx, 'clip_hold', 'Clipping Hold', prefs.clip_hold, nil, not prefs.show_clipping))
    accept(switch_row(ctx, 'show_correlation', 'Show Correlation', prefs.show_correlation,
      'Shows how closely the left and right channels agree. Negative values can cancel when summed to mono.'))
  end
  widgets.end_settings_group(ctx, child)
  if failed then reaper.ImGui_EndDisabled(ctx) end
  reaper.ImGui_SetCursorPosY(ctx, reaper.ImGui_GetCursorPosY(ctx) + M.ITEM_SPACING_Y)
  local frozen = state.stereo.frozen == true
  local width = (reaper.ImGui_GetContentRegionAvail(ctx) - M.ITEM_SPACING_X) / 2
  if widgets.panel_button_frame(ctx, 'Freeze', width, 0, frozen) then
    action = {type='stereo_freeze', value=not frozen}
  end
  tips.show(ctx, reaper.ImGui_IsItemHovered(ctx), 'Holds the picture while audio continues. Click again to resume.')
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, 'Clear', width) then action = {type='stereo_clear_display'} end
  if failed then
    reaper.ImGui_PushTextWrapPos(ctx, 0)
    reaper.ImGui_TextColored(ctx, T.DANGER_RED, state.stereo_preferences_error .. '\nReset Stereo Settings to enable changes.')
    reaper.ImGui_PopTextWrapPos(ctx)
    if reaper.ImGui_Button(ctx, 'Reset Stereo Settings', (reaper.ImGui_GetContentRegionAvail(ctx))) then
      action = {type='stereo_reset_all_settings'}
    end
  end
  return action
end

local function panel_height(ctx, state)
  local width = M.SPECTRUM_SETTINGS_W
  local frame = reaper.ImGui_GetFrameHeight(ctx)
  local bold = theme.push_bold_font(ctx)
  local heading = reaper.ImGui_GetTextLineHeight(ctx)
  if bold then reaper.ImGui_PopFont(ctx) end
  -- These groups contain fixed-height rows. Give them their final height on
  -- the opening frame so child auto-sizing cannot shrink and regrow the panel.
  local height = 2 * M.WINDOW_PAD + frame + 6 * M.ITEM_SPACING_Y
  for _, group in pairs(groups) do
    group.height = group.rows * frame + (group.rows - 1) * M.ITEM_SPACING_Y + 2 * M.WINDOW_PAD
    height = height + heading + M.ITEM_SPACING_Y + group.height
  end
  if state.stereo_preferences_error then
    local message = state.stereo_preferences_error .. '\nReset Stereo Settings to enable changes.'
    local _, text_height = reaper.ImGui_CalcTextSize(ctx, message, nil, nil, false, width - 2 * M.WINDOW_PAD)
    height = height + text_height + frame + 2 * M.ITEM_SPACING_Y
  end
  return width, height
end

function settings.gallery_measure(ctx, state)
  return panel_height(ctx, state)
end

function settings.draw_panel(ctx, state, res)
  if not ui.open then return end
  local width, height = panel_height(ctx, state)
  if ui.opening or ui.reposition or ui.scale ~= theme.scale or ui.placed_height ~= height then
    ui.geometry = anchored_panel.place(ctx, res, ui.anchor, {
      width=width, height=height, min_height=height,
      gap=M.PANEL_ANCHOR_GAP, margin=M.PICK_SCREEN_MARGIN,
      prefer_beside=true,
    })
    reaper.ImGui_SetNextWindowPos(ctx, ui.geometry.x, ui.geometry.y, reaper.ImGui_Cond_Always())
    ui.opening, ui.scale, ui.placed_height = false, theme.scale, height
    ui.reposition = false
  end
  reaper.ImGui_SetNextWindowSize(ctx, ui.geometry.w, ui.geometry.h, reaper.ImGui_Cond_Always())
  local flags = reaper.ImGui_WindowFlags_NoTitleBar() | reaper.ImGui_WindowFlags_NoResize()
    | reaper.ImGui_WindowFlags_NoCollapse() | reaper.ImGui_WindowFlags_NoSavedSettings()
    | reaper.ImGui_WindowFlags_NoDocking()
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), T.BG_WINDOW)
  local visible = reaper.ImGui_Begin(ctx, '##yb_stereo_settings', nil, flags)
  reaper.ImGui_PopStyleColor(ctx)
  if not visible then return end
  local dismiss = anchored_panel.dismissed(ctx, ui)
  local action = draw_content(ctx, state)
  if ui.closing or dismiss then ui.open, ui.closing = false, nil end
  if reaper.ImGui_IsWindowFocused(ctx, reaper.ImGui_FocusedFlags_RootAndChildWindows())
      and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
    ui.open = false
    focus.request()
  end
  reaper.ImGui_End(ctx)
  return action
end

-- Gallery controls are the real settings rows in a separate, input-free window.
-- Their scripted values and target rectangles never touch the live panel state.
function settings.gallery_preview(ctx, state, x, y, id, preview)
  preview = preview or {}
  preview.targets = preview.targets or {}
  local width, height = panel_height(ctx, state)
  reaper.ImGui_SetNextWindowPos(ctx, x, y, reaper.ImGui_Cond_Always())
  reaper.ImGui_SetNextWindowSize(ctx, width, height, reaper.ImGui_Cond_Always())
  local flags = reaper.ImGui_WindowFlags_NoTitleBar() | reaper.ImGui_WindowFlags_NoResize()
    | reaper.ImGui_WindowFlags_NoCollapse() | reaper.ImGui_WindowFlags_NoSavedSettings()
    | reaper.ImGui_WindowFlags_NoDocking()
  if reaper.ImGui_WindowFlags_NoInputs then flags = flags | reaper.ImGui_WindowFlags_NoInputs() end
  if reaper.ImGui_WindowFlags_NoNav then flags = flags | reaper.ImGui_WindowFlags_NoNav() end
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), T.BG_WINDOW)
  local opened = reaper.ImGui_Begin(ctx, '##stereo_settings_gallery_' .. tostring(id or 'preview'), nil, flags)
  reaper.ImGui_PopStyleColor(ctx)
  if opened then
    local alpha = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha())
    reaper.ImGui_BeginDisabled(ctx)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_Alpha(), alpha)
    preview_targets = preview.targets
    local result = table.pack(xpcall(function() draw_content(ctx, state) end, debug.traceback))
    preview_targets = nil
    reaper.ImGui_PopStyleVar(ctx)
    reaper.ImGui_EndDisabled(ctx)
    if result[1] and preview.paint_pointer then
      preview.paint_pointer(ctx, preview, x, y, width, height)
    end
    reaper.ImGui_End(ctx)
    if not result[1] then error(result[2], 0) end
  end
  return width, height
end

function settings.draw(ctx, state, res, x, y, width, height, exclusion, presentation)
  -- The scope can change shape while these settings stay open. Record its
  -- current bounds before the separate settings window is positioned this frame.
  if not presentation and ui.open then update_anchor(x, y, width, height) end
  local size = reaper.ImGui_GetFrameHeight(ctx)
  if width < size + 2 * M.WINDOW_PAD or height < size + 2 * M.WINDOW_PAD then return end
  local bx, by = x + M.WINDOW_PAD, y + M.WINDOW_PAD
  if exclusion and bx < exclusion.x1 and bx + size > exclusion.x0
      and by < exclusion.y1 and by + size > exclusion.y0 then
    -- Compact layouts reserve this corner for the panel picker. Keep settings
    -- and Resume reachable beside it, or below it when the row is too narrow.
    local right = exclusion.x1 + M.ITEM_SPACING_X
    local controls_width = 2 * size + M.ITEM_SPACING_X
    if right + controls_width <= x + width - M.WINDOW_PAD then
      bx = right
    else
      by = exclusion.y1 + M.ITEM_SPACING_Y
      if by + size > y + height - M.WINDOW_PAD then return end
    end
  end
  local open = not presentation and ui.open
  local hovered
  if presentation then
    hovered = presentation.hovered == true
  else
    hovered = reaper.ImGui_IsWindowHovered(ctx,
        reaper.ImGui_HoveredFlags_AllowWhenBlockedByActiveItem())
      and reaper.ImGui_IsMouseHoveringRect(ctx, x, y, x + width, y + height)
  end
  local frozen = state.stereo.frozen == true
  if not (hovered or open or frozen) then return end
  reaper.ImGui_SetCursorScreenPos(ctx, bx, by)
  local clicked, button_hovered = widgets.plot_settings_button(ctx, res and res.icon_font,
    'stereo_view_button', open)
  if clicked and not presentation then
    if open then
      ui.closing = true
    else
      ui.open, ui.opening, ui.closing = true, true, nil
      update_anchor(x, y, width, height)
    end
  end
  if not presentation then
    tips.show(ctx, button_hovered and not open, 'Stereo Settings', 'stereo_view')
  end
  local action
  local fx = bx + size + M.ITEM_SPACING_X
  local freeze_blocked = exclusion and fx < exclusion.x1 and fx + size > exclusion.x0
    and by < exclusion.y1 and by + size > exclusion.y0
  if frozen and fx + size <= x + width - M.WINDOW_PAD and not freeze_blocked then
    reaper.ImGui_SetCursorScreenPos(ctx, fx, by)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), T.FILL_PRIMARY)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(), 0)
    local resume, resume_hovered = widgets.panel_button(ctx, res and res.icon_font,
      'stereo_resume', 'pause', true, '||')
    if resume and not presentation then action = {type='stereo_freeze', value=false} end
    if not presentation then
      tips.show(ctx, resume_hovered, 'Resume Stereo Display', 'stereo_resume')
    end
    reaper.ImGui_PopStyleColor(ctx, 4)
  end
  reaper.ImGui_SetCursorScreenPos(ctx, x, y + height)
  return action
end

return settings
