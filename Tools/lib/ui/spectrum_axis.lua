-- Passive frequency ruler for the spectrum. It owns only paint: the caller
-- decides whether another control or active gesture excludes the pointer.
local theme = require('ui.theme')
local mathx = require('core.spectrum_math')
local axis_geometry = require('core.spectrum_axis')

local T, M = theme.tokens, theme.metrics
local axis = {}

local LABELS = {20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000}

local function hz_label(hz)
  return hz >= 1000 and tostring(hz // 1000) .. 'k' or tostring(hz)
end

local function valid_geometry(input)
  return type(input) == 'table'
    and (tonumber(input.axis) or 0) > 0
    and type(input.gx) == 'number' and type(input.gy) == 'number'
    and type(input.gw) == 'number' and type(input.gh) == 'number'
    and input.gw > 0 and input.gh > 0
end

-- `input.bottom` is the spectrum floor in dB. The ruler begins at
-- `input.gy + input.gh`, so it follows the plot exactly without another
-- geometry field that can become stale after a resize.
function axis.draw(ctx, dl, model, input)
  if not valid_geometry(input) then return end

  local gx, gy, gw, gh = input.gx, input.gy, input.gw, input.gh
  local graph_bottom = gy + gh
  local ruler_bottom = graph_bottom + tonumber(input.axis)
  local fmin = math.max(0.001, tonumber(input.fmin) or 10)
  local fmax = math.max(fmin * 1.001, tonumber(input.fmax) or 22050)
  local mx, my = tonumber(input.mx), tonumber(input.my)
  local pointer_on_axis = input.eligible == true and mx and my
    and mx >= gx and mx <= gx + gw
    and my > graph_bottom and my <= ruler_bottom

  local small = theme.push_small_font(ctx)
  local readout, readout_width, readout_x
  local readout_frequency, trace_y
  if pointer_on_axis then
    local fraction = math.max(0, math.min(1, (mx - gx) / gw))
    readout_frequency = mathx.fraction_frequency(fraction, fmin, fmax)
    readout = string.format('%.0f Hz', readout_frequency)
    readout_width = reaper.ImGui_CalcTextSize(ctx, readout)
    -- Match the waveform ruler's cursor clearance and flip at the left edge.
    local pointer_gap = M.ITEM_SPACING_X * 3
    readout_x = mx - readout_width - pointer_gap
    if readout_x < gx then readout_x = mx + pointer_gap end
    readout_x = math.max(gx, math.min(gx + gw - readout_width, readout_x))

    if input.draw_live and type(model) == 'table' and type(model.live) == 'table' then
      local count = math.max(0, math.floor(tonumber(model.count) or #model.live))
      local db = mathx.sample_log_values(model.live, count, readout_frequency, fmin, fmax)
      if db then
        local prefs = model.prefs or {}
        db = mathx.tilted_db(db, readout_frequency, prefs.tilt)
        local floor_db = tonumber(input.bottom) or -96
        if db >= floor_db then
          trace_y = gy + mathx.db_fraction(db, 6, floor_db) * gh
        end
      end
    end
  end

  -- Fade nearby labels before the moving value reaches them. Labels that would
  -- overlap vanish completely, so the ruler never becomes a stack of numbers.
  local last_right = gx - M.SPECTRUM_PLOT_PAD
  local label_y = graph_bottom + M.RULER_TICK_MAJOR + 2
  local falloff = M.RULER_LABEL_FADE_W
  reaper.ImGui_DrawList_PushClipRect(dl, gx, gy, gx + gw, ruler_bottom, true)
  for _, hz in ipairs(LABELS) do
    if hz >= fmin and hz <= fmax then
      local text = hz_label(hz)
      local width = reaper.ImGui_CalcTextSize(ctx, text)
      local tick_x = gx + mathx.frequency_fraction(hz, fmin, fmax) * gw
      local text_x = axis_geometry.label_left(tick_x, width, gx, gx + gw)
      if text_x >= last_right + M.ITEM_SPACING_X then
        local opacity = readout and axis_geometry.label_opacity(text_x, width,
          readout_x, readout_width, falloff) or 1
        reaper.ImGui_DrawList_AddLine(dl, tick_x, graph_bottom,
          tick_x, graph_bottom + M.RULER_TICK_MAJOR,
          theme.fade(T.TEXT_TERTIARY, opacity))
        if opacity > 0 then
          reaper.ImGui_DrawList_AddText(dl, text_x, label_y,
            theme.fade(T.TEXT_TERTIARY, opacity), text)
        end
        last_right = text_x + width
      end
    end
  end

  if readout then
    -- Keep the sampled position visible even without a live trace.
    if trace_y then
      reaper.ImGui_DrawList_AddLine(dl, mx, trace_y, mx, label_y,
        theme.fade(T.TEXT_PRIMARY, 0.3), theme.scale)
      reaper.ImGui_DrawList_AddCircleFilled(dl, mx, trace_y,
        M.UPDATE_DOT_R, T.TEXT_PRIMARY)
    end
    reaper.ImGui_DrawList_AddLine(dl, mx, graph_bottom,
      mx, graph_bottom + M.RULER_TICK_MAJOR, T.TEXT_PRIMARY, theme.scale)
    reaper.ImGui_DrawList_AddText(dl, readout_x, label_y, T.TEXT_PRIMARY, readout)
  end
  reaper.ImGui_DrawList_PopClipRect(dl)

  if small then reaper.ImGui_PopFont(ctx) end
  return trace_y ~= nil
end

return axis
