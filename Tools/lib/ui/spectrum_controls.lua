-- Compact listening controls live over the spectrum picture. Waveform-only
-- mode deliberately has no spectrum or listening-filter controls.
local theme = require('ui.theme')
local icons = require('ui.icons')
local icon_motion = require('ui.icon_motion')
local widgets = require('ui.widgets')
local tips = require('ui.tips')
local filter = require('core.monitor_filter')
local settings = require('ui.filterwin')
local entry = require('ui.filter_entry')
local helper_status = require('core.monitor_helper_status')
local T, M = theme.tokens, theme.metrics
local controls = {}
local overlay_alpha, overlay_time, overlay_frame = 0, nil, nil
local overlay_start, overlay_target = 0, 0
local overlay_generation = theme.motion.generation
local OVERLAY_ENTER_SECONDS, OVERLAY_EXIT_SECONDS = 0.24, 0.12

-- Enter with the preview's easing; leave at a steady speed for an immediate response.
local function overlay_ease(progress, entering)
  if not entering or progress <= 0 or progress >= 1 then return progress end
  local x1, x2 = 0.16, 0.3
  local low, high, t = 0, 1, progress
  for _ = 1, 16 do
    local inverse = 1 - t
    local x = 3 * inverse * inverse * t * x1 + 3 * inverse * t * t * x2 + t * t * t
    if x < progress then low = t else high = t end
    t = (low + high) * 0.5
  end
  local inverse = 1 - t
  return 3 * inverse * inverse * t + 3 * inverse * t * t + t * t * t
end

function controls.update_overlay(ctx, wanted)
  local target = wanted and 1 or 0
  if not theme.motion.enabled then
    overlay_alpha, overlay_start, overlay_target = target, target, target
    overlay_time, overlay_frame = nil, nil
    return overlay_alpha
  end
  local now, frame = reaper.ImGui_GetTime(ctx), reaper.ImGui_GetFrameCount(ctx)
  if overlay_generation ~= theme.motion.generation then
    overlay_alpha, overlay_start, overlay_target = target, target, target
    overlay_time, overlay_frame, overlay_generation = now, frame, theme.motion.generation
    return overlay_alpha
  end
  -- Returning from waveform-only mode starts a fresh fade.
  if not overlay_frame or frame > overlay_frame + 1 or now < overlay_time then
    overlay_alpha, overlay_start, overlay_target, overlay_time = 0, 0, target, now
  end
  local duration = overlay_target == 1 and OVERLAY_ENTER_SECONDS or OVERLAY_EXIT_SECONDS
  -- A reversal only covers the remaining distance, so it needs less time.
  duration = duration * math.abs(overlay_target - overlay_start)
  local progress = duration > 0 and math.min(1, math.max(0, now - overlay_time) / duration) or 1
  overlay_alpha = overlay_start + (overlay_target - overlay_start)
    * overlay_ease(progress, overlay_target == 1)
  if target ~= overlay_target then
    -- Reverse from the current position and opacity when hover changes mid-flight.
    overlay_start, overlay_target, overlay_time = overlay_alpha, target, now
  end
  overlay_frame = frame
  return overlay_alpha
end


local function push_overlay_button_state(ctx, visible, selected)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),
    selected and T.ACTIVE_CONTROL_FILL or 0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(),
    selected and T.ACTIVE_CONTROL_HOVER or 0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),
    visible and (selected and T.ACTIVE_CONTROL_HELD or T.FILL_PRIMARY) or 0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),
    0)
end

local function draw_segment_outline(ctx, selected, hovered, visible)
  if not (visible and (selected or hovered)) then return end
  widgets.button_outline(ctx, selected and T.ACTIVE_CONTROL_BORDER or T.STROKE_PRIMARY)
end

local function draw_divider_after(ctx, selected, visible, segment, hovered_segment)
  if not (visible and not selected)
      or hovered_segment == segment or hovered_segment == segment + 1 then return end
  local _, y0 = reaper.ImGui_GetItemRectMin(ctx)
  local x1, y1 = reaper.ImGui_GetItemRectMax(ctx)
  local inset = 4 * theme.scale
  local alpha = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha())
  reaper.ImGui_DrawList_AddLine(reaper.ImGui_GetWindowDrawList(ctx),
    x1, y0 + inset, x1, y1 - inset,
    theme.fade(T.STROKE_PRIMARY, alpha))
end

local function icon_segment(ctx, font, id, name, colour, hover_colour, fallback, open)
  local size = reaper.ImGui_GetFrameHeight(ctx)
  local clicked = reaper.ImGui_Button(ctx, '##' .. id, size, size)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  colour = hovered and hover_colour or colour
  local animated = icon_motion.paint_item(ctx, id, name, colour, open == true, clicked)
  if not animated and not icons.paint_over_item(ctx, font, name, {color = colour}) and fallback then
    local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
    local x1, y1 = reaper.ImGui_GetItemRectMax(ctx)
    local alpha = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha())
    fallback(reaper.ImGui_GetWindowDrawList(ctx),
      (x0 + x1) * 0.5, (y0 + y1) * 0.5, theme.fade(colour, alpha))
  end
  return clicked, hovered
end

local region_icon = require("ui.filter_band_icon").paint


function controls.overlay_bounds(ctx, x, y, width, height, axis_height)
  local frame = reaper.ImGui_GetFrameHeight(ctx)
  local content_w = (#filter.PRESETS + 2) * frame
  local plot_w = math.max(1, width - M.SPECTRUM_LEVEL_W)
  local left = x + math.max(M.SPECTRUM_PLOT_PAD, (plot_w - content_w) * 0.5)
  local top = math.max(y + M.SPECTRUM_PLOT_PAD,
    y + height - axis_height - frame - M.SPECTRUM_PLOT_PAD)
  top = top + (1 - overlay_alpha) * M.SPECTRUM_OVERLAY_TRAVEL
  local pad = 2 * theme.scale
  return {
    x0 = left - pad, y0 = top - pad,
    x1 = left + content_w + pad, y1 = top + frame + pad,
    content_x = left, content_y = top, content_w = content_w, frame = frame,
    pad = pad,
  }
end

function controls.contains(bounds, x, y)
  return x >= bounds.x0 and x <= bounds.x1
    and y >= bounds.y0 and y <= bounds.y1
end

function controls.overlay(ctx, state, res, x, y, width, height, axis_height)
  local opacity = overlay_alpha
  if opacity == 0 then return end
  local visible = true
  local alpha = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha()) * opacity
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_Alpha(), alpha)
  local value = state.monitor_filter
  local system = value.system or {}
  local available = system.available == true
  local font, action = res and res.icon_font, nil
  local bounds = controls.overlay_bounds(ctx, x, y, width, height, axis_height)
  local frame, content_w = bounds.frame, bounds.content_w
  local left, top, bar_pad = bounds.content_x, bounds.content_y, bounds.pad
  local mx, my = reaper.ImGui_GetMousePos(ctx)
  local hovered_segment
  if visible and reaper.ImGui_IsWindowHovered(ctx,
      reaper.ImGui_HoveredFlags_AllowWhenBlockedByActiveItem())
      and mx >= left and mx < left + content_w
      and my >= top and my <= top + frame then
    hovered_segment = math.floor((mx - left) / frame) + 1
  end
  if visible then
    local rounding = select(1,
      reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding()))
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    reaper.ImGui_DrawList_AddRectFilled(dl,
      left - bar_pad, top - bar_pad,
      left + content_w + bar_pad, top + frame + bar_pad,
      theme.fade(T.BG_POPUP, alpha), rounding + bar_pad)
    reaper.ImGui_DrawList_AddRect(dl,
      left - bar_pad + 0.5, top - bar_pad + 0.5,
      left + content_w + bar_pad - 0.5, top + frame + bar_pad - 0.5,
      theme.fade(T.STROKE_SECONDARY, alpha), rounding + bar_pad, 0, 1)
  end
  reaper.ImGui_SetCursorScreenPos(ctx, left, top)

  reaper.ImGui_BeginDisabled(ctx, not available)
  local idle_icon = visible and T.TEXT_SECONDARY or 0
  local entry_open = entry.is_open()
  local custom_selected = available and value.on and not value.selected_id
  local custom_highlighted = custom_selected or entry_open
  push_overlay_button_state(ctx, visible, custom_highlighted)
  local custom_clicked, custom_hovered = icon_segment(ctx, font,
    'filter_entry', 'pencil',
      custom_highlighted and visible and T.ACCENT_HOVER or idle_icon,
      custom_highlighted and T.ACCENT_HOVER or T.TEXT_PRIMARY,
      icons.draw_pencil)
  if custom_hovered and available and reaper.ImGui_IsMouseClicked(ctx, 1) then
    action = {type = 'monitor_filter_full_range'}
  elseif custom_clicked then
    local x, y = reaper.ImGui_GetItemRectMin(ctx)
    local _, bottom = reaper.ImGui_GetItemRectMax(ctx)
    settings.close()
    entry.open_at(x, y, bottom, 'low')
  end
  reaper.ImGui_PopStyleColor(ctx, 4)
  draw_segment_outline(ctx, custom_highlighted, custom_hovered, visible)
  draw_divider_after(ctx, custom_highlighted, visible, 1, hovered_segment)
  tips.show(ctx, custom_hovered, 'Edit Filter Range. Right-click to return to Full.', 'filter_entry')
  for i, preset in ipairs(filter.PRESETS) do
    reaper.ImGui_SameLine(ctx, 0, 0)
    local band = value.presets[preset.id]
    local supported = not system.max_filter_hz or band.high_hz <= system.max_filter_hz
    reaper.ImGui_BeginDisabled(ctx, not supported)
    local selected = available and value.on and value.selected_id == preset.id
    push_overlay_button_state(ctx, visible, selected)
    if reaper.ImGui_Button(ctx, '##filter_' .. preset.id, frame, frame) then
      action = selected
        and {type = 'monitor_filter_full_range'}
        or {type = 'apply_monitor_filter_preset', id = preset.id}
    end
    reaper.ImGui_PopStyleColor(ctx, 4)
    local hovered = reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_AllowWhenDisabled())
    region_icon(ctx, band.low_hz, band.high_hz,
      selected and visible and T.ACCENT_HOVER
        or (hovered and T.TEXT_PRIMARY or idle_icon))
    draw_segment_outline(ctx, selected, hovered, visible)
    draw_divider_after(ctx, selected, visible, i + 1, hovered_segment)
    reaper.ImGui_EndDisabled(ctx)
    tips.show(ctx, hovered, tips.with_shortcut(state, 'filter_' .. preset.id, preset.label .. ' · ' .. band.low_hz .. '–' .. band.high_hz .. ' Hz'
      .. (selected and '\nClick again to turn filtering off.' or '')
      .. (supported and '' or '\nThis range exceeds the current sample rate.')), 'filter_' .. preset.id)
  end
  reaper.ImGui_EndDisabled(ctx)
  reaper.ImGui_SameLine(ctx, 0, 0)
  local settings_tip = 'Spectrum and Filter Settings'
  if not available then
    local recovery = helper_status.describe(system)
    settings_tip = recovery.title .. '.\n' .. recovery.detail
  elseif system.range_error then
    settings_tip = 'Full monitoring: the filter range was not applied.\n' .. system.range_error
      .. '\nChoose a supported range to dismiss this notice.'
  end
  local settings_open = settings.panel_is_open()
  local settings_clicked, settings_hovered = widgets.plot_settings_button(ctx, font,
    'spectrum_settings', settings_open, false)
  if settings_clicked then
    local x, y = reaper.ImGui_GetItemRectMin(ctx)
    local _, bottom = reaper.ImGui_GetItemRectMax(ctx)
    settings.toggle_at(x, y, bottom)
  end
  if system.range_error then
    local right = reaper.ImGui_GetItemRectMax(ctx)
    local _, top = reaper.ImGui_GetItemRectMin(ctx)
    reaper.ImGui_DrawList_AddCircleFilled(reaper.ImGui_GetWindowDrawList(ctx),
      right - M.UPDATE_DOT_R, top + M.UPDATE_DOT_R, M.UPDATE_DOT_R,
      theme.fade(T.TEXT_PRIMARY, alpha))
  end
  tips.show(ctx, settings_hovered, settings_tip, 'spectrum_settings')
  reaper.ImGui_PopStyleVar(ctx)
  return action
end

return controls
