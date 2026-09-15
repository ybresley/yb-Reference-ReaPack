-- Release demonstrations for waveform navigation, interface motion, and the
-- responsive waveform/spectrum layout. All data and mutable state stay local.

local theme = require("ui.theme")
local widgets = require("ui.widgets")
local icons = require("ui.icons")
local icon_motion = require("ui.icon_motion")
local release_pointer = require("ui.release_pointer")
local tips = require("ui.tips")
local spectrum_layout = require("core.spectrum_layout")
local viewport = require("core.wave_view")
local waveform = require("ui.waveform")
local wave_navigation = require("ui.wave_navigation")
local release_spectrum = require("ui.release_spectrum")
local release_signal = require("ui.release_signal")

local T, M = theme.tokens, theme.metrics
local examples = {}

local function clamp(value, low, high)
  return math.max(low, math.min(high, value))
end

local function ease(value)
  value = clamp(value, 0, 1)
  return value * value * (3 - 2 * value)
end

local function mix(a, b, amount)
  return a + (b - a) * amount
end

local function scaled(value)
  return value * theme.scale
end

function examples.new()
  local demo = {
    signal = release_signal,
    spectrum = release_spectrum.new(),
    motion = { animations = true, pitch_unit = "st", buttons = {} },
    horizontal_first = "waveform",
    vertical_first = "waveform",
    last_modes = {},
    swap_cycle = -1,
  }
  demo.id = "release_examples"
  return demo
end

local function frame_rounding(ctx)
  return reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding())
end

local function text(dl, x, y, colour, value)
  reaper.ImGui_DrawList_AddText(dl,
    math.floor(x + 0.5), math.floor(y + 0.5), colour, value)
end

local function begin_canvas(ctx, width, height)
  width, height = math.max(0, width or 0), math.max(0, height or 0)
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  reaper.ImGui_DrawList_PushClipRect(dl, x, y, x + width, y + height, true)
  reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x + width, y + height,
    T.BG_WINDOW, frame_rounding(ctx))
  return dl, x, y, width, height
end

local function finish_canvas(ctx, dl, x, y, width, height)
  reaper.ImGui_DrawList_PopClipRect(dl)
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  reaper.ImGui_Dummy(ctx, width, height)
end

local function draw_resize_pointer(dl, x, y, axis, down)
  local size = scaled(8)
  local colour = T.TEXT_PRIMARY
  local thickness = math.max(1, theme.scale)
  release_pointer.paint_click(dl, x, y, down)
  if axis == "horizontal" then
    reaper.ImGui_DrawList_AddLine(dl, x - size, y, x + size, y, colour, thickness)
    reaper.ImGui_DrawList_AddTriangleFilled(dl,
      x - size, y, x - size * 0.45, y - size * 0.45,
      x - size * 0.45, y + size * 0.45, colour)
    reaper.ImGui_DrawList_AddTriangleFilled(dl,
      x + size, y, x + size * 0.45, y - size * 0.45,
      x + size * 0.45, y + size * 0.45, colour)
  else
    reaper.ImGui_DrawList_AddLine(dl, x, y - size, x, y + size, colour, thickness)
    reaper.ImGui_DrawList_AddTriangleFilled(dl,
      x, y - size, x - size * 0.45, y - size * 0.45,
      x + size * 0.45, y - size * 0.45, colour)
    reaper.ImGui_DrawList_AddTriangleFilled(dl,
      x, y + size, x - size * 0.45, y + size * 0.45,
      x + size * 0.45, y + size * 0.45, colour)
  end
end

local function draw_wave_panel(ctx, dl, signal, x, y, width, total_height, view, opts)
  if width <= 1 or total_height <= 1 then return end
  opts = opts or {}
  local ruler_h = opts.ruler and M.RULER_H or 0
  local height = math.max(1, total_height - ruler_h)
  reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x + width, y + height,
    T.WAVE_BG, frame_rounding(ctx))
  local channels = signal.waveform.channels
  local lane_h = height / #channels
  local cols = math.max(1, math.floor(width))
  local detail = type(opts.detail) == "table" and opts.detail
    or opts.detail and signal.detail or nil
  for index, overview in ipairs(channels) do
    local lane_y = y + (index - 1) * lane_h
    waveform.paint_lane(dl, x, lane_y, lane_h, cols, overview,
      detail and detail.channels[index] or nil,
      detail and detail.count or nil,
      detail and detail.timing or nil,
      view, false, -1, opts.gain or 1)
    waveform.paint_baseline(dl, x, lane_y, lane_h, width, view, -1, opts.gain or 1)
  end
  if ruler_h > 0 then
    waveform.paint_ruler(ctx, dl, "release_" .. (opts.key or "wave"),
      x, y + height, width, signal.duration, view, opts.pointer_x)
  end
  if opts.navigation then
    wave_navigation.draw_rails(dl, view, x, y, width, height, ruler_h,
      opts.hot, opts.ruler_hovered)
  end
end

local function navigation_view(signal, phase, panel_height)
  local wide = viewport.configure(viewport.new(), signal.duration, signal.sample_rate)
  local ruler_start_x, ruler_end_x = 0.43, 0.68
  local ruler_dy = -scaled(72)
  local ruler_y = 1 - M.RULER_H * 0.58 / panel_height
  local ruler_up_y = ruler_y + ruler_dy / panel_height
  local centre_y = 0.45
  local rail_start_y = 0.58
  local amp_wheel_gain, amp_max_gain = 2, 10 ^ (12 / 20)
  local rail_dy = -math.log(amp_max_gain / amp_wheel_gain) / 0.012
  local rail_end_y = rail_start_y + rail_dy / panel_height
  local close_time = viewport.copy(wide)
  local anchor = viewport.time_at(wide, ruler_start_x)
  viewport.drag_ruler(close_time, math.exp(-ruler_dy * 0.012), anchor,
    ruler_start_x - (ruler_end_x - ruler_start_x))

  local amp_wheel = viewport.copy(close_time)
  viewport.zoom_amp(amp_wheel, amp_wheel_gain, 0)
  local amp_close = viewport.copy(amp_wheel)
  viewport.set_amp_span(amp_close,
    (amp_wheel.a1 - amp_wheel.a0) * math.exp(rail_dy * 0.012))

  local view, pointer_x, pointer_y, down, hot, ruler_hovered, status
  if phase < 4 then
    local a = ease(phase / 4)
    local dx = (ruler_end_x - ruler_start_x) * a
    local dy = ruler_dy * a
    view = viewport.copy(wide)
    viewport.drag_ruler(view, math.exp(-dy * 0.012), anchor, ruler_start_x - dx)
    pointer_x, pointer_y, down, hot, ruler_hovered =
      ruler_start_x + dx, mix(ruler_y, ruler_up_y, a), true, "ruler", true
    status = "Drag right and up · later time, closer view"
  elseif phase < 4.2 then
    view, pointer_x, pointer_y, hot, ruler_hovered =
      close_time, ruler_end_x, ruler_up_y, "ruler", true
    status = "Later section in view"
  elseif phase < 6.2 then
    local a = ease((phase - 4.2) / 2)
    view = viewport.copy(close_time)
    viewport.zoom_amp(view, mix(1, amp_wheel_gain, a), 0)
    pointer_x, pointer_y = mix(ruler_end_x, 0.57, a), mix(ruler_up_y, centre_y, a)
    status = "Alt + mouse wheel · engage amplitude zoom"
  elseif phase < 7.2 then
    local a = ease(phase - 6.2)
    view = amp_wheel
    pointer_x, pointer_y = mix(0.57, 0.985, a), mix(centre_y, rail_start_y, a)
    status = "Move to the amplitude rail"
  elseif phase < 10.2 then
    local a = ease((phase - 7.2) / 3)
    view = viewport.copy(amp_wheel)
    viewport.set_amp_span(view, (amp_wheel.a1 - amp_wheel.a0)
      * math.exp((rail_dy * a) * 0.012))
    pointer_x, pointer_y, down, hot =
      0.985, mix(rail_start_y, rail_end_y, a), true, "amp_body"
    status = "Drag the rail up · quieter detail becomes visible"
  elseif phase < 10.4 then
    view, pointer_x, pointer_y, hot = amp_close, 0.985, rail_end_y, "amp_body"
    status = "Amplitude zoom changes the picture only"
  elseif phase < 12.4 then
    local a = ease((phase - 10.4) / 2)
    view = viewport.copy(amp_close)
    viewport.set_amp_span(view, mix(amp_close.a1 - amp_close.a0,
      amp_wheel.a1 - amp_wheel.a0, a))
    pointer_x, pointer_y, down, hot =
      0.985, mix(rail_end_y, rail_start_y, a), true, "amp_body"
    status = "Drag down to restore the rail"
  elseif phase < 14.4 then
    local a = ease((phase - 12.4) / 2)
    view = viewport.copy(close_time)
    viewport.zoom_amp(view, mix(amp_wheel_gain, 1, a), 0)
    pointer_x, pointer_y = mix(0.985, ruler_end_x, a), mix(rail_start_y, ruler_y, a)
    status = "Alt + mouse wheel · restore amplitude"
  elseif phase < 14.55 then
    view, pointer_x, pointer_y, hot, ruler_hovered =
      close_time, ruler_end_x, ruler_y, "ruler", true
    status = "Return to the time ruler"
  elseif phase < 14.75 then
    view = phase < 14.65 and close_time or wide
    pointer_x, pointer_y, down, hot, ruler_hovered =
      ruler_end_x, ruler_y, true, "ruler", true
    status = "Right-click the ruler · reset the view"
  else
    local a = ease((phase - 14.75) / .8)
    view, pointer_x, pointer_y = wide, mix(ruler_end_x, ruler_start_x, a), ruler_y
    status = "Whole sound in view"
  end
  return view, pointer_x, pointer_y, down, hot, ruler_hovered, status
end

local function draw_navigation(ctx, dl, x, y, width, height, demo, elapsed)
  local pad = 0
  local x0, y0 = x + pad, y + pad
  local panel_w, panel_h = width - pad * 2, height - pad * 2
  local phase = elapsed % 15.55
  local view, pointer_fraction, pointer_fraction_y, down, hot, ruler_hovered, status =
    navigation_view(demo.signal, phase, panel_h)
  local pointer_x = x0 + panel_w * pointer_fraction
  local pointer_y = y0 + panel_h * pointer_fraction_y
  draw_wave_panel(ctx, dl, demo.signal, x0, y0, panel_w, panel_h, view, {
    key = "navigation", ruler = true, navigation = true,
    pointer_x = (hot == "ruler" or ruler_hovered) and pointer_x or nil,
    hot = hot, ruler_hovered = ruler_hovered,
    gain = 10 ^ (-12 / 20),
  })
  release_pointer.paint(dl, pointer_x, pointer_y, down)
  return status
end

local function draw_detail(ctx, dl, x, y, width, height, demo, elapsed)
  local pad = 0
  local detail = demo.signal.detail
  local phase = elapsed % 6.9
  local amount
  if phase < 3.5 then amount = ease(phase / 3.5)
  elseif phase < 3.9 then amount = 1
  else amount = 1 - ease((phase - 3.9) / 3) end
  local close_span = 60 * detail.timing.step
  local full_span = demo.signal.duration
  local span = full_span * ((close_span / full_span) ^ amount)
  local samples = span / detail.timing.step
  local centre = detail.timing.t0 + detail.count * detail.timing.step * 0.5
  local view = viewport.configure(viewport.new(), demo.signal.duration,
    demo.signal.sample_rate)
  viewport.set_time(view, centre - span * 0.5, centre + span * 0.5)
  local drawn_detail
  for _, level in ipairs(demo.signal.detail_levels or {}) do
    if view.t0 >= level.t0 and view.t1 <= level.t1 then drawn_detail = level end
  end
  if view.t0 >= detail.t0 and view.t1 <= detail.t1 then drawn_detail = detail end
  draw_wave_panel(ctx, dl, demo.signal, x + pad, y + pad,
    width - pad * 2, height - pad * 2, view,
    { key = "detail", ruler = true, detail = drawn_detail })
  return string.format("%.0f source samples visible", samples)
end

local MOTION_ICONS = {
  { name = "mono", label = "Mono" },
  { name = "music-2", label = "Pitch" },
  { name = "target", label = "Loudness" },
  { name = "repeat", label = "Loop" },
  { name = "link", label = "Latch" },
  { name = "play", label = "Play" },
}
local ACCENT_ICONS = { "repeat", "music-2", "target" }
local BUTTON_START_DELAY = 0.75
local BUTTON_STAGGER = 0.55
local BUTTON_ON_TIME = 2.8
local BUTTON_CYCLE = 4.5
local SWITCH_INTERVAL = 2.2
local PITCH_UNIT_INTERVAL = 2.4
local ACCENT_INTERVAL = 1.8

local function card(ctx, dl, x, y, w, h, label)
  local header_h = M.BASE_FS + M.WINDOW_PAD * 2
  reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x + w, y + h,
    T.BG_CHROME, frame_rounding(ctx))
  reaper.ImGui_DrawList_AddRectFilled(dl, x, y + header_h, x + w, y + h,
    T.FILL_QUATERNARY, frame_rounding(ctx))
  reaper.ImGui_DrawList_AddLine(dl, x, y + header_h, x + w, y + header_h,
    T.STROKE_TERTIARY, 1)
  reaper.ImGui_DrawList_AddRect(dl, x + 0.5, y + 0.5, x + w - 0.5, y + h - 0.5,
    T.STROKE_TERTIARY, frame_rounding(ctx), 0, 1)
  local bold = theme.push_bold_font(ctx)
  text(dl, x + M.WINDOW_PAD, y + M.WINDOW_PAD, T.TEXT_PRIMARY, label)
  if bold then reaper.ImGui_PopFont(ctx) end
  return y + header_h, h - header_h
end

local function motion_button_columns(ctx, width)
  local size = reaper.ImGui_GetFrameHeight(ctx) * 1.7
  local fit = math.floor((width - M.WINDOW_PAD * 2)
    / (size + M.ITEM_SPACING_X * 4))
  local columns = fit >= 6 and 6 or fit >= 3 and 3 or fit >= 2 and 2 or 1
  return size, columns
end

local function draw_icon_example(ctx, dl, res, demo, elapsed, x, y, w, h)
  local body_y, body_h = card(ctx, dl, x, y, w, h, "Buttons")
  local size, columns = motion_button_columns(ctx, w)
  local rows = math.ceil(#MOTION_ICONS / columns)
  local cell_w = (w - M.WINDOW_PAD * 2) / columns
  local row_h = size + M.ITEM_SPACING_Y + M.BASE_FS
  local total_h = rows * row_h + (rows - 1) * M.ITEM_SPACING_Y * 2
  local top = body_y + (body_h - total_h) * 0.5
  local font = res and res.icon_font
  for index, spec in ipairs(MOTION_ICONS) do
    local state = demo.motion.buttons[index]
    if not state then
      state = { on = false, manual_until = 0 }
      demo.motion.buttons[index] = state
    end
    if elapsed < (state.elapsed or 0) then state.manual_until = 0 end
    state.elapsed = elapsed
    -- Offset later controls later in time, following the gallery's reading order.
    local step_elapsed = elapsed - BUTTON_START_DELAY - (index - 1) * BUTTON_STAGGER
    local scheduled = step_elapsed >= 0 and step_elapsed % BUTTON_CYCLE < BUTTON_ON_TIME
    local previous = state.on
    local changed = elapsed >= state.manual_until and scheduled ~= previous
    if changed then state.on = scheduled end
    local col, row = (index - 1) % columns, math.floor((index - 1) / columns)
    local cx = x + M.WINDOW_PAD + (col + 0.5) * cell_w
    local by = top + row * (row_h + M.ITEM_SPACING_Y * 2)
    local bx = cx - size * 0.5
    local id = "release_motion_" .. demo.id .. "_" .. spec.name
    reaper.ImGui_SetCursorScreenPos(ctx, bx, by)
    local clicked
    if spec.name == "mono" then
      -- Enlarge the shared control; its two circles keep the production motion.
      reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(),
        M.FRAME_PAD_X, (size - reaper.ImGui_GetFontSize(ctx)) * 0.5)
      clicked = widgets.toggle(ctx, id, "M", state.on, nil, font, nil, true, "mono")
      reaper.ImGui_PopStyleVar(ctx)
    else
      clicked = widgets.panel_button_frame(ctx, "##" .. id, size, size, state.on)
      local next_on = state.on
      if clicked then next_on = not next_on end
      local colour = next_on and T.ACCENT_HOVER or T.TEXT_SECONDARY
      if spec.name == "play" then
        widgets.play_bloom(ctx, id, next_on)
        icons.paint_glyph(ctx, font, next_on and "pause" or "play",
          cx, by + size * 0.5, colour, M.ICON_FS * 1.5)
      else
        icon_motion.paint(ctx, id, spec.name, cx, by + size * 0.5, colour,
          previous, next_on ~= previous, true, M.ICON_FS * 1.5, font, size)
      end
    end
    if clicked then
      state.on = not state.on
      state.manual_until = elapsed + 4
    end
    local tw = reaper.ImGui_CalcTextSize(ctx, spec.label)
    text(dl, cx - tw * 0.5, by + size + M.ITEM_SPACING_Y,
      T.TEXT_SECONDARY, spec.label)
  end
end

local function switch_content_height(ctx)
  local row_h = reaper.ImGui_GetFrameHeight(ctx) * 1.5 + M.ITEM_SPACING_Y + M.BASE_FS
  return row_h * 2 + M.ITEM_SPACING_Y * 2
end

local function draw_switch_example(ctx, dl, demo, elapsed, x, y, w, h)
  local body_y, body_h = card(ctx, dl, x, y, w, h, "Switches")
  local size_scale = 1.5
  local control_h = reaper.ImGui_GetFrameHeight(ctx) * size_scale
  local row_h = control_h + M.ITEM_SPACING_Y + M.BASE_FS
  local top = body_y + (body_h - switch_content_height(ctx)) * 0.5
  if elapsed >= (demo.motion.switch_manual_until or 0) then
    demo.motion.animations = math.floor(elapsed / SWITCH_INTERVAL) % 2 == 1
  end
  reaper.ImGui_SetCursorScreenPos(ctx,
    x + (w - M.SET_SWITCH_W * size_scale) * 0.5, top)
  if widgets.switch(ctx, "release_switch_" .. demo.id,
      demo.motion.animations, nil, true, nil, size_scale) then
    demo.motion.animations = not demo.motion.animations
    demo.motion.switch_manual_until = elapsed + 4
  end
  local tw = reaper.ImGui_CalcTextSize(ctx, "On / Off")
  text(dl, x + (w - tw) * 0.5, top + control_h + M.ITEM_SPACING_Y,
    T.TEXT_SECONDARY, "On / Off")
  if elapsed >= (demo.motion.pitch_manual_until or 0) then
    demo.motion.pitch_unit = math.floor(elapsed / PITCH_UNIT_INTERVAL) % 2 == 0
      and "st" or "percent"
  end
  local pitch_y = top + row_h + M.ITEM_SPACING_Y * 2
  reaper.ImGui_SetCursorScreenPos(ctx,
    x + (w - M.PITCH_UNIT_W * 2 * size_scale) * 0.5, pitch_y)
  local selected = widgets.pitch_units(ctx, "release_pitch_units_" .. demo.id,
    demo.motion.pitch_unit, size_scale)
  if selected then
    demo.motion.pitch_unit = selected
    demo.motion.pitch_manual_until = elapsed + 4
  end
  tw = reaper.ImGui_CalcTextSize(ctx, "Pitch Units")
  text(dl, x + (w - tw) * 0.5, pitch_y + control_h + M.ITEM_SPACING_Y,
    T.TEXT_SECONDARY, "Pitch Units")
end

local function accent_content_layout(ctx, width)
  local columns = width >= scaled(320) and 4 or 2
  local rows = #theme.accent_options / columns
  local button_h = reaper.ImGui_GetFrameHeight(ctx) * 1.25
  local face = reaper.ImGui_GetFrameHeight(ctx) * 1.5
  local content_h = rows * button_h + (rows - 1) * M.ITEM_SPACING_X
    + M.ITEM_SPACING_X * 2 + face
  return columns, button_h, face, content_h
end

local function draw_accent_example(ctx, dl, res, demo, elapsed, x, y, w, h)
  local body_y, body_h = card(ctx, dl, x, y, w, h, "Accent Colour")
  local options = theme.accent_options
  local motion = demo.motion
  if elapsed < (motion.accent_elapsed or 0) then
    motion.accent_target, motion.accent_manual_until = nil, nil
  end
  motion.accent_elapsed = elapsed
  local selected = math.floor(elapsed / ACCENT_INTERVAL) % #options + 1
  if elapsed < (motion.accent_manual_until or 0) then
    selected = motion.accent_manual
  end
  local target = options[selected]
  if not motion.accent_colour then motion.accent_colour = target.color end
  if motion.accent_target ~= selected then
    motion.accent_from = motion.accent_colour
    motion.accent_start, motion.accent_target = elapsed, selected
  end
  local amount = ease((elapsed - motion.accent_start) / theme.motion.ACCENT_FADE)
  local shown = theme.blend(motion.accent_from, target.color, amount)
  motion.accent_colour = shown
  local fill = (shown & ~0xFF) | (T.ACTIVE_CONTROL_FILL & 0xFF)
  local border = (shown & ~0xFF) | (T.ACTIVE_CONTROL_BORDER & 0xFF)
  local columns, button_h, face, content_h = accent_content_layout(ctx, w)
  local gap, pad = M.ITEM_SPACING_X, M.WINDOW_PAD
  local button_w = (w - pad * 2 - gap * (columns - 1)) / columns
  local top = body_y + (body_h - content_h) * 0.5
  for index, option in ipairs(options) do
    local bx = x + pad + (index - 1) % columns * (button_w + gap)
    local by = top + math.floor((index - 1) / columns) * (button_h + gap)
    local active = index == selected
    reaper.ImGui_SetCursorScreenPos(ctx, bx, by)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),
      active and fill or T.FILL_TERTIARY)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),
      active and border or T.STROKE_SECONDARY)
    local clicked = reaper.ImGui_Button(ctx,
      "##release_accent_" .. demo.id .. option.id, button_w, button_h)
    reaper.ImGui_PopStyleColor(ctx, 2)
    widgets.button_bloom(ctx, "release_accent_" .. demo.id .. option.id,
      active, option.color, clicked, true)
    local chip = M.ICON_SM_FS
    local tw, th = reaper.ImGui_CalcTextSize(ctx, option.label)
    local left = bx + (button_w - chip - gap - tw) * 0.5
    local cy = by + button_h * 0.5
    reaper.ImGui_DrawList_AddRectFilled(dl, left, cy - chip * 0.5,
      left + chip, cy + chip * 0.5, option.color, frame_rounding(ctx))
    text(dl, left + chip + gap, cy - th * 0.5,
      active and shown or T.TEXT_SECONDARY, option.label)
    if clicked then
      motion.accent_manual, motion.accent_manual_until = index, elapsed + 4
    end
  end
  -- The same selected controls change together, as they do under Appearance.
  local total = #ACCENT_ICONS * face + (#ACCENT_ICONS - 1) * gap
  local by = top + content_h - face
  for index, name in ipairs(ACCENT_ICONS) do
    local bx = x + (w - total) * 0.5 + (index - 1) * (face + gap)
    reaper.ImGui_DrawList_AddRectFilled(dl, bx, by, bx + face, by + face,
      fill, frame_rounding(ctx))
    reaper.ImGui_DrawList_AddRect(dl, bx, by, bx + face, by + face,
      border, frame_rounding(ctx), 0, 1)
    icon_motion.paint_pose(ctx, res and res.icon_font, name,
      bx + face * 0.5, by + face * 0.5, shown, 1, nil, M.ICON_FS * 1.5, face)
  end
end

local function draw_motion(ctx, dl, x, y, width, height, demo, elapsed, res)
  local gap = M.ITEM_SPACING_X
  local size, columns = motion_button_columns(ctx, width)
  local rows = math.ceil(#MOTION_ICONS / columns)
  local header_h = M.BASE_FS + M.WINDOW_PAD * 2
  local buttons_content_h = rows * (size + M.ITEM_SPACING_Y + M.BASE_FS)
    + (rows - 1) * M.ITEM_SPACING_Y * 2
  local card_w = (width - gap) * 0.5
  local _, _, _, accent_content_h = accent_content_layout(ctx, card_w)
  local lower_content_h = math.max(switch_content_height(ctx), accent_content_h)
  -- Share spare height between the upper and lower cards instead of leaving
  -- the button row tightly packed while the lower cards absorb all the room.
  local padding = math.max(0,
    (height - gap - header_h * 2 - buttons_content_h - lower_content_h) / 4)
  local buttons_h = header_h + buttons_content_h + padding * 2
  local lower_h = math.max(1, height - buttons_h - gap)
  draw_icon_example(ctx, dl, res, demo, elapsed, x, y, width, buttons_h)
  draw_switch_example(ctx, dl, demo, elapsed,
    x, y + buttons_h + gap, card_w, lower_h)
  draw_accent_example(ctx, dl, res, demo, elapsed,
    x + card_w + gap, y + buttons_h + gap, card_w, lower_h)
  return "Interface motion examples"
end

local function measure_layout(demo, key, width, height, prefs, first_share)
  local geometry = spectrum_layout.measure(width, height, 0, 0,
    M.RULER_H, M.WAVE_MIN_H, M.WAVE_HIDE_H,
    M.SPECTRUM_PANE_MIN_W, M.SPECTRUM_SPLIT_GAP,
    first_share or 0.46, first_share or 0.42, M.SPECTRUM_STACK_WAVE_MIN_H,
    M.SPECTRUM_STACK_MIN_H, prefs, demo.last_modes[key])
  if geometry.both then demo.last_modes[key] = geometry.mode end
  return geometry
end

local function draw_layout_stage(ctx, dl, res, demo, key, elapsed,
    x, y, width, height, prefs, first_share)
  width, height = math.max(1, width), math.max(1, height)
  reaper.ImGui_DrawList_AddRect(dl, x + 0.5, y + 0.5,
    x + width - 0.5, y + height - 0.5, T.STROKE_TERTIARY,
    frame_rounding(ctx), 0, 1)
  local inset = math.min(M.WINDOW_PAD, (width - 1) * .5, (height - 1) * .5)
  x, y = x + inset, y + inset
  width, height = width - inset * 2, height - inset * 2
  local geometry = measure_layout(demo, key, width, height, prefs, first_share)
  if geometry.visual_h > 0 then
    if geometry.both then
      draw_wave_panel(ctx, dl, demo.signal,
        x + geometry.wave_x, y + geometry.wave_y,
        geometry.wave_w, geometry.wave_total_h,
        { t0 = 0, t1 = 1, a0 = -1, a1 = 1 },
        { key = "layout_" .. key, ruler = geometry.ruler })
      release_spectrum.paint_plot(ctx, res, demo.spectrum, elapsed,
        x + geometry.spectrum_x, y + geometry.spectrum_y,
        geometry.spectrum_w, geometry.spectrum_h)
    else
      draw_wave_panel(ctx, dl, demo.signal, x, y, width, geometry.wave_total_h,
        { t0 = 0, t1 = 1, a0 = -1, a1 = 1 },
        { key = "layout_" .. key, ruler = geometry.ruler })
    end
  end
  local gap
  if geometry.mode == "horizontal" then
    gap = { x = x + geometry.divider_x, y = y,
      w = M.SPECTRUM_SPLIT_GAP, h = geometry.visual_h }
  elseif geometry.mode == "vertical" then
    gap = { x = x, y = y + geometry.divider_y,
      w = width, h = M.SPECTRUM_SPLIT_GAP }
  end
  return geometry, gap
end

local function auto_geometry(phase, full_width, full_height)
  local normal_height = math.min(scaled(300), full_height * 0.7)
  local small_height = math.min(scaled(220), full_height * 0.5)
  local width, height = full_width, normal_height
  local pointer_axis, pointer_x, pointer_y, down = "vertical", width * 0.72, height
  local status = "Side by Side"
  if phase < 2 then
    local a = ease(phase / 2)
    height, pointer_y, down = mix(normal_height, full_height, a), mix(normal_height, full_height, a), true
  elseif phase < 2.6 then
    height = full_height
    local a = ease((phase - 2) / .6)
    pointer_axis = "horizontal"
    pointer_x, pointer_y = mix(width * 0.72, width, a), mix(height, height * 0.55, a)
    status = "Move to the right edge"
  elseif phase < 4.6 then
    local a = ease((phase - 2.6) / 2)
    width, height = mix(full_width, math.min(full_width, scaled(420)), a), full_height
    pointer_axis, pointer_x, pointer_y, down = "horizontal", width, height * 0.55, true
  elseif phase < 5.2 then
    width, height = math.min(full_width, scaled(420)), full_height
    local a = ease((phase - 4.6) / .6)
    pointer_x, pointer_y = mix(width, width * 0.72, a), mix(height * 0.55, height, a)
    status = "Move to the bottom edge"
  elseif phase < 7.2 then
    local a = ease((phase - 5.2) / 2)
    width, height = math.min(full_width, scaled(420)), mix(full_height, small_height, a)
    pointer_x, pointer_y, down = width * 0.72, height, true
  elseif phase < 7.45 then
    width, height = math.min(full_width, scaled(420)), small_height
    pointer_x, pointer_y = width * .72, height
  elseif phase < 9.45 then
    local a = ease((phase - 7.45) / 2)
    width, height = math.min(full_width, scaled(420)), mix(small_height, full_height, a)
    pointer_x, pointer_y, down = width * 0.72, height, true
  elseif phase < 10.05 then
    width, height = math.min(full_width, scaled(420)), full_height
    local a = ease((phase - 9.45) / .6)
    pointer_axis = "horizontal"
    pointer_x, pointer_y = mix(width * 0.72, width, a), mix(height, height * 0.55, a)
    status = "Move to the right edge"
  elseif phase < 12.05 then
    local a = ease((phase - 10.05) / 2)
    width, height = mix(math.min(full_width, scaled(420)), full_width, a), full_height
    pointer_axis, pointer_x, pointer_y, down = "horizontal", width, height * 0.55, true
  elseif phase < 12.65 then
    width, height = full_width, full_height
    local a = ease((phase - 12.05) / .6)
    pointer_x, pointer_y = mix(width, width * 0.72, a), mix(height * 0.55, height, a)
    status = "Move to the bottom edge"
  elseif phase < 14.65 then
    local a = ease((phase - 12.65) / 2)
    width, height = full_width, mix(full_height, normal_height, a)
    pointer_x, pointer_y, down = width * 0.72, height, true
  end
  return width, height, pointer_axis, pointer_x, pointer_y, down, status
end

local function mode_name(mode)
  if mode == "horizontal" then return "Side by Side" end
  if mode == "vertical" then return "Stacked" end
  return "Waveform only"
end

local function draw_auto_layout(ctx, dl, x, y, width, height, demo, elapsed, res)
  local pad = 0
  local full_width = math.max(1, width - pad * 2)
  -- Enter the loop at full size, just before the pointer starts shrinking it.
  local phase = (elapsed + 2) % 14.65
  local model_w, model_h, axis, px, py, down, move_status =
    auto_geometry(phase, full_width, height)
  local geometry = draw_layout_stage(ctx, dl, res, demo, "auto", elapsed,
    x + pad, y + pad, model_w, model_h,
    { mode = "auto", horizontal_first = "waveform", vertical_first = "waveform" })
  draw_resize_pointer(dl, x + pad + px, y + pad + py, axis, down)
  if not down and move_status ~= mode_name(geometry.mode) then return move_status end
  return (down and "Resizing · " or "") .. mode_name(geometry.mode)
end

local function draw_swap_layout(ctx, dl, x, y, width, height, demo, elapsed, res)
  local pad = 0
  local stage_w, stage_h = width, height
  local sx, sy = x + pad, y + pad
  local phase = elapsed % 4
  local cycle = math.floor(elapsed / 4)
  local automated_press = phase >= .45 and phase < .6
  local dragging = phase >= 1.55 and phase < 3.05
  -- Alternate the drag direction so the split carries smoothly into each swap.
  local from_share, to_share = .42, .58
  if cycle % 2 == 1 then from_share, to_share = to_share, from_share end
  local first_share = mix(from_share, to_share, ease((phase - 1.55) / 1.5))
  local requested = stage_w - M.WINDOW_PAD * 2 >= M.SPECTRUM_PANE_MIN_W * 2 + M.SPECTRUM_SPLIT_GAP
    and "horizontal" or "vertical"
  if phase >= .45 and demo.swap_cycle ~= cycle then
    demo.swap_start = cycle * 4 + .45
    if phase >= .6 then
      demo.swap_cycle = cycle
      local key = requested == "horizontal" and "horizontal_first" or "vertical_first"
      demo[key] = demo[key] == "waveform" and "spectrum" or "waveform"
    end
  end
  local geometry, gap = draw_layout_stage(ctx, dl, res, demo, "swap", elapsed,
    sx, sy, stage_w, stage_h,
    { mode = requested, horizontal_first = demo.horizontal_first,
      vertical_first = demo.vertical_first }, first_share)
  if not gap then return "Waveform only at this width" end

  local face = reaper.ImGui_GetFrameHeight(ctx)
  local vertical = geometry.mode == "vertical"
  local face_x = vertical and gap.x + scaled(8) or gap.x + (gap.w - face) * 0.5
  local face_y = vertical and gap.y + (gap.h - face) * 0.5 or gap.y + scaled(8)
  reaper.ImGui_SetCursorScreenPos(ctx, face_x, face_y)
  local clicked = reaper.ImGui_InvisibleButton(ctx,
    "##release_swap_" .. demo.id, face, face)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  if clicked then
    local key = vertical and "vertical_first" or "horizontal_first"
    demo[key] = demo[key] == "waveform" and "spectrum" or "waveform"
    demo.swap_start = elapsed
  end

  local target_x, target_y = face_x + face * 0.5, face_y + face * 0.5
  local home_x, home_y = sx + stage_w * 0.22, sy + stage_h * 0.70
  local grab_x = vertical and gap.x + gap.w * .7 or gap.x + gap.w * .5
  local grab_y = vertical and gap.y + gap.h * .5 or gap.y + gap.h * .7
  local pointer_x, pointer_y = target_x, target_y
  if cycle == 0 and phase < .35 then
    local approach = ease(phase / .35)
    pointer_x, pointer_y = mix(home_x, target_x, approach), mix(home_y, target_y, approach)
  elseif phase >= .9 then
    local travel = ease((phase - .9) / .5)
    local returning = ease((phase - 3.25) / .55)
    pointer_x, pointer_y = mix(target_x, grab_x, travel), mix(target_y, grab_y, travel)
    pointer_x, pointer_y = mix(pointer_x, target_x, returning), mix(pointer_y, target_y, returning)
  end
  local scripted_hover = pointer_x >= face_x and pointer_x <= face_x + face
    and pointer_y >= face_y and pointer_y <= face_y + face
  local on_divider = not scripted_hover and pointer_x >= gap.x and pointer_x <= gap.x + gap.w
    and pointer_y >= gap.y and pointer_y <= gap.y + gap.h
  if hovered or scripted_hover or on_divider then
    reaper.ImGui_DrawList_AddRectFilled(dl, gap.x, gap.y,
      gap.x + gap.w, gap.y + gap.h,
      (automated_press or dragging) and T.FILL_PRIMARY or T.FILL_SECONDARY)
    reaper.ImGui_DrawList_AddRectFilled(dl, face_x, face_y,
      face_x + face, face_y + face,
      automated_press and T.FILL_PRIMARY or T.BG_CHROME, frame_rounding(ctx))
    reaper.ImGui_DrawList_AddRect(dl, face_x + 0.5, face_y + 0.5,
      face_x + face - 0.5, face_y + face - 0.5,
      T.STROKE_PRIMARY, frame_rounding(ctx), 0, 1)
    local since = elapsed - (demo.swap_start or -100)
    local progress = since >= 0 and since <= theme.motion.ICON_SWAP
      and since / theme.motion.ICON_SWAP or nil
    icon_motion.paint_pose(ctx, res and res.icon_font, "arrow-left-right",
      target_x, target_y, T.TEXT_PRIMARY, 0, progress, M.ICON_FS, face)
  end
  tips.show(ctx, hovered, "Swap waveform and spectrum positions.",
    "release_swap_" .. demo.id)
  if on_divider then
    draw_resize_pointer(dl, pointer_x, pointer_y, vertical and "vertical" or "horizontal", dragging)
  else
    release_pointer.paint(dl, pointer_x, pointer_y, automated_press)
  end
  local first = vertical and demo.vertical_first or demo.horizontal_first
  if vertical then
    return first == "waveform" and "Waveform top" or "Spectrum top"
  end
  return first == "waveform" and "Waveform left" or "Spectrum left"
end

function examples.draw(ctx, res, demo, topic_id, elapsed, width, height)
  demo = demo or examples.new()
  elapsed = tonumber(elapsed) or 0
  local dl, x, y, w, h = begin_canvas(ctx, width, height)
  local status
  if topic_id == "waveform_navigation" then
    status = draw_navigation(ctx, dl, x, y, w, h, demo, elapsed)
  elseif topic_id == "waveform_detail" then
    status = draw_detail(ctx, dl, x, y, w, h, demo, elapsed)
  elseif topic_id == "buttons_feedback" then
    status = draw_motion(ctx, dl, x, y, w, h, demo, elapsed, res)
  elseif topic_id == "layout_auto" then
    status = draw_auto_layout(ctx, dl, x, y, w, h, demo, elapsed, res)
  elseif topic_id == "layout_swap" then
    status = draw_swap_layout(ctx, dl, x, y, w, h, demo, elapsed, res)
  end
  finish_canvas(ctx, dl, x, y, w, h)
  return status
end

return examples
