-- Paint-only spectrum demonstrations for the release showcase. The module owns
-- its measured signal and interaction state; it never opens the live panels or
-- returns actions that could change monitoring.
local theme = require("ui.theme")
local icons = require("ui.icons")
local mathx = require("core.spectrum_math")
local curve_shape = require("core.spectrum_curve")
local hover_model = require("core.spectrum_hover")
local label_model = require("core.spectrum_labels")
local filter = require("core.monitor_filter")
local signal = require('ui.release_signal')
local spectrum = require('ui.spectrum')
local filterwin = require('ui.filterwin')
local pointer = require('ui.release_pointer')
local filter_demo = require('core.release_filter_demo')
local peak_demo = require('core.release_peak_demo')
local overview_demo = require('core.release_overview_demo')
local frequency_axis = require('ui.spectrum_axis')
local settings_layout = require('core.release_settings_layout')

local T, M = theme.tokens, theme.metrics
local release_spectrum = {}

local BIN_COUNT = signal.bins
local FMIN, FMAX = 10, 22050
local TOP_DB, BOTTOM_DB = 6, -90
local passive_axis = { eligible = false, fmin = FMIN, fmax = FMAX }
local ANALYSIS_OPTIONS = {
  motion_mode = 'power', attack_seconds = .012,
  release_seconds = mathx.power_release_seconds(20, .9), average_seconds = 3,
}
local DECODE = {}
local ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
for i = 1, #ALPHABET do DECODE[ALPHABET:byte(i)] = i - 1 end

local function decode_frame(frame, target)
  for i = 1, BIN_COUNT do
    local code = DECODE[frame:byte(i * 2 - 1)] * 64 + DECODE[frame:byte(i * 2)]
    target[i] = signal.db_min + code * signal.db_step
  end
end

local function update_display(demo, tilt)
  tilt = tonumber(tilt) or 4.5
  for i = 1, BIN_COUNT do
    local hz = mathx.bin_frequency(i, BIN_COUNT, FMIN, FMAX)
    demo.live[i] = mathx.tilted_db(demo.analysis.live[i], hz, tilt)
    demo.average[i] = mathx.tilted_db(mathx.average_db(demo.analysis, i), hz, tilt)
  end
end

local function clamp(value, low, high)
  return math.max(low, math.min(high, value))
end

local function smoothstep(value)
  value = clamp(value, 0, 1)
  return value * value * (3 - 2 * value)
end

local function move(from, to, progress)
  return from + (to - from) * smoothstep(progress)
end

local function alpha(colour, amount)
  return theme.fade(colour, clamp(amount, 0, 1))
end

function release_spectrum.new()
  local analysis = mathx.new(BIN_COUNT, signal.db_min)
  local demo = {
    analysis = analysis,
    live = {},
    average = {},
    target = {},
    hover = hover_model.new(),
    labels = label_model.new(),
    hover_input = {},
    overview_model = { live = analysis.live, count = BIN_COUNT, prefs = { tilt = 4.5 },
      fmin = FMIN, fmax = FMAX, bottom = BOTTOM_DB },
    overview_readout = {},
    overview_input = {},
    settings_state = {
      spectrum = { prefs = {
        resolution = "balanced", smoothing = "1/12", speed = "balanced",
        average = "off", hover_peaks = "hold", range = 90, tilt = 4.5,
      } },
      monitor_filter = filter.defaults(),
    },
    settings_preview = {},
    band_story = {},
    band_motion = { selected_id = false },
    listening = filter.defaults(),
    topic = nil,
    last_spectrum_elapsed = nil,
  }
  decode_frame(signal.frames[1], demo.target)
  mathx.update(analysis, demo.target, 0, ANALYSIS_OPTIONS)
  update_display(demo, 4.5)
  return demo
end

local function update_signal(demo, elapsed, tilt)
  tilt = tonumber(tilt) or 4.5
  if demo.last_spectrum_elapsed == elapsed and demo.last_display_tilt == tilt then return end
  local previous = demo.last_spectrum_elapsed
  local dt = math.max(0, math.min(.1, elapsed - (previous or elapsed)))
  demo.last_spectrum_elapsed = elapsed
  demo.last_display_tilt = tilt
  local duration = signal.spectrum_duration
  local phase = duration > 0 and elapsed % (duration * 2) or 0
  local sample_time = phase <= duration and phase or duration * 2 - phase
  local frame = math.min(#signal.frames, math.floor(sample_time / signal.frame_step) + 1)
  if demo.last_frame ~= frame then
    decode_frame(signal.frames[frame], demo.target)
    demo.last_frame = frame
  end
  mathx.update(demo.analysis, demo.target, dt, ANALYSIS_OPTIONS)
  update_display(demo, tilt)
end

local function db_y(db, gy, gh)
  return gy + mathx.db_fraction(db, TOP_DB, BOTTOM_DB) * gh
end

local function draw_trace(dl, demo, values, gx, gy, gw, gh, line_colour, fill_colour,
    rounded, line_width)
  spectrum.paint_curve(dl, values, BIN_COUNT, gx, gy, gw, gh, BOTTOM_DB,
    line_colour, fill_colour, demo.draw, (line_width or 1.25 * theme.scale) / theme.scale, rounded)
end

local FREQUENCY_LABELS = {
  { 20, "20" }, { 50, "50" }, { 100, "100" }, { 200, "200" },
  { 500, "500" }, { 1000, "1k" }, { 2000, "2k" }, { 5000, "5k" },
  { 10000, "10k" }, { 20000, "20k" },
}

local function draw_grid(ctx, dl, gx, gy, gw, gh, axis_h, right, shared_axis)
  for db = 0, BOTTOM_DB, -5 do
    local fraction = mathx.db_fraction(db, TOP_DB, BOTTOM_DB)
    local yy = gy + fraction * gh
    local strong = db % 10 == 0
    reaper.ImGui_DrawList_AddLine(dl, gx, yy, gx + gw, yy,
      alpha(T.SPECTRUM_GRID, (strong and 0.72 or 0.30) * (1 - fraction * 0.45)))
  end
  local zero_y = db_y(0, gy, gh)
  for offset = -2, 2 do
    reaper.ImGui_DrawList_AddLine(dl, gx, zero_y + offset * theme.scale,
      gx + gw, zero_y + offset * theme.scale,
      alpha(T.SPECTRUM_GRID, offset == 0 and 1 or math.abs(offset) == 1 and 0.12 or 0.05),
      theme.scale)
  end
  for decade = 1, 4 do
    for multiple = 1, 9 do
      local hz = 10 ^ decade * multiple
      if hz > FMIN and hz <= FMAX then
        local xx = gx + mathx.frequency_fraction(hz, FMIN, FMAX) * gw
        reaper.ImGui_DrawList_AddLine(dl, xx, gy, xx, gy + gh,
          alpha(T.SPECTRUM_FREQ_GRID, mathx.frequency_grid_prominence(multiple)))
      end
    end
  end
  if axis_h <= 0 then return end
  if not shared_axis then
    passive_axis.gx, passive_axis.gy = gx, gy
    passive_axis.gw, passive_axis.gh, passive_axis.axis = gw, gh, axis_h
    frequency_axis.draw(ctx, dl, nil, passive_axis)
  end
  local small = theme.push_small_font(ctx)
  local last_level_y = gy - reaper.ImGui_GetTextLineHeight(ctx) - theme.scale
  for db = 0, BOTTOM_DB, -10 do
    local text = db == 0 and "0" or tostring(db)
    local tw, th = reaper.ImGui_CalcTextSize(ctx, text)
    local yy = clamp(db_y(db, gy, gh) - th * 0.5, gy, gy + gh - th)
    if yy >= last_level_y + th + theme.scale then
      reaper.ImGui_DrawList_AddText(dl, right - tw, yy, T.TEXT_TERTIARY, text)
      last_level_y = yy
    end
  end
  if small then reaper.ImGui_PopFont(ctx) end
end

local function draw_pencil(dl, cx, cy, colour)
  icons.draw_pencil(dl, cx, cy, colour)
end

local function draw_sliders(dl, cx, cy, colour)
  local s = theme.scale
  local xs = { 2.5, -2.5, 3.5 }
  for index = 1, 3 do
    local yy = cy + (index - 2) * 5 * s
    local knob = cx + xs[index] * s
    reaper.ImGui_DrawList_AddLine(dl, cx - 7 * s, yy, knob - 2 * s, yy, colour, s)
    reaper.ImGui_DrawList_AddLine(dl, knob + 2 * s, yy, cx + 7 * s, yy, colour, s)
    reaper.ImGui_DrawList_AddLine(dl, knob, yy - 2 * s, knob, yy + 2 * s, colour, 1.5 * s)
  end
end

local function draw_region_icon(dl, x0, y0, x1, y1, low, high, colour)
  local s = theme.scale
  local start_x = (x0 + x1) * 0.5 - 9.5 * s
  local base = (y0 + y1) * 0.5 + 4.5 * s
  local width, height = 19 * s, 8 * s
  local left = start_x + filter.frequency_to_t(low) * width
  local right = start_x + filter.frequency_to_t(high) * width
  local rise_start = math.max(start_x, left - 2 * s)
  local fall_end = math.min(start_x + width, right + 2 * s)
  local function amount_at(x)
    local rise = low <= filter.MIN_HZ and 1
      or smoothstep((x - rise_start) / math.max(0.001, left - rise_start))
    local fall = high >= filter.MAX_HZ and 1
      or smoothstep((fall_end - x) / math.max(0.001, fall_end - right))
    return math.min(rise, fall)
  end
  for column = math.ceil(start_x), math.floor(start_x + width - 0.001) do
    local amount = amount_at(column + 0.5)
    if amount > 0 then
      reaper.ImGui_DrawList_AddRectFilled(dl, column, base - amount * height,
        column + 1, base, alpha(colour, 0.3))
    end
  end
  local previous_x, previous_y
  for step = 0, math.max(1, math.floor(width + 0.5)) do
    local xx = start_x + step
    local yy = base - amount_at(xx) * height
    if previous_x then
      reaper.ImGui_DrawList_AddLine(dl, previous_x, previous_y, xx, yy, colour, s)
    end
    previous_x, previous_y = xx, yy
  end
  if low <= filter.MIN_HZ then
    reaper.ImGui_DrawList_AddLine(dl, start_x, base, start_x, base - height, colour, s)
  end
  if high >= filter.MAX_HZ then
    reaper.ImGui_DrawList_AddLine(dl, start_x + width, base,
      start_x + width, base - height, colour, s)
  end
  reaper.ImGui_DrawList_AddLine(dl, start_x, base, start_x + width, base,
    alpha(colour, 0.2), s)
end

local function bar_geometry(ctx, x, y, width, height, axis_h)
  local frame = reaper.ImGui_GetFrameHeight(ctx)
  local content_w = (#filter.PRESETS + 2) * frame
  local plot_w = math.max(1, width - M.SPECTRUM_LEVEL_W)
  local left = x + math.max(M.SPECTRUM_PLOT_PAD, (plot_w - content_w) * 0.5)
  local top = math.max(y + M.SPECTRUM_PLOT_PAD,
    y + height - axis_h - frame - M.SPECTRUM_PLOT_PAD)
  return left, top, frame, content_w
end

local function draw_filter_bar(ctx, dl, res, left, top, frame, content_w,
    selected_id, settings_open, custom)
  local rounding = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding()))
  local pad = 2 * theme.scale
  reaper.ImGui_DrawList_AddRectFilled(dl, left - pad, top - pad,
    left + content_w + pad, top + frame + pad, T.BG_POPUP, rounding + pad)
  reaper.ImGui_DrawList_AddRect(dl, left - pad + 0.5, top - pad + 0.5,
    left + content_w + pad - 0.5, top + frame + pad - 0.5,
    T.STROKE_SECONDARY, rounding + pad, 0, 1)

  for segment = 1, #filter.PRESETS + 2 do
    local x0, x1 = left + (segment - 1) * frame, left + segment * frame
    local selected
    if segment == 1 then
      selected = custom
    elseif segment > 1 and segment <= #filter.PRESETS + 1 then
      selected = selected_id == filter.PRESETS[segment - 1].id
    elseif segment == #filter.PRESETS + 2 then
      selected = settings_open
    end
    if selected then
      reaper.ImGui_DrawList_AddRectFilled(dl, x0, top, x1, top + frame,
        T.ACTIVE_CONTROL_FILL, rounding)
      reaper.ImGui_DrawList_AddRect(dl, x0 + 0.5, top + 0.5,
        x1 - 0.5, top + frame - 0.5, T.ACTIVE_CONTROL_BORDER, rounding, 0, 1)
    elseif segment < #filter.PRESETS + 2 then
      reaper.ImGui_DrawList_AddLine(dl, x1, top + 4 * theme.scale,
        x1, top + frame - 4 * theme.scale, T.STROKE_PRIMARY)
    end
    local colour = selected and T.ACCENT_HOVER or T.TEXT_SECONDARY
    local cx, cy = (x0 + x1) * 0.5, top + frame * 0.5
    if segment == 1 then
      if not icons.paint_glyph(ctx, res and res.icon_font, "pencil",
          cx, cy, colour, M.ICON_FS) then draw_pencil(dl, cx, cy, colour) end
    elseif segment == #filter.PRESETS + 2 then
      if not icons.paint_glyph(ctx, res and res.icon_font, "sliders-horizontal",
          cx, cy, colour, M.ICON_FS) then draw_sliders(dl, cx, cy, colour) end
    else
      local preset = filter.PRESETS[segment - 1]
      draw_region_icon(dl, x0, top, x1, top + frame,
        preset.low_hz, preset.high_hz, colour)
    end
  end
end

local function draw_cursor(dl, x, y, pulse)
  pointer.paint(dl, x, y, pulse)
end

local function click_pulse(phase, at)
  local delta = phase - at
  if delta < 0 or delta > 0.55 then return nil end
  return delta / 0.55
end

local function band_script(demo, story, left, top, frame, gx, gy, gw, gh, home_x, home_y)
  local function target(name)
    if name == 'bass' then return left + 2.5 * frame, top + frame * 0.5 end
    if name == 'mid' then return left + 4.5 * frame, top + frame * 0.5 end
    local hz = name == 'low_handle' and 700 or name == 'low_dragged' and 180
      or name == 'high_handle' and 3000 or name == 'high_dragged' and 6000
    if hz then return gx + mathx.frequency_fraction(hz, FMIN, FMAX) * gw, gy + gh / 2 end
    return home_x, home_y
  end
  local x0, y0 = target(story.from)
  local x1, y1 = target(story.target)
  local value = demo.listening
  value.on, value.low_hz, value.high_hz = story.on, story.low, story.high
  value.selected_id = story.preset or nil
  return move(x0, x1, story.progress), move(y0, y1, story.progress),
    story.pulse or (story.held and true or nil)
end

local function text(dl, x, y, colour, value)
  reaper.ImGui_DrawList_AddText(dl, x, y, colour, value)
end

local function settings_values(demo, elapsed)
  local phase = elapsed
  local prefs = demo.settings_state.spectrum.prefs
  prefs.average = phase >= 3.5 and "3s" or "off"
  prefs.tilt = phase >= 6.23 and 0 or 4.5
  return phase
end

local function settings_script(demo, elapsed, gear_x, gear_y, home_x, home_y,
    panel_x, panel_y, panel_w, ctx, start_x, start_y)
  local phase = elapsed
  local targets = demo.settings_preview.targets or {}
  local row_h = reaper.ImGui_GetTextLineHeight(ctx)
  local average = targets.average or {
    x = panel_x + panel_w - M.WINDOW_PAD * 2 - M.SPECTRUM_OPTION_W * 0.5,
    y = panel_y + panel_w * 0.69,
  }
  local tilt = targets.tilt or {
    x = average.x,
    y = panel_y + M.SPECTRUM_SETTINGS_H - 55 * theme.scale,
  }
  local average_choice = targets.average_3s or {
    x = average.x,
    y = (average.y1 or average.y + reaper.ImGui_GetFrameHeight(ctx) * .5)
      + M.WINDOW_PAD + row_h * 2.5 + M.ITEM_SPACING_Y * 2,
  }
  local tilt_choice = targets.tilt_0 or {
    x = tilt.x,
    y = (tilt.y1 or tilt.y + reaper.ImGui_GetFrameHeight(ctx) * .5)
      + M.WINDOW_PAD + row_h * .5,
  }
  local preview = demo.settings_preview
  preview.open_combo, preview.highlight_value, preview.selected_value = nil, nil, nil
  if phase >= 2.2 and phase < 3.65 then
    preview.open_combo = "average"
    preview.selected_value = phase >= 3.5 and "3s" or "off"
    if phase >= 3.32 then preview.highlight_value = "3s" end
  elseif phase >= 4.93 and phase < 6.38 then
    preview.open_combo = "tilt"
    preview.selected_value = phase >= 6.23 and 0 or 4.5
    if phase >= 6.05 then preview.highlight_value = 0 end
  end
  if phase < .65 then
    return false, "spectrum", move(start_x, gear_x, phase / .65),
      move(start_y, gear_y, phase / .65), nil, "Open settings."
  elseif phase < .9 then
    return false, "spectrum", gear_x, gear_y, nil, "Open settings."
  elseif phase < 1.55 then
    return true, "spectrum", gear_x, gear_y, click_pulse(phase, .9),
      "Spectrum settings"
  elseif phase < 2.2 then
    return true, "spectrum",
      move(gear_x, average.x, (phase - 1.55) / .65),
      move(gear_y, average.y, (phase - 1.55) / .65), nil,
      "Turn on Average."
  elseif phase < 2.85 then
    return true, "spectrum", average.x, average.y, click_pulse(phase, 2.2),
      "Choose Average."
  elseif phase < 3.5 then
    return true, "spectrum",
      move(average.x, average_choice.x, (phase - 2.85) / .65),
      move(average.y, average_choice.y, (phase - 2.85) / .65), nil,
      "Choose 3 s."
  elseif phase < 4.15 then
    return true, "spectrum", average_choice.x, average_choice.y,
      click_pulse(phase, 3.5), "Average · 3 s"
  elseif phase < 4.93 then
    return true, "spectrum",
      move(average_choice.x, tilt.x, (phase - 4.15) / .78),
      move(average_choice.y, tilt.y, (phase - 4.15) / .78), nil,
      "Set Tilt to Flat."
  elseif phase < 5.58 then
    return true, "spectrum", tilt.x, tilt.y, click_pulse(phase, 4.93),
      "Choose Tilt."
  elseif phase < 6.23 then
    return true, "spectrum",
      move(tilt.x, tilt_choice.x, (phase - 5.58) / .65),
      move(tilt.y, tilt_choice.y, (phase - 5.58) / .65), nil,
      "Choose Flat."
  elseif phase < 6.88 then
    return true, "spectrum", tilt_choice.x, tilt_choice.y,
      click_pulse(phase, 6.23), "Tilt · Flat"
  elseif phase < 7.71 then
    return true, "spectrum",
      move(tilt_choice.x, home_x, (phase - 6.88) / .83),
      move(tilt_choice.y, home_y, (phase - 6.88) / .83), nil,
      "Close settings."
  elseif phase < 7.86 then
    return true, "spectrum", home_x, home_y, click_pulse(phase, 7.71),
      "Close settings."
  end
  return false, "spectrum", home_x, home_y, nil, "Settings closed."
end

local function update_hover(demo, elapsed, eligible, mx, my, gx, gy, gw)
  local input = demo.hover_input
  input.now = elapsed
  input.eligible = eligible
  input.x, input.y = (mx - gx) / theme.scale, (my - gy) / theme.scale
  input.count, input.values = BIN_COUNT, demo.live
  input.fmin, input.fmax = FMIN, FMAX
  input.tilt, input.width = 4.5, gw / theme.scale
  input.mode, input.source_key, input.epoch = "hold", "release-demo", 1
  local generation = demo.hover.generation
  hover_model.update(demo.hover, input)
  if generation ~= demo.hover.generation then label_model.reset(demo.labels) end
  local association = hover_model.label_association_distance(BIN_COUNT, FMIN, FMAX, input.width)
  label_model.update(demo.labels, demo.hover.peaks, elapsed, demo.hover.active,
    association, demo.hover.outline, demo.hover.count, input.width)
  demo.hover.highlight = hover_model.highlight_amount(demo.hover)
end

local function format_peak(hz)
  if hz >= 1000 then return string.format("%.2f kHz", hz / 1000) end
  return string.format("%.0f Hz", hz)
end

local function draw_peak_labels(ctx, dl, demo, gx, gy, gw, gh, bar_top)
  local small = theme.push_small_font(ctx)
  local line_h = reaper.ImGui_GetTextLineHeight(ctx)
  local pad_x, pad_y = M.SPECTRUM_TAG_PAD_X, M.SPECTRUM_TAG_PAD_Y
  for _, item in ipairs(demo.labels.items) do
    if item.ready and item.opacity > 0 and item.index then
      local hz = mathx.bin_frequency(item.index, BIN_COUNT, FMIN, FMAX)
      local label = format_peak(hz)
      local xx = gx + (item.index - 0.5) / BIN_COUNT * gw
      local db = curve_shape.sample_drawn(demo.hover.outline, BIN_COUNT, item.index, gw)
      local yy = db_y(db, gy, gh)
      local tw = reaper.ImGui_CalcTextSize(ctx, label)
      local x0 = clamp(xx - tw * 0.5 - pad_x, gx, gx + gw - tw - pad_x * 2)
      local y0 = clamp(yy - line_h - pad_y * 2 - M.ITEM_SPACING_Y,
        gy, bar_top - line_h - pad_y * 2 - M.ITEM_SPACING_Y)
      local opacity = item.opacity * demo.hover.opacity
      reaper.ImGui_DrawList_AddCircleFilled(dl, xx, yy, M.UPDATE_DOT_R,
        alpha(T.TEXT_PRIMARY, opacity))
      reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0,
        x0 + tw + pad_x * 2, y0 + line_h + pad_y * 2,
        alpha(T.BG_POPUP, opacity), M.SPECTRUM_BAND_GAP)
      text(dl, x0 + pad_x, y0 + pad_y, alpha(T.TEXT_PRIMARY, opacity), label)
    end
  end
  if small then reaper.ImGui_PopFont(ctx) end
end

local function draw_range_wash(dl, gx, gy, gw, gh, value)
  if not value then return end
  local low_x = gx + mathx.frequency_fraction(value.low_hz, FMIN, FMAX) * gw
  local high_x = gx + mathx.frequency_fraction(value.high_hz, FMIN, FMAX) * gw
  if not value.on then return low_x, high_x end
  reaper.ImGui_DrawList_AddRectFilled(dl, gx, gy, low_x, gy + gh, T.SPAN_DIM)
  reaper.ImGui_DrawList_AddRectFilled(dl, high_x, gy, gx + gw, gy + gh, T.SPAN_DIM)
  for i = 1, 2 do
    local xx = i == 1 and low_x or high_x
    reaper.ImGui_DrawList_AddLine(dl, xx, gy, xx, gy + gh, alpha(T.TEXT_PRIMARY, 0.45), theme.scale)
    reaper.ImGui_DrawList_AddRectFilled(dl, xx - theme.scale, gy + gh / 2 - 6 * theme.scale,
      xx + theme.scale, gy + gh / 2 + 6 * theme.scale, T.TEXT_SECONDARY, theme.scale)
  end
  return low_x, high_x
end

function release_spectrum.draw(ctx, res, demo, topic_id, elapsed, width, height)
  demo = demo or release_spectrum.new()
  topic_id = topic_id or "overview"
  elapsed = math.max(0, tonumber(elapsed) or 0)
  width, height = math.max(1, tonumber(width) or 1), math.max(1, tonumber(height) or 1)
  local topic_changed = demo.topic ~= topic_id
  if topic_changed then
    demo.topic = topic_id
    demo.overview_path = nil
    hover_model.reset(demo.hover)
    demo.hover.highlight = 0
    label_model.reset(demo.labels)
  end
  demo.draw = res and res.spectrum_draw
  local story = topic_id == 'filter_bar' and filter_demo.sample(elapsed, demo.band_story)
  if story then settings_values(demo, story.settings_phase or 0) end
  local display_tilt = story and demo.settings_state.spectrum.prefs.tilt or 4.5
  update_signal(demo, elapsed, display_tilt)

  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  reaper.ImGui_InvisibleButton(ctx, "##release_spectrum_" .. topic_id, width, height)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local plot_height = height
  local axis_h = plot_height >= M.WAVE_MIN_H and M.RULER_H or 0
  local gx, gy = x + M.SPECTRUM_PLOT_PAD, y
  local gw = math.max(1, width - M.SPECTRUM_PLOT_PAD - M.SPECTRUM_LEVEL_W)
  local gh = math.max(1, plot_height - axis_h)
  local graph_right = gx + gw
  reaper.ImGui_DrawList_PushClipRect(dl, x, y, x + width, y + height, true)
  reaper.ImGui_DrawList_AddRectFilled(dl, x, y, graph_right, gy + gh,
    T.SPECTRUM_BG, 3 * theme.scale)
  draw_grid(ctx, dl, gx, gy, gw, gh, axis_h, x + width - M.SPECTRUM_BAND_GAP,
    topic_id == 'overview')

  local bar_left, bar_top, frame, content_w = bar_geometry(ctx, x, y, width, plot_height, axis_h)
  local selected_id, settings_open, cursor_x, cursor_y, cursor_pulse, status
  local home_x, home_y = x + width * .2, y + height * .4
  if story then
    cursor_x, cursor_y, cursor_pulse = band_script(demo, story,
      bar_left, bar_top, frame, gx, gy, gw, gh, home_x, home_y)
    selected_id = demo.listening.selected_id
  end

  if topic_id == 'overview' or story and demo.settings_state.spectrum.prefs.average ~= 'off' then
    draw_trace(dl, demo, demo.average, gx, gy, gw, gh, nil, T.SPECTRUM_AVERAGE_FILL, false)
  end
  if topic_id == "peaks" then
    local eligible, hover_x, hover_y = peak_demo.pointer(
      elapsed, gx, gy, gw, gh, M.RULER_H)
    update_hover(demo, elapsed, eligible, hover_x, hover_y, gx, gy, gw)
    cursor_x, cursor_y = hover_x, hover_y
  end
  spectrum.paint_inspection(dl, demo.live, BIN_COUNT, gx, gy, gw, gh, BOTTOM_DB,
    demo.draw, demo.hover, true)
  local low_x, high_x = draw_range_wash(dl, gx, gy, gw, gh, story and demo.listening)
  if story then
    local selected_id = story.on and story.preset or false
    local motion = demo.band_motion
    local reset = topic_changed or motion.elapsed and elapsed < motion.elapsed
    local illuminate = not reset and selected_id and selected_id ~= motion.selected_id
    motion.selected_id, motion.elapsed = selected_id, elapsed
    if low_x then
      spectrum.paint_applied_band_illumination(ctx, dl,
        'release_spectrum_applied_band', low_x, gy, high_x, gy + gh,
        selected_id ~= false, illuminate)
    end
  end

  local panel_x, panel_y, panel_w
  local work
  local settings_tab
  if story and story.settings_phase then
    work = {
      left = x, top = y, right = x + width, bottom = y + height,
    }
    local gear_x = bar_left + (#filter.PRESETS + 1.5) * frame
    local gear_y = bar_top + frame * 0.5
    local preview = demo.settings_preview
    local settings_w, settings_h = filterwin.gallery_size()
    local placement = settings_layout.place(
      work, { right = gear_x + frame * .5, bottom = bar_top + frame },
      settings_w, settings_h, M.SPECTRUM_BAND_GAP)
    -- Keep room for the real child groups inside the fixed panel bounds.
    local content_scale = .9
    panel_x, panel_y, panel_w = placement.x, placement.y, placement.width * content_scale
    preview.paint_pointer = draw_cursor
    preview.scale = placement.scale * content_scale
    preview.height = placement.height
    preview.work = work
    settings_open, settings_tab, cursor_x, cursor_y, cursor_pulse, status =
      settings_script(demo, story.settings_phase, gear_x, gear_y, home_x, home_y,
        panel_x, panel_y, panel_w, ctx, cursor_x, cursor_y)
    preview.pointer_x, preview.pointer_y, preview.pointer_pulse = cursor_x, cursor_y, cursor_pulse
  end

  if topic_id == "peaks" then
    draw_peak_labels(ctx, dl, demo, gx, gy, gw, gh, bar_top)
    if demo.hover.active then
      status = "Peaks held. Move away to release."
    elseif demo.hover.pending then
      status = "Keep your pointer still to hold the peaks."
    elseif demo.hover.opacity > 0 then
      status = "Peak hold released."
    else
      status = "Hold your pointer over the graph."
    end
  elseif topic_id == "overview" then
    status = nil
  end

  draw_filter_bar(ctx, dl, res, bar_left, bar_top, frame, content_w,
    selected_id, settings_open, story and demo.listening.on and not selected_id)
  if topic_id == 'overview' then
    local on_graph
    demo.overview_path = demo.overview_path or overview_demo.capture(demo.overview_model)
    on_graph, cursor_x, cursor_y = overview_demo.pointer(elapsed, gx, gy, gw, gh, axis_h, demo.overview_path)
    local bar_pad = 2 * theme.scale
    local over_bar = cursor_x >= bar_left - bar_pad and cursor_x <= bar_left + content_w + bar_pad
      and cursor_y >= bar_top - bar_pad and cursor_y <= bar_top + frame + bar_pad
    local input = demo.overview_input
    input.model, input.source_key, input.epoch = demo.overview_model, 'release-overview', 1
    input.tilt, input.draw_live, input.count = 4.5, true, BIN_COUNT
    input.gx, input.gy, input.gw, input.gh = gx, gy, gw, gh
    input.fmin, input.fmax, input.bottom = FMIN, FMAX, BOTTOM_DB
    input.mx, input.my, input.pad = cursor_x, cursor_y, M.SPECTRUM_BAND_GAP
    input.axis, input.eligible = axis_h, true
    local readout = spectrum.prepare_readout(ctx, demo.overview_readout, elapsed, on_graph and not over_bar, input)
    local ruler_readout = frequency_axis.draw(ctx, dl, demo.overview_model, input)
    if readout and not ruler_readout then spectrum.paint_readout(dl, readout, input) end
  end
  local overlaid = story and story.settings_phase ~= nil
  if not overlaid and cursor_x and cursor_y then
    draw_cursor(dl, cursor_x, cursor_y, cursor_pulse)
  end
  reaper.ImGui_DrawList_PopClipRect(dl)
  if settings_open then
    filterwin.gallery_preview(ctx, demo.settings_state, settings_tab,
      panel_x, panel_y, "release", demo.settings_preview)
  end
  if overlaid and cursor_x and cursor_y then
    local clip_x0, clip_y0, clip_x1, clip_y1 = work.left, work.top, work.right, work.bottom
    if clip_x1 > clip_x0 and clip_y1 > clip_y0 then
      local foreground = reaper.ImGui_GetForegroundDrawList(ctx)
      reaper.ImGui_DrawList_PushClipRect(foreground,
        clip_x0, clip_y0, clip_x1, clip_y1, true)
      draw_cursor(foreground, cursor_x, cursor_y, cursor_pulse)
      reaper.ImGui_DrawList_PopClipRect(foreground)
    end
  end
  -- Overlaid forms move the cursor. Re-submit the canvas bounds so EndChild
  -- never receives a bare cursor move past its last registered item.
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  reaper.ImGui_Dummy(ctx, width, height)
  return status
end

-- The layout demonstration shares this picture without submitting live controls.
function release_spectrum.paint_plot(ctx, res, demo, elapsed, x, y, width, height)
  demo.draw = res and res.spectrum_draw
  update_signal(demo, elapsed, 4.5)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local axis_h = height >= M.WAVE_MIN_H and M.RULER_H or 0
  local gx, gy = x + M.SPECTRUM_PLOT_PAD, y
  local gw = math.max(1, width - M.SPECTRUM_PLOT_PAD - M.SPECTRUM_LEVEL_W)
  local gh = math.max(1, height - axis_h)
  reaper.ImGui_DrawList_PushClipRect(dl, x, y, x + width, y + height, true)
  reaper.ImGui_DrawList_AddRectFilled(dl, x, y, gx + gw, y + gh, T.SPECTRUM_BG)
  draw_grid(ctx, dl, gx, gy, gw, gh, axis_h, x + width - M.SPECTRUM_BAND_GAP)
  draw_trace(dl, demo, demo.live, gx, gy, gw, gh, T.SPECTRUM_LIVE, T.SPECTRUM_LIVE_FILL, false)
  local left, top, frame, bar_w = bar_geometry(ctx, x, y, width, height, axis_h)
  if bar_w <= width and height >= M.WAVE_MIN_H then
    draw_filter_bar(ctx, dl, res, left, top, frame, bar_w)
  end
  reaper.ImGui_DrawList_PopClipRect(dl)
end

-- A compact signal illustration uses the same measurements and curve as the
-- larger demos, with quiet axes and no controls competing with the FX chain.
function release_spectrum.paint_signal(ctx, res, demo, elapsed, x, y, width, height, opacity, scale)
  demo.draw = res and res.spectrum_draw
  update_signal(demo, elapsed, 4.5)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local axis_h = 23 * scale
  local gh = math.max(1, height - axis_h)
  reaper.ImGui_DrawList_PushClipRect(dl, x, y, x + width, y + height, true)
  for index = 0, 3 do
    local yy = y + gh * index / 3
    reaper.ImGui_DrawList_AddLine(dl, x, yy, x + width, yy,
      alpha(T.SPECTRUM_GRID, opacity * .5), scale)
  end
  local font = theme.push_release_font(ctx, 11 * scale)
  local last_label = x - 8 * scale
  for _, mark in ipairs(FREQUENCY_LABELS) do
    if mark[1] == 20 or mark[1] == 100 or mark[1] == 1000
        or mark[1] == 10000 or mark[1] == 20000 then
      local xx = x + mathx.frequency_fraction(mark[1], FMIN, FMAX) * width
      local tw = reaper.ImGui_CalcTextSize(ctx, mark[2])
      local label_x = clamp(xx - tw * .5, x, x + width - tw)
      if label_x >= last_label + 8 * scale then
        reaper.ImGui_DrawList_AddLine(dl, xx, y, xx, y + gh + 3 * scale,
          alpha(T.SPECTRUM_GRID, opacity * .5), scale)
        reaper.ImGui_DrawList_AddText(dl, label_x, y + gh + 6 * scale,
          alpha(T.TEXT_TERTIARY, opacity), mark[2])
        last_label = label_x + tw
      end
    end
  end
  if font then reaper.ImGui_PopFont(ctx) end
  draw_trace(dl, demo, demo.live, x, y, width, gh,
    alpha(T.SPECTRUM_LIVE, opacity), alpha(T.SPECTRUM_LIVE_FILL, opacity), false, 1.25 * scale)
  reaper.ImGui_DrawList_PopClipRect(dl)
end

return release_spectrum
