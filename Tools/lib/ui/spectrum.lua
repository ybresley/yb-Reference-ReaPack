-- Spectrum drawing reads only pre-filter measurements. Listening exclusions
-- are a separate wash; they never feed back into the plotted values.
local theme = require('ui.theme')
local mathx = require('core.spectrum_math')
local curve_shape = require('core.spectrum_curve')
local filter = require('core.monitor_filter')
local icons = require('ui.icons')
local widgets = require('ui.widgets')
local tips = require('ui.tips')
local settings = require('ui.filterwin')
local entry = require('ui.filter_entry')
local focus = require('ui.focus')
local helper_status = require('ui.spectrum_status')
local controls = require('ui.spectrum_controls')
local hover_peaks = require('ui.spectrum_hover')
local frequency_axis = require('ui.spectrum_axis')
local level_axis = require('ui.spectrum_level_axis')
local T, M = theme.tokens, theme.metrics
local spectrum = {}
local drag, focused_handle
local values = {live = {}, average = {}}
local clear_bounds = {}
local live_readout = {}
local live_input = {}
local axis_input = {}
local LIVE_LINE_W = 1.35
local LIVE_READOUT_FADE = 0.15
local applied_band_motion = {
  generation = nil, active = nil, selected_id = nil,
  frame = nil,
}
function spectrum.clear_handle_focus()
  focused_handle, drag = nil, nil
end

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function highlight_colour(amount)
  local colour = 0
  for shift = 0, 24, 8 do
    local live = (T.SPECTRUM_LIVE >> shift) & 0xFF
    local held = (T.TEXT_PRIMARY >> shift) & 0xFF
    colour = colour | (math.floor(live + (held - live) * amount + 0.5) << shift)
  end
  return colour
end

local function clear_live_readout(live_readout)
  live_readout.active, live_readout.alpha, live_readout.last_time = nil, nil, nil
  live_readout.mx, live_readout.yy, live_readout.bx, live_readout.by = nil, nil, nil, nil
  live_readout.text, live_readout.tw, live_readout.th = nil, nil, nil
end

local function fade_live_readout(live_readout, now, visible)
  local elapsed = math.max(0, math.min(LIVE_READOUT_FADE, now - (live_readout.last_time or now)))
  local amount = elapsed / LIVE_READOUT_FADE
  local alpha = live_readout.alpha or 0
  live_readout.alpha = clamp(alpha + (visible and amount or -amount), 0, 1)
  live_readout.last_time = now
  return live_readout.alpha
end

local function prepare_live_readout(ctx, live_readout, now, eligible, data)
  local frame = reaper.ImGui_GetFrameCount(ctx)
  local invalid = live_readout.last_frame and frame ~= live_readout.last_frame + 1
    or live_readout.model ~= data.model
    or live_readout.source_key ~= data.source_key
    or live_readout.epoch ~= data.epoch
    or live_readout.history_epoch ~= data.history_epoch
    or live_readout.tilt ~= data.tilt
    or live_readout.fmin ~= data.fmin or live_readout.fmax ~= data.fmax
    or live_readout.bottom ~= data.bottom
    or live_readout.gx ~= data.gx or live_readout.gy ~= data.gy
    or live_readout.gw ~= data.gw or live_readout.gh ~= data.gh
  if not data.draw_live then
    clear_live_readout(live_readout)
    return
  end
  if invalid then clear_live_readout(live_readout) end
  live_readout.last_frame = frame
  live_readout.model, live_readout.source_key = data.model, data.source_key
  live_readout.epoch, live_readout.history_epoch = data.epoch, data.history_epoch
  live_readout.tilt = data.tilt
  live_readout.fmin, live_readout.fmax, live_readout.bottom = data.fmin, data.fmax, data.bottom
  live_readout.gx, live_readout.gy, live_readout.gw, live_readout.gh =
    data.gx, data.gy, data.gw, data.gh

  if eligible then
    local hz = mathx.fraction_frequency((data.mx - data.gx) / data.gw, data.fmin, data.fmax)
    local db = mathx.sample_log_values(data.model.live, data.count, hz, data.fmin, data.fmax)
    db = db and mathx.tilted_db(db, hz, data.model.prefs.tilt)
    if db and db >= data.bottom then
      local text = string.format('%.0f Hz · %s · %.1f dB', hz, mathx.frequency_note(hz), db)
      local tw, th = reaper.ImGui_CalcTextSize(ctx, text)
      local yy = data.gy + mathx.db_fraction(db, 6, data.bottom) * data.gh
      live_readout.mx, live_readout.yy = data.mx, yy
      -- Clear the whole arrow, including its tail; flip before clamping at an edge.
      local box_w, box_h = tw + data.pad * 2, th + data.pad
      local gap_x, gap_y = M.ITEM_SPACING_X * 3, M.ITEM_SPACING_Y * 4
      local bx, by = data.mx + gap_x, data.my + gap_y
      if bx + box_w > data.gx + data.gw then bx = data.mx - box_w - gap_x end
      if by + box_h > data.gy + data.gh then by = data.my - box_h - data.pad end
      live_readout.bx = clamp(bx, data.gx, math.max(data.gx, data.gx + data.gw - box_w))
      live_readout.by = clamp(by, data.gy, math.max(data.gy, data.gy + data.gh - box_h))
      live_readout.text, live_readout.tw, live_readout.th = text, tw, th
      live_readout.active = true
    else
      eligible = false
    end
  end
  if not live_readout.active then return end
  local alpha = fade_live_readout(live_readout, now, eligible)
  if alpha <= 0 and not eligible then
    clear_live_readout(live_readout)
    return
  end
  return live_readout
end

local function draw_live_readout(dl, live_readout, data)
  local alpha = live_readout.alpha
  reaper.ImGui_DrawList_PushClipRect(dl, data.gx, data.gy, data.gx + data.gw, data.gy + data.gh, true)
  reaper.ImGui_DrawList_AddLine(dl, live_readout.mx, live_readout.yy, live_readout.mx, data.gy + data.gh,
    theme.fade(T.TEXT_PRIMARY, 0.3 * alpha), theme.scale)
  reaper.ImGui_DrawList_AddCircleFilled(dl, live_readout.mx, live_readout.yy, M.UPDATE_DOT_R,
    theme.fade(T.TEXT_PRIMARY, alpha))
  reaper.ImGui_DrawList_AddRectFilled(dl, live_readout.bx, live_readout.by,
    live_readout.bx + live_readout.tw + data.pad * 2, live_readout.by + live_readout.th + data.pad,
    theme.fade(T.BG_POPUP, alpha), 3 * theme.scale)
  reaper.ImGui_DrawList_AddText(dl, live_readout.bx + data.pad, live_readout.by + data.pad / 2,
    theme.fade(T.TEXT_PRIMARY, alpha), live_readout.text)
  reaper.ImGui_DrawList_PopClipRect(dl)
end

-- Callers supply separate readout state so demonstrations cannot affect the live hover.
spectrum.prepare_readout = prepare_live_readout
spectrum.paint_readout = draw_live_readout

local function curve(dl, data, count, gx, gy, width, height, bottom, colour, fill, draw,
    line_width, round_corners)
  line_width = (line_width or 1.25) * theme.scale
  local points = colour and draw and draw.batch
  local used = 0
  local function flush()
    if points and used > 1 then
      points.resize(used * 2)
      reaper.ImGui_DrawList_AddPolyline(dl, points, colour, 0, line_width)
      points.resize(2048)
    end
    used = 0
  end
  local function stroke(x1, y1, x2, y2)
    if not colour then return end
    reaper.ImGui_DrawList_AddLine(dl, x1, y1, x2, y2, colour, line_width)
  end
  local last_x, last_y, last_fill_column
  -- Round only the held outline between its existing measurement positions.
  -- Subdivision is bounded even in a very wide graph.
  local subdivisions = round_corners and curve_shape.subdivisions(count, width) or 1
  local previous_db = data[1]
  for step = 1, (count - 1) * subdivisions do
    local position = 1 + step / subdivisions
    local next_db = round_corners and curve_shape.sample(data, count, position) or data[position]
    local x1, d1, x2, d2 = mathx.clip_segment_to_floor(
      gx + (position - 1 / subdivisions - 0.5) / count * width, previous_db,
      gx + (position - 0.5) / count * width, next_db, bottom)
    previous_db = next_db
    if x1 then
      local y1 = gy + mathx.db_fraction(d1, 6, bottom) * height
      local y2 = gy + mathx.db_fraction(d2, 6, bottom) * height
      if fill then
        -- Draw each screen column once. The old translucent quads overlapped
        -- heavily when many bins landed inside one pixel, producing moving
        -- vertical bands in narrow graphs.
        local first = math.ceil(x1 - 0.5)
        local final = math.floor(x2 - 0.5)
        if last_fill_column then first = math.max(first, last_fill_column + 1) end
        for column = first, final do
          local t = x2 == x1 and 0 or clamp((column + 0.5 - x1) / (x2 - x1), 0, 1)
          local yy = y1 + (y2 - y1) * t
          reaper.ImGui_DrawList_AddRectFilled(dl, column, yy, column + 1,
            gy + height, fill)
          last_fill_column = column
        end
      end
      if points then
        if used == 1024 or not last_x
            or math.abs(x1 - last_x) > 0.01 or math.abs(y1 - last_y) > 0.01 then
          flush(); used = 1; points[1], points[2] = x1, y1
        end
        used = used + 1; points[used * 2 - 1], points[used * 2] = x2, y2
      else
        stroke(x1, y1, x2, y2)
      end
      last_x, last_y = x2, y2
    else
      flush(); last_x, last_y, last_fill_column = nil, nil, nil
    end
  end
  flush()
end

-- Shared paint path accepts measured values without reading live graph state.
spectrum.paint_curve = curve

-- Live and demonstrated inspection share the brightening and held-line handover.
local function paint_inspection(dl, data, count, gx, gy, gw, gh, bottom, draw, capture, draw_live)
  local highlight = capture.highlight or 0
  if draw_live and highlight > 0 then
    -- Draw both hover strokes as separate segments so sharp turns cannot
    -- stretch their corners into bright vertical spikes.
    curve(dl, data, count, gx, gy, gw, gh, bottom,
      theme.fade(T.TEXT_PRIMARY, 0.14 * highlight), nil, nil, 2.5)
  end
  if draw_live then curve(dl, data, count, gx, gy, gw, gh, bottom,
    highlight_colour(highlight), T.SPECTRUM_LIVE_FILL,
    not (capture.pending or capture.active) and draw or nil,
    LIVE_LINE_W + (1.1 - LIVE_LINE_W) * highlight) end
  if capture.opacity > 0 then curve(dl, capture.outline, capture.count, gx, gy, gw, gh, bottom,
    theme.fade(T.TEXT_PRIMARY, capture.opacity), theme.fade(T.ACCENT_WASH, capture.opacity),
    draw, LIVE_LINE_W, true) end
end
spectrum.paint_inspection = paint_inspection

function spectrum.paint_applied_band_illumination(ctx, dl, id,
    low_x, top, high_x, bottom, active, trigger)
  local progress = widgets.motion_event(ctx, id, active, 0.5, trigger)
  if not progress then return end
  local pulse = math.sin(math.pi * progress) ^ 2
  local alpha = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha()))
  reaper.ImGui_DrawList_AddRectFilled(dl, low_x, top, high_x, bottom,
    theme.fade(T.ACCENT, 0.18 * pulse * alpha))
end

local function clear_button(ctx, res, x, y)
  local size = reaper.ImGui_GetFrameHeight(ctx)
  local rounding = select(1,
    reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding()))
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  -- Match the filter controls' opaque backing so the trace cannot show through.
  reaper.ImGui_DrawList_AddRectFilled(dl,
    x, y, x + size, y + size, T.BG_POPUP, rounding)
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), T.FILL_PRIMARY)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(), 0)
  local clicked = reaper.ImGui_Button(ctx, '##reset_spectrum_history', size, size)
  reaper.ImGui_PopStyleColor(ctx, 4)
  local button_hovered = reaper.ImGui_IsItemHovered(ctx)
  local colour = button_hovered and T.TEXT_PRIMARY or T.TEXT_SECONDARY
  if not icons.paint_over_item(ctx, res and res.icon_font, 'rotate-ccw', {color = colour}) then
    local alpha = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha())
    icons.draw_reset(dl, x + size * 0.5, y + size * 0.5, theme.fade(colour, alpha))
  end
  widgets.button_outline(ctx, button_hovered and T.TEXT_QUATERNARY or T.STROKE_PRIMARY)
  tips.show(ctx, button_hovered, 'Clear Spectrum History', 'reset_spectrum_history')
  if clicked then return {type = 'reset_spectrum_history'} end
end

function spectrum.draw(ctx, state, width, height, res, input_exclusion)
  local model, listening = state.spectrum, state.monitor_filter
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local pad, scale = M.SPECTRUM_PLOT_PAD, theme.scale
  local axis = height >= M.WAVE_MIN_H and M.RULER_H or 0
  local gx, gy = x + pad, y
  local gw = math.max(1, width - pad - M.SPECTRUM_LEVEL_W)
  local gh = math.max(1, height - axis)
  local graph_right, graph_bottom = gx + gw, gy + gh
  local fmin, fmax = model.fmin or 10, model.fmax or 22050
  local bottom = -model.prefs.range
  local mx, my = reaper.ImGui_GetMousePos(ctx)
  local hovered = reaper.ImGui_IsWindowHovered(ctx)
    and reaper.ImGui_IsMouseHoveringRect(ctx, x, y, x + width, y + height)
  local input_excluded = input_exclusion
    and controls.contains(input_exclusion, mx, my)
  -- Holding a button blocks ordinary window hover, but must not hide its row.
  local controls_visible = settings.is_open()
    or (listening.system.available == true and listening.on)
    or (reaper.ImGui_IsWindowHovered(ctx,
      reaper.ImGui_HoveredFlags_AllowWhenBlockedByActiveItem())
      and reaper.ImGui_IsMouseHoveringRect(ctx, gx, gy, graph_right, graph_bottom))
  -- Match the waveform: the filled picture stops before its ruler. Frequency
  -- labels sit below it on the window background, and level labels sit in the
  -- bare gutter to its right. Both pictures now end on the same horizontal line.
  reaper.ImGui_DrawList_AddRectFilled(dl,
    x, y, graph_right, graph_bottom, T.SPECTRUM_BG, 3 * scale)
  reaper.ImGui_Dummy(ctx, width, height)

  local zero_y = gy + mathx.db_fraction(0, 6, bottom) * gh
  for db = 0, bottom, -5 do
    local fy = mathx.db_fraction(db, 6, bottom)
    local yy = gy + fy * gh
    local colour = db % 10 == 0 and T.SPECTRUM_GRID
      or theme.fade(T.SPECTRUM_GRID, 0.55)
    local tick = axis > 0 and (db % 10 == 0 and M.RULER_TICK_MAJOR
      or M.RULER_TICK_MINOR) or 0
    reaper.ImGui_DrawList_AddLine(dl, gx, yy, graph_right + tick, yy,
      theme.fade(colour, 0.35 + 0.65 * (1 - fy) ^ 0.85))
  end
  for offset = -2, 2 do
    reaper.ImGui_DrawList_AddLine(dl, gx, zero_y + offset * scale,
      graph_right + (axis > 0 and M.RULER_TICK_MAJOR or 0),
      zero_y + offset * scale, theme.fade(T.SPECTRUM_GRID,
        offset == 0 and 1 or math.abs(offset) == 1 and 0.12 or 0.05), scale)
  end
  for decade = 1, 4 do
    for multiple = 1, 9 do
      local hz = 10 ^ decade * multiple
      if hz > fmin and hz <= fmax then
        local xx = gx + mathx.frequency_fraction(hz, fmin, fmax) * gw
        reaper.ImGui_DrawList_AddLine(dl, xx, gy, xx, graph_bottom,
          theme.fade(T.SPECTRUM_FREQ_GRID, mathx.frequency_grid_prominence(multiple)))
      end
    end
  end

  local available = listening.system.available == true
  local draw_live = available and model.live_visible and model.ready
  local usable_history = available and model.status ~= 'stale' and model.status ~= 'invalid'
  local draw_average = usable_history and model.average_ready and model.prefs.average ~= 'off'
  local count = model.count or 0
  local low_x = gx + mathx.frequency_fraction(listening.low_hz, fmin, fmax) * gw
  local high_x = gx + mathx.frequency_fraction(listening.high_hz, fmin, fmax) * gw
  local selected_band = listening.system.available == true and listening.on
  local audible_band = selected_band and listening.system.audible
  local controls_drawn = controls.update_overlay(ctx, controls_visible) > 0
  local overlay_bounds = controls.overlay_bounds(ctx, x, y, width, height, axis)
  local overlay_hot = controls_drawn and controls.contains(overlay_bounds, mx, my)
  local near_handle = selected_band
    and (math.abs(mx - low_x) <= M.SPAN_GRAB or math.abs(mx - high_x) <= M.SPAN_GRAB)
  local clearable_average = draw_average
    and (model.prefs.average == 'infinite' or not model.playing)
  local show_clear = hovered and model.has_history and clearable_average
  if show_clear then
    local size = reaper.ImGui_GetFrameHeight(ctx)
    clear_bounds.x0 = input_exclusion and input_exclusion.x1 + M.ITEM_SPACING_X or gx
    clear_bounds.y0 = y + M.SPECTRUM_PLOT_PAD
    clear_bounds.x1, clear_bounds.y1 = clear_bounds.x0 + size, clear_bounds.y0 + size
  end
  local clear_hot = show_clear and controls.contains(clear_bounds, mx, my)
  reaper.ImGui_DrawList_PushClipRect(dl, gx, gy, gx + gw, gy + gh, true)
  for i = 1, count do
    local hz = mathx.bin_frequency(i, count, fmin, fmax)
    if draw_live then values.live[i] = mathx.tilted_db(model.live[i], hz, model.prefs.tilt) end
    if draw_average then values.average[i] = mathx.tilted_db(model.average[i], hz, model.prefs.tilt) end
  end
  local capture = hover_peaks.prepare(ctx, model, draw_live and values.live or nil,
    hovered and draw_live and not input_excluded and not overlay_hot and not near_handle and not clear_hot
      and not entry.is_open() and not reaper.ImGui_IsAnyItemActive(ctx)
      and not reaper.ImGui_IsMouseDown(ctx, 0) and not reaper.ImGui_IsMouseDown(ctx, 1)
      and not reaper.ImGui_IsMouseDown(ctx, 2)
      and mx >= gx and mx <= graph_right and my >= gy and my <= graph_bottom,
    gx, gy, gw)
  if draw_average then curve(dl, values.average, count, gx, gy, gw, gh, bottom,
    nil, T.SPECTRUM_AVERAGE_FILL, model.draw) end
  paint_inspection(dl, values.live, count, gx, gy, gw, gh, bottom,
    model.draw, capture, draw_live)

  local illuminate = false
  local audible_preset = audible_band and listening.selected_id ~= nil
  if theme.motion.enabled and reaper.ImGui_GetFrameCount then
    local frame = reaper.ImGui_GetFrameCount(ctx)
    local stale = not applied_band_motion.frame or frame > applied_band_motion.frame + 1
    if applied_band_motion.generation ~= theme.motion.generation or stale then
      applied_band_motion.generation = theme.motion.generation
      applied_band_motion.active = audible_preset
      applied_band_motion.selected_id = listening.selected_id
    elseif audible_preset ~= applied_band_motion.active
        or listening.selected_id ~= applied_band_motion.selected_id then
      -- `audible` is the helper's acknowledgement. A requested or rejected
      -- range never reaches this path, so it cannot claim to be live.
      -- Handle and exact-range edits clear the preset, so they never pulse.
      illuminate = audible_preset
      applied_band_motion.active = audible_preset
      applied_band_motion.selected_id = listening.selected_id
    end
    applied_band_motion.frame = frame
  end
  if audible_band then
    reaper.ImGui_DrawList_AddRectFilled(dl, gx, gy, low_x, gy + gh, T.SPAN_DIM)
    reaper.ImGui_DrawList_AddRectFilled(dl, high_x, gy, gx + gw, gy + gh, T.SPAN_DIM)
  end
  -- Illuminate the applied range evenly without moving its boundaries.
  spectrum.paint_applied_band_illumination(ctx, dl, 'spectrum_applied_band',
    low_x, gy, high_x, gy + gh, audible_preset, illuminate)
  reaper.ImGui_DrawList_PopClipRect(dl)

  local action, handle_hot
  -- Handle focus is local to this graph. It does not enable ImGui navigation
  -- throughout the app or change the existing forwarding of Reaper shortcuts.
  if not reaper.ImGui_IsWindowFocused(ctx) or reaper.ImGui_IsMouseClicked(ctx, 0)
      or reaper.ImGui_IsMouseClicked(ctx, 1) then focused_handle = nil end
  if focused_handle and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
    focused_handle = nil
    focus.request()
  end
  local handles_interactive = not settings.is_open() and not entry.is_open()
  if selected_band then
    for _, boundary in ipairs({'low', 'high'}) do
      local xx = boundary == 'low' and low_x or high_x
      local hx0 = math.max(gx, xx - M.SPAN_GRAB)
      local hx1 = math.min(gx + gw, xx + M.SPAN_GRAB)
      local middle = (low_x + high_x) * 0.5
      if boundary == 'low' then hx1 = math.min(hx1, middle) else hx0 = math.max(hx0, middle) end
      local hot, held = false, false
      -- A drag that began on the handle keeps normal mouse capture, but the
      -- joined control row wins hit-testing when a new gesture starts over it.
      if drag == boundary
          or handles_interactive and not overlay_hot and not input_excluded then
        reaper.ImGui_SetCursorScreenPos(ctx, hx0, gy)
        reaper.ImGui_InvisibleButton(ctx, '##spectrum_' .. boundary, math.max(1, hx1 - hx0), gh)
        hot, held = reaper.ImGui_IsItemHovered(ctx), reaper.ImGui_IsItemActive(ctx)
        handle_hot = handle_hot or hot or held
        if hot or held then reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeEW()) end
        if hot and reaper.ImGui_IsMouseClicked(ctx, 0) then
          drag, focused_handle = boundary, boundary
        end
        if focused_handle == boundary then focus.keep_zone(hx0, gy, hx1, gy + gh) end
        if hot and reaper.ImGui_IsMouseClicked(ctx, 1)
            or focused_handle == boundary and not reaper.ImGui_IsMouseDown(ctx, 0)
              and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter()) then
          entry.open_at(xx, gy, gy + gh, boundary)
          focused_handle = nil
        end
        if held and drag == boundary then
          local hz = mathx.fraction_frequency(clamp((mx - gx) / gw, 0, 1), fmin, fmax)
          hz = math.min(hz, listening.system.max_filter_hz or filter.MAX_HZ)
          action = {type = 'set_monitor_filter_boundary', boundary = boundary, hz = hz, commit = false}
        elseif drag == boundary and reaper.ImGui_IsItemDeactivated(ctx) then
          action = {type = 'set_monitor_filter_boundary', boundary = boundary,
            hz = listening[boundary .. '_hz'], commit = true}
          drag = nil
        end
      end
      reaper.ImGui_DrawList_AddLine(dl, xx, gy, xx, gy + gh,
        theme.fade(T.TEXT_PRIMARY, (hot or held) and 0.9 or 0.45), scale)
      reaper.ImGui_DrawList_AddRectFilled(dl, xx - scale, gy + gh / 2 - 6 * scale,
        xx + scale, gy + gh / 2 + 6 * scale, hot and T.ACCENT or T.TEXT_SECONDARY, scale)
      if hot or held then
        local label = tostring(listening[boundary .. '_hz']) .. ' Hz'
        local tw = reaper.ImGui_CalcTextSize(ctx, label)
        reaper.ImGui_DrawList_AddText(dl, clamp(xx - tw / 2, gx, gx + gw - tw), gy + pad,
          T.TEXT_PRIMARY, label)
      end
      tips.show(ctx, hot and not held,
        'Drag to adjust. Right-click, or click then press Enter, to type a frequency.', 'spectrum_' .. boundary)
    end
  else spectrum.clear_handle_focus() end

  local live_eligible = hovered and not input_excluded
    and not overlay_hot and not handle_hot and draw_live
    and mx >= gx and mx <= gx + gw and my >= gy and my <= gy + gh
  live_input.model, live_input.source_key, live_input.epoch = model, model.source_key, model.epoch
  live_input.history_epoch, live_input.tilt, live_input.draw_live =
    model.history_epoch, model.prefs.tilt, draw_live
  live_input.fmin, live_input.fmax, live_input.bottom = fmin, fmax, bottom
  live_input.gx, live_input.gy, live_input.gw, live_input.gh = gx, gy, gw, gh
  live_input.mx, live_input.my, live_input.pad, live_input.count = mx, my, pad, count
  hover_peaks.draw_labels(ctx, dl, gx, gy, gw, gh, bottom, input_exclusion,
    controls_drawn and overlay_bounds or nil, show_clear and clear_bounds or nil)
  axis_input.gx, axis_input.gy, axis_input.gw, axis_input.gh = gx, gy, gw, gh
  axis_input.axis, axis_input.fmin, axis_input.fmax, axis_input.bottom = axis, fmin, fmax, bottom
  axis_input.mx, axis_input.my = mx, my
  axis_input.draw_live = draw_live
  axis_input.level_right = x + width - M.SPECTRUM_BAND_GAP
  axis_input.eligible = hovered and not input_excluded and not overlay_hot
    and not settings.is_open() and not entry.is_open() and not reaper.ImGui_IsAnyItemActive(ctx)
    and not reaper.ImGui_IsMouseDown(ctx, 0) and not reaper.ImGui_IsMouseDown(ctx, 1)
    and not reaper.ImGui_IsMouseDown(ctx, 2)
  local pointer_readout = prepare_live_readout(ctx, live_readout, reaper.ImGui_GetTime(ctx), live_eligible, live_input)
  local ruler_readout = frequency_axis.draw(ctx, dl, model, axis_input)
  level_axis.draw(ctx, dl, axis_input)
  if pointer_readout and not ruler_readout then draw_live_readout(dl, live_readout, live_input) end
  if not available then
    action = action or helper_status.draw(ctx, listening.system, gx, gy, gw, gh)
  elseif model.status == 'stale' or model.status == 'invalid'
      or not model.fresh and not model.has_history and not draw_live
      or not model.has_signal and not model.has_history and not draw_live then
    local waiting = model.status == 'stale' or model.status == 'invalid'
    local message = waiting and 'Waiting for spectrum data' or 'No Signal'
    local tw, th = reaper.ImGui_CalcTextSize(ctx, message)
    reaper.ImGui_DrawList_AddText(dl, x + math.max(pad, (width - tw) / 2), gy + math.max(0, (gh - th) / 2),
      waiting and T.TEXT_SECONDARY or T.TEXT_QUATERNARY, message)
  end
  -- Timed histories refill immediately during playback; clearing is useful
  -- for Infinite accumulation or for history left after playback stops.
  if show_clear then
    local clear_action = clear_button(ctx, res, clear_bounds.x0, clear_bounds.y0)
    action = action or clear_action
  end
  local controls_action = controls.overlay(ctx, state, res, x, y, width, height, axis)
  action = action or controls_action
  reaper.ImGui_SetCursorScreenPos(ctx, x, y + height)
  reaper.ImGui_Dummy(ctx, width, 0)
  return action
end

return spectrum
