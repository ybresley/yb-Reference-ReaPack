local core = require('core.stereo')
local raster = require('core.stereo_raster')
local clip_arcs = require('core.stereo_clip_arcs')
local theme = require('ui.theme')
local helper_status = require('ui.spectrum_status')
local controls = require('ui.spectrum_controls')
local settings = require('ui.stereo_settings')
local preferences = require('core.stereo_preferences')
local tips = require('ui.tips')

local T, M = theme.tokens, theme.metrics
local stereo = {}
local defaults = preferences.defaults()

local function centre_text(ctx, dl, value, x, y, width, height)
  local tw, th = reaper.ImGui_CalcTextSize(ctx, value)
  reaper.ImGui_DrawList_AddText(dl, x + math.max(0, (width - tw) / 2),
    y + math.max(0, (height - th) / 2), T.TEXT_QUATERNARY, value)
end

local function label(ctx, dl, value, x, y)
  local tw, th = reaper.ImGui_CalcTextSize(ctx, value)
  reaper.ImGui_DrawList_AddText(dl,
    math.floor(x - tw / 2 + 0.5), math.floor(y - th / 2 + 0.5),
    T.TEXT_TERTIARY, value)
end

local function correlation(ctx, dl, model, x, width, cy, radius, polar, now, presentation)
  local scale = theme.scale
  local bx = x + width - M.STEREO_CORRELATION_W + M.WINDOW_PAD
  local top = cy - radius
  local bottom = polar and cy or cy + radius
  if bottom - top < reaper.ImGui_GetTextLineHeight(ctx) * 3 then return end
  local middle = (top + bottom) / 2
  reaper.ImGui_DrawList_AddLine(dl, bx, top, bx, bottom, T.STROKE_SECONDARY, scale)
  local small = theme.push_small_font(ctx)
  label(ctx, dl, '+1', bx + M.STEREO_LABEL_GAP * 2, top)
  label(ctx, dl, '0', bx + M.STEREO_LABEL_GAP * 2, middle)
  label(ctx, dl, '-1', bx + M.STEREO_LABEL_GAP * 2, bottom)
  if small then reaper.ImGui_PopFont(ctx) end
  local value = core.correlation(model, now)
  if value then
    local position = middle - value * (bottom - top) / 2
    reaper.ImGui_DrawList_AddRectFilled(dl, bx - 3 * scale, position - scale,
      bx + 3 * scale, position + scale, T.STEREO_TRACE)
  end
  if not presentation then
    tips.show(ctx, reaper.ImGui_IsMouseHoveringRect(ctx, bx - M.WINDOW_PAD, top,
      x + width, bottom), value and string.format('Correlation: %+.2f', value)
        or 'Correlation: unavailable', 'stereo_correlation')
  end
end

function stereo.draw(ctx, state, width, height, res, input_exclusion, panel_x, panel_width, presentation)
  local model = state.stereo
  local system = state.monitor_filter.system
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local scale = theme.scale
  local polar = state.stereo_view == 'polar_sample'
  local prefs = state.stereo_preferences or defaults
  local plot_width = width - (prefs.show_correlation and M.STEREO_CORRELATION_W or 0)
  reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x + width, y + height,
    T.STEREO_BG, 3 * scale)
  reaper.ImGui_Dummy(ctx, width, height)

  local cx = x + plot_width / 2
  local plot_height = height - M.STEREO_PAD_Y - M.STEREO_PAD_BOTTOM
  -- Rounded UI-size metrics must still let a square panel use its full height.
  local side_pad = math.min(M.STEREO_PAD_X, (M.STEREO_PAD_Y + M.STEREO_PAD_BOTTOM) / 2)
  -- Centre the visible shape within the padded area. Polar Sample's origin
  -- sits at the bottom of its semicircle; Lissajous's origin is its centre.
  local radius = math.max(1, math.min(plot_width / 2 - side_pad,
    plot_height / (polar and 1 or 2)))
  local cy = y + M.STEREO_PAD_Y + (plot_height + (polar and radius or 0)) / 2
  local diagonal = polar and radius / math.sqrt(2) or radius * 0.5
  local inner_level = 0.5
  if polar then
    for ring = 1, 2 do
      reaper.ImGui_DrawList_PathArcTo(dl, cx, cy, radius * (ring == 1 and inner_level or 1),
        math.pi, 2 * math.pi, 48)
      reaper.ImGui_DrawList_PathStroke(dl, ring == 2 and T.STROKE_PRIMARY or T.SPECTRUM_GRID, 0, scale)
    end
  else
    for ring = 1, 2 do
      local extent = radius * (ring == 1 and inner_level or 1)
      local colour = ring == 2 and T.STROKE_PRIMARY or T.SPECTRUM_GRID
      reaper.ImGui_DrawList_AddLine(dl, cx, cy - extent, cx + extent, cy, colour, scale)
      reaper.ImGui_DrawList_AddLine(dl, cx + extent, cy, cx, cy + extent, colour, scale)
      reaper.ImGui_DrawList_AddLine(dl, cx, cy + extent, cx - extent, cy, colour, scale)
      reaper.ImGui_DrawList_AddLine(dl, cx - extent, cy, cx, cy - extent, colour, scale)
    end
  end
  reaper.ImGui_DrawList_AddLine(dl, cx - radius, cy, cx + radius, cy,
    polar and T.STROKE_PRIMARY or T.SPECTRUM_GRID, scale)
  reaper.ImGui_DrawList_AddLine(dl, cx, cy - radius, cx, polar and cy or cy + radius,
    T.SPECTRUM_GRID)
  reaper.ImGui_DrawList_AddLine(dl, cx - diagonal, cy - diagonal,
    polar and cx or cx + diagonal, polar and cy or cy + diagonal,
    T.SPECTRUM_GRID, scale)
  reaper.ImGui_DrawList_AddLine(dl, polar and cx or cx - diagonal, polar and cy or cy + diagonal,
    cx + diagonal, cy - diagonal, T.SPECTRUM_GRID, scale)
  local small = theme.push_small_font(ctx)
  -- AddLine centres its stroke half a pixel beyond the supplied coordinate.
  label(ctx, dl, 'M', cx + 0.5, cy - radius - M.STEREO_LABEL_GAP)
  label(ctx, dl, 'L', cx - diagonal - M.STEREO_LABEL_GAP, cy - diagonal - 4 * scale)
  label(ctx, dl, 'R', cx + diagonal + M.STEREO_LABEL_GAP, cy - diagonal - 4 * scale)
  if not polar then
    label(ctx, dl, 'S', cx + radius + M.STEREO_LABEL_GAP, cy)
  end
  if small then reaper.ImGui_PopFont(ctx) end

  if prefs.show_correlation then
    correlation(ctx, dl, model, x, width, cy, radius, polar, model.now or 0, presentation)
  end

  -- Controls follow the full panel while the scope keeps its centred proportions.
  local action = settings.draw(ctx, state, res, panel_x or x, y,
    panel_width or width, height, input_exclusion, presentation)
  reaper.ImGui_SetCursorScreenPos(ctx, x, y + height)

  if system and not system.available then
    if presentation then return end
    if input_exclusion then
      local mx, my = reaper.ImGui_GetMousePos(ctx)
      if controls.contains(input_exclusion, mx, my) then return action end
    end
    local recovery = helper_status.draw(ctx, system, x, y, width, height)
    return action or recovery
  end

  local now = core.display_time(model, model.now or 0)
  local mx, my
  if not presentation then mx, my = reaper.ImGui_GetMousePos(ctx) end
  if not presentation and not (input_exclusion and controls.contains(input_exclusion, mx, my)) then
    -- Submit after the view control so it keeps ownership of clicks over it.
    reaper.ImGui_SetCursorScreenPos(ctx, x, y)
    reaper.ImGui_InvisibleButton(ctx, '##stereo_clear_display', width, height)
    if reaper.ImGui_IsItemClicked(ctx, 0) then
      action = action or {type='stereo_clear_display'}
    end
    reaper.ImGui_SetCursorScreenPos(ctx, x, y + height)
  end
  -- Leave the grid empty on the click frame, before the action clears history.
  if action and action.type == 'stereo_clear_display' then return action end
  local visible = false
  local dot_size = math.max(1, math.floor(M.STEREO_DOT_SIZE + 0.5))
  local clip_radius = 1.5 * scale
  if not model.raster then
    model.raster = raster.new()
    model.raster.clip_arcs = clip_arcs.new()
    model.raster.colours = {}
    for level = 0, 255 do
      model.raster.colours[level] = theme.blend(T.STEREO_BG, T.STEREO_TRACE, level / 255)
    end
  end
  local pixels = raster.build(model.raster, model, radius, polar, dot_size, now, prefs)
  local ox, oy = math.floor(cx - radius), math.floor(cy - radius)
  -- Resize previews already place hits on the current grid.
  local grid_step = pixels.dot_size
  -- Include the marker radius so full-scale samples remain visible at vertices.
  reaper.ImGui_DrawList_PushClipRect(dl, cx - radius - clip_radius, cy - radius - clip_radius,
    cx + radius + clip_radius, (polar and cy or cy + radius) + clip_radius, true)
  -- Draw each occupied pixel once at its freshest brightness. Capturing more
  -- samples adds detail without repeatedly painting the same screen position.
  for i = 1, pixels.count do
    visible = true
    local cell = pixels.cells[i]
    local level = math.floor(pixels.levels[cell] * 255 + 0.5)
    local dx = math.floor(ox + cell % pixels.cols * grid_step)
    local dy = math.floor(oy + math.floor(cell / pixels.cols) * grid_step)
    reaper.ImGui_DrawList_AddRectFilled(dl, dx, dy,
      dx + dot_size, dy + dot_size, model.raster.colours[level])
  end
  -- Draw full-scale markers last so ordinary dots cannot obscure them.
  -- Clipping holds at its actual full-scale boundary independently of display
  -- magnification and the ordinary dots' fade.
  if prefs.show_clipping then
    if polar then
      local px, py
      if core.overflow_clip_visible(model, now, prefs) then
        local clip = model.overflow_clip
        px, py = core.polar_point(clip.left, clip.right)
      end
      local arcs = clip_arcs.build(model.raster.clip_arcs, pixels, radius, clip_radius, px, py)
      for i = 1, arcs.count do
        visible = true
        local first, last = arcs.starts[i], arcs.ends[i]
        local segments = math.max(2, math.ceil((last - first) * radius / 3))
        reaper.ImGui_DrawList_PathArcTo(dl, cx, cy, radius, first, last, segments)
        reaper.ImGui_DrawList_PathStroke(dl, T.STEREO_CLIP, 0, M.STEREO_CLIP_STROKE)
      end
    else
      for i = 1, pixels.clip_count do
        visible = true
        local cell = pixels.clip_cells[i]
        reaper.ImGui_DrawList_AddCircleFilled(dl,
          ox + cell % pixels.cols * grid_step,
          oy + math.floor(cell / pixels.cols) * grid_step, clip_radius, T.STEREO_CLIP, 4)
      end
      if core.overflow_clip_visible(model, now, prefs) then
        visible = true
        local clip = model.overflow_clip
        local px, py = core.point(clip.left, clip.right)
        reaper.ImGui_DrawList_AddCircleFilled(dl, cx + px * radius, cy - py * radius,
          clip_radius, T.STEREO_CLIP, 4)
      end
    end
  end
  reaper.ImGui_DrawList_PopClipRect(dl)
  if model.playing and not visible and (model.status == 'invalid' or model.status == 'stale') then
    centre_text(ctx, dl, 'Stereo data unavailable', x, y, width, height)
  end
  if model.playing and model.overrun_until and now < model.overrun_until then
    reaper.ImGui_DrawList_PushClipRect(dl, x, y, x + width, y + height, true)
    centre_text(ctx, dl, 'Some stereo history was skipped.',
      x, y + height - 20 * scale, width, 20 * scale)
    reaper.ImGui_DrawList_PopClipRect(dl)
  end
  return action
end

return stereo
