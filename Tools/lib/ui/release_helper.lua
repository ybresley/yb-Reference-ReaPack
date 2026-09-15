-- A paint-only likeness of Reaper's Monitoring FX list. The native palette
-- distinguishes the host window from the surrounding audio illustration.
local theme = require('ui.theme')
local signal = require('ui.release_spectrum')
local helper = {}

local NATIVE = {
  shadow = 0x00000035, border = 0x777777FF, title_bg = 0xEFF2F8FF,
  menu_bg = 0xFAFAFAFF, list_bg = 0xFFFFFFFF, divider = 0xD4D4D4FF,
  text = 0x171717FF, selected = 0x0078D7FF, selected_text = 0xFFFFFFFF,
}
local ROWS = {
  'JS: yb-Reference Monitoring Filter',
  'VST: ReaEQ (Cockos)', 'VST: ReaLimit (Cockos)',
  'JS: Loudness Meter Peak/RMS/LUFS', 'JS: Oscilloscope Meter',
  'JS: Stereo Field Meter',
}
local SOURCES = { 'yb-Reference', 'Reaper' }

function helper.new()
  return { spectrum = signal.new() }
end

local function ease(value)
  value = math.max(0, math.min(1, value))
  return value * value * (3 - 2 * value)
end

local function add_text(ctx, dl, x, y, height, value, colour)
  local _, text_h = reaper.ImGui_CalcTextSize(ctx, value)
  reaper.ImGui_DrawList_AddText(dl, math.floor(x + .5),
    math.floor(y + (height - text_h) * .5 + .5), colour, value)
end

local function checkbox(dl, x, y, size, stroke, fill, thickness)
  reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x + size, y + size, fill)
  reaper.ImGui_DrawList_AddRect(dl, x, y, x + size, y + size, stroke, 0, 0, thickness)
  reaper.ImGui_DrawList_AddLine(dl, x + size * .20, y + size * .53,
    x + size * .43, y + size * .76, stroke, thickness * 1.35)
  reaper.ImGui_DrawList_AddLine(dl, x + size * .43, y + size * .76,
    x + size * .82, y + size * .22, stroke, thickness * 1.35)
end

local function cubic(a, b, c, d, t)
  local u = 1 - t
  return u*u*u*a + 3*u*u*t*b + 3*u*t*t*c + t*t*t*d
end

-- The three short paths have a fixed drawing budget and allocate no point arrays.
local function connection(dl, x1, y1, x2, y2, x3, y3, x4, y4, opacity, phase, scale)
  local px, py = x1, y1
  local accent = theme.tokens.ACCENT
  for i = 1, 24 do
    local t = i / 24
    local x, y = cubic(x1, x2, x3, x4, t), cubic(y1, y2, y3, y4, t)
    reaper.ImGui_DrawList_AddLine(dl, px, py, x, y,
      theme.fade(accent, opacity * .48), 1.35 * scale)
    px, py = x, y
  end
  if phase then
    local t = phase % 1
    local x, y = cubic(x1, x2, x3, x4, t), cubic(y1, y2, y3, y4, t)
    local glow = opacity * math.sin(t * math.pi)
    reaper.ImGui_DrawList_AddCircleFilled(dl, x, y, 5 * scale, theme.fade(accent, glow * .09))
    reaper.ImGui_DrawList_AddCircleFilled(dl, x, y, 2 * scale, theme.fade(accent, glow * .85))
  end
end

local function window(ctx, dl, left, top, scale, entry, focus, opacity)
  local right, bottom = left + 330 * scale, top + 232 * scale
  local list_y = top + 50 * scale
  local line = math.max(.75, scale)
  local function colour(value, amount) return theme.fade(value, opacity * (amount or 1)) end
  reaper.ImGui_DrawList_AddRectFilled(dl, left + 4 * scale, top + 5 * scale,
    right + 4 * scale, bottom + 5 * scale, colour(NATIVE.shadow))
  reaper.ImGui_DrawList_AddRectFilled(dl, left, top, right, bottom, colour(NATIVE.list_bg))
  reaper.ImGui_DrawList_AddRectFilled(dl, left, top, right, top + 26 * scale, colour(NATIVE.title_bg))
  reaper.ImGui_DrawList_AddRectFilled(dl, left, top + 26 * scale, right, list_y, colour(NATIVE.menu_bg))
  reaper.ImGui_DrawList_AddLine(dl, left, list_y, right, list_y, colour(NATIVE.divider), line)
  local font = theme.push_release_font(ctx, 13 * scale)
  add_text(ctx, dl, left + 8 * scale, top, 26 * scale, 'FX: Monitoring', colour(NATIVE.text))
  add_text(ctx, dl, left + 8 * scale, top + 26 * scale, 24 * scale,
    'FX    Edit    Options', colour(NATIVE.text))
  -- Clip translated rows within the native list; the enclosing demo never moves.
  reaper.ImGui_DrawList_PushClipRect(dl, left + scale, list_y, right - scale, bottom - scale, true)
  for index = 2, #ROWS do
    local row_y = list_y + (index - 2 + entry) * 30 * scale
    local dim = 1 - focus * .56
    checkbox(dl, left + 6 * scale, row_y + 8 * scale, 13 * scale,
      colour(NATIVE.text, dim), colour(NATIVE.list_bg), line)
    add_text(ctx, dl, left + 28 * scale, row_y, 30 * scale, ROWS[index], colour(NATIVE.text, dim))
  end
  local row_y = list_y - (1 - entry) * 10 * scale
  if entry > 0 then
    reaper.ImGui_DrawList_AddRectFilled(dl, left + 25 * scale, row_y + 2 * scale,
      right - 4 * scale, row_y + 28 * scale, colour(NATIVE.selected, entry))
    checkbox(dl, left + 6 * scale, row_y + 8 * scale, 13 * scale,
      colour(NATIVE.text, entry), colour(NATIVE.list_bg, entry), line)
    add_text(ctx, dl, left + 30 * scale, row_y, 30 * scale, ROWS[1], colour(NATIVE.selected_text, entry))
  end
  reaper.ImGui_DrawList_PopClipRect(dl)
  reaper.ImGui_DrawList_AddRect(dl, left, top, right, bottom, colour(NATIVE.border), 0, 0, line)
  if font then reaper.ImGui_PopFont(ctx) end
end

function helper.draw(ctx, res, demo, _, elapsed, width, height)
  local canvas_x, canvas_y = reaper.ImGui_GetCursorScreenPos(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local opacity = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha())
  local moving = theme.motion.enabled
  local time = moving and math.max(0, elapsed) or 6
  local t = time % 11.6
  local entry = ease((t - .5) / .65) * (1 - ease((t - 10.7) / .6))
  local focus = ease((t - 1.7) / .65) * (1 - ease((t - 9.9) / .5))
  local extra = ease((t - 1.8) / .25) * (1 - ease((t - 9.8) / .5)) * opacity
  -- These dimensions describe the approved illustration, scaled as one unit.
  local scale = math.max(.01, math.min(theme.scale, width / 736, height / 350))
  local ox, oy = canvas_x + (width - 736 * scale) * .5, canvas_y + (height - 350 * scale) * .5
  local left, top = ox + 26 * scale, oy + 90 * scale
  local right, row_y = left + 330 * scale, top + 65 * scale
  local plot_x, plot_y = ox + 410 * scale, oy + 137 * scale
  local phase = moving and t > 1.8 and (t - 1.8) * .4 or nil
  reaper.ImGui_DrawList_PushClipRect(dl, canvas_x, canvas_y, canvas_x + width, canvas_y + height, true)
  reaper.ImGui_DrawList_AddRectFilled(dl, canvas_x, canvas_y, canvas_x + width,
    canvas_y + height, theme.fade(theme.tokens.BG_WINDOW, opacity))

  local font = theme.push_release_font(ctx, 14 * scale)
  for index, name in ipairs(SOURCES) do
    local centre = left + (index == 1 and 84 or 249) * scale
    reaper.ImGui_DrawList_AddRect(dl, centre - 76 * scale, oy + 18 * scale,
      centre + 76 * scale, oy + 54 * scale,
      theme.fade(theme.tokens.STROKE_PRIMARY, extra), 0, 0, scale)
    local label_w = reaper.ImGui_CalcTextSize(ctx, name)
    local label_x = centre - (label_w + 26 * scale) * .5
    add_text(ctx, dl, label_x, oy + 26 * scale, 20 * scale, name,
      theme.fade(theme.tokens.TEXT_PRIMARY, extra))
    for bar = 1, 5 do
      local bar_h = (4 + 11 * (.5 + .5 * math.sin(time * 3 + (index * 5 + bar) * 1.7))) * scale
      local x = label_x + label_w + (10 + (bar - 1) * 4) * scale
      local cy = oy + 36 * scale
      reaper.ImGui_DrawList_AddRectFilled(dl, x, cy - bar_h * .5, x + 2 * scale, cy + bar_h * .5,
        theme.fade(theme.tokens.ACCENT, extra), scale)
    end
    connection(dl, centre, oy + 54 * scale, centre, top - 20 * scale,
      left + 165 * scale, top - 28 * scale, left + 165 * scale, top,
      extra, phase and phase + index * .23, scale)
  end
  if font then reaper.ImGui_PopFont(ctx) end
  connection(dl, right, row_y, right + 26 * scale, row_y,
    plot_x - 38 * scale, plot_y + 60 * scale, plot_x - 12 * scale, plot_y + 60 * scale,
    extra, phase and phase + .46, scale)
  window(ctx, dl, left, top, scale, entry, focus, opacity)
  if extra > 0 then
    reaper.ImGui_DrawList_AddRect(dl, plot_x - 12 * scale, plot_y - 10 * scale,
      plot_x + 314 * scale, plot_y + 176 * scale,
      theme.fade(theme.tokens.STROKE_PRIMARY, extra), 0, 0, scale)
    font = theme.push_release_font(ctx, 13 * scale)
    add_text(ctx, dl, plot_x, plot_y, 20 * scale, 'Spectrum analyser',
      theme.fade(theme.tokens.TEXT_SECONDARY, extra))
    if font then reaper.ImGui_PopFont(ctx) end
    signal.paint_signal(ctx, res, demo.spectrum, time, plot_x, plot_y + 27 * scale,
      302 * scale, 139 * scale, extra, scale)
  end
  reaper.ImGui_DrawList_PopClipRect(dl)
  reaper.ImGui_Dummy(ctx, width, height)
end

return helper
