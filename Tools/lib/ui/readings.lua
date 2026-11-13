-- The selected reference's six stored readings, drawn in the Reference card
-- and in the Normalize menu. Sharing the names, order and number format keeps
-- the two from drifting apart. A ui/ module: draws only.
local theme = require("ui.theme")
local tips = require("ui.tips")
local T = theme.tokens
local M = theme.metrics

local readings = {}

-- Loudness across the top row, peaks and RMS below. Momentary comes before
-- short-term, the scan order the user wants.
local UNITS = {
  { key = "lufs_m_max", tag = "LUFS-M" },
  { key = "lufs_s_max", tag = "LUFS-S" },
  { key = "lufs_i",     tag = "LUFS-I" },
  { key = "true_peak",  tag = "True Peak" },
  { key = "peak",       tag = "Peak" },
  { key = "rms",        tag = "RMS" },
}
readings.UNITS = UNITS

-- The one-row form shows the three loudness readings and one peak reading,
-- which clicking cycles through. The choice is remembered (reaper_api).
local EXTRA = { true_peak = UNITS[4], peak = UNITS[5], rms = UNITS[6] }
local NEXT_EXTRA = { true_peak = "peak", peak = "rms", rms = "true_peak" }
readings.EXTRA_TIP = "Click to switch between True Peak, Peak and RMS."
function readings.next_extra(key) return NEXT_EXTRA[key] or "true_peak" end

local UNIT = "dB"
local WIDEST_VALUE = "-120.0"
-- The three-column forms are for tight spaces: sized for everyday readings,
-- with the label-to-value gap absorbing a rare extra digit.
local SHORT_VALUE = "-00.0"

local function snap(v) return math.floor(v + 0.5) end

function readings.format(v)
  return type(v) == "number" and string.format("%.1f", v) or "\u{2014}"
end

-- Kept until the font size or UI scale changes; several draws a frame need
-- them, and the text they measure never changes.
local sizes, flat_columns, four_columns = {}, {}, {}
local measured_font, measured_scale

-- Content widths in pixels, from the live font:
--   two_w         two columns of three, each with its "dB"
--   wide_w        three columns of two with units, for a wide window
--   flat_w        three columns without units, for the two-row form
--   four_w        four columns without units, for the one-row form
--   flat_columns, four_columns  those columns' natural widths
function readings.measure(ctx)
  local font = reaper.ImGui_GetFontSize(ctx)
  if font == measured_font and theme.scale == measured_scale then return sizes end
  measured_font, measured_scale = font, theme.scale
  local gap = M.STRIP_GROUP_GAP
  local label = 0
  for _, u in ipairs(UNITS) do label = math.max(label, (reaper.ImGui_CalcTextSize(ctx, u.tag))) end
  local column = label + gap + reaper.ImGui_CalcTextSize(ctx, WIDEST_VALUE)
    + M.STRIP_UNIT_GAP + reaper.ImGui_CalcTextSize(ctx, UNIT)
  sizes.two_w = 2 * column + gap
  sizes.wide_w = 3 * column + 2 * 3 * gap
  local value = reaper.ImGui_CalcTextSize(ctx, SHORT_VALUE)
  local flat = 2 * gap
  for c = 1, 3 do
    -- Widths only: a size call in the last argument would also pass its height.
    local top_w = reaper.ImGui_CalcTextSize(ctx, UNITS[c].tag)
    local bottom_w = reaper.ImGui_CalcTextSize(ctx, UNITS[c + 3].tag)
    flat_columns[c] = math.max(top_w, bottom_w) + M.STRIP_LABEL_GAP + value
    flat = flat + flat_columns[c]
    four_columns[c] = top_w + M.STRIP_LABEL_GAP + value
  end
  -- The fourth column fits the widest of the peak readings it cycles through.
  local extra = 0
  for c = 4, 6 do extra = math.max(extra, (reaper.ImGui_CalcTextSize(ctx, UNITS[c].tag))) end
  four_columns[4] = extra + M.STRIP_LABEL_GAP + value
  sizes.four_w = 3 * gap + four_columns[1] + four_columns[2] + four_columns[3] + four_columns[4]
  sizes.flat_w = flat
  sizes.flat_columns, sizes.four_columns = flat_columns, four_columns
  return sizes
end

-- Row heights for 1, 2 or 3 rows of readings, or false where content `w`
-- wide cannot fit that form. Fills `rows` (reused by the caller).
function readings.rows_for_width(ctx, w, rows)
  local s = readings.measure(ctx)
  rows[3] = w >= s.two_w and 3 * M.STRIP_READING_H or false
  rows[2] = w >= s.flat_w and 2 * M.STRIP_COMPACT_READING_H or false
  rows[1] = w >= s.four_w and M.STRIP_COMPACT_READING_H or false
  return rows
end

-- The height of one row in a form with `count` rows.
function readings.row_height(count)
  return count == 3 and M.STRIP_READING_H or M.STRIP_COMPACT_READING_H
end

-- The readings section under a name or details row: a hairline with a gap
-- either side, then `count` rows. 0 for none. core/card_plan.lua folds the
-- card with the same sum.
function readings.section_height(count)
  if count == 0 then return 0 end
  return 2 * M.STRIP_FACTS_GAP + theme.scale + count * readings.row_height(count)
end

-- Draws that section's hairline from line_x0 to line_x1 at line_y, then the
-- rows a gap below it, `w` wide from x. Returns the one-row form's action.
function readings.draw_section(ctx, state, sel, line_x0, line_x1, line_y, x, w, count, id)
  local stroke = theme.scale
  reaper.ImGui_DrawList_AddLine(reaper.ImGui_GetWindowDrawList(ctx), line_x0, line_y + stroke * 0.5,
    line_x1, line_y + stroke * 0.5, T.STROKE_SECONDARY, stroke)
  return readings.draw_block(ctx, state, sel, x, line_y + stroke + M.STRIP_FACTS_GAP, w, count, id)
end

-- One reading: the label at lx and the value ending at rx, or before the unit
-- when `unit` is set. No value means no unit, only a dash.
local function draw_reading(ctx, dl, u, sel, lx, rx, y, h, unit)
  local lh = select(2, reaper.ImGui_CalcTextSize(ctx, u.tag))
  local ty = snap(y + (h - lh) * 0.5)
  reaper.ImGui_DrawList_AddText(dl, lx, ty, T.TEXT_SECONDARY, u.tag)
  local v = sel and sel[u.key]
  local text = readings.format(v)
  local number = type(v) == "number"
  local unit_w = unit and (M.STRIP_UNIT_GAP + reaper.ImGui_CalcTextSize(ctx, UNIT)) or 0
  local vw = reaper.ImGui_CalcTextSize(ctx, text)
  reaper.ImGui_DrawList_AddText(dl, snap(rx - unit_w - vw), ty,
    number and T.TEXT_PRIMARY or T.TEXT_QUATERNARY, text)
  if unit and number then
    reaper.ImGui_DrawList_AddText(dl, snap(rx - unit_w + M.STRIP_UNIT_GAP), ty, T.TEXT_TERTIARY, UNIT)
  end
end

-- Two equal columns of three rows, each row h tall, split by the group gap.
function readings.draw_columns(ctx, dl, sel, x, y, w, h)
  local gap = M.STRIP_GROUP_GAP
  local split = snap((w - gap) * 0.5)
  for i, u in ipairs(UNITS) do
    local col, row = (i - 1) // 3, (i - 1) % 3
    local ry = y + row * h
    if col == 0 then
      draw_reading(ctx, dl, u, sel, x, x + split, ry, h, true)
    else
      draw_reading(ctx, dl, u, sel, x + split + gap, x + w, ry, h, true)
    end
  end
end

-- Two rows of three, loudness above peaks. Each column keeps its natural width
-- plus an equal share of the spare width.
function readings.draw_rows(ctx, dl, sel, x, y, w, h)
  local s = readings.measure(ctx)
  local gap = M.STRIP_GROUP_GAP
  local spare = (w - 2 * gap) - (s.flat_columns[1] + s.flat_columns[2] + s.flat_columns[3])
  local lx = x
  for c = 1, 3 do
    local rx = lx + s.flat_columns[c] + spare / 3
    for r = 0, 1 do
      draw_reading(ctx, dl, UNITS[r * 3 + c], sel, snap(lx), snap(rx), y + r * h, h, false)
    end
    lx = rx + gap
  end
end

-- Two rows of three with units, in equal columns, for a wide window.
function readings.draw_wide_rows(ctx, dl, sel, x, y, w, h)
  local gap = 3 * M.STRIP_GROUP_GAP
  local column = (w - 2 * gap) / 3
  for i, u in ipairs(UNITS) do
    local c, r = (i - 1) % 3, (i - 1) // 3
    local lx = x + c * (column + gap)
    draw_reading(ctx, dl, u, sel, snap(lx), snap(lx + column), y + r * h, h, true)
  end
end

-- One row: the three loudness readings, then the peak reading named by
-- `extra`. Returns the fourth column's left and right edges, for its click
-- target.
function readings.draw_four(ctx, dl, sel, x, y, w, h, extra)
  local s = readings.measure(ctx)
  local gap = M.STRIP_GROUP_GAP
  local cols = s.four_columns
  local spare = w - s.four_w
  local lx = x
  for c = 1, 4 do
    local rx = lx + cols[c] + spare / 4
    local unit = c < 4 and UNITS[c] or (EXTRA[extra] or EXTRA.true_peak)
    draw_reading(ctx, dl, unit, sel, snap(lx), snap(rx), y, h, false)
    if c == 4 then return snap(lx), snap(rx) end
    lx = rx + gap
  end
end

-- `count` rows of readings for sound `sel` at (x, y), `w` wide, in the form
-- for that many rows. In the one-row form the fourth reading is a button that
-- cycles the peak reading; `id` keeps the Reference card's and the Library's
-- buttons apart. Returns that button's action.
function readings.draw_block(ctx, state, sel, x, y, w, count, id)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local h = readings.row_height(count)
  if count == 3 then
    readings.draw_columns(ctx, dl, sel, x, y, w, h)
    return nil
  elseif count == 2 then
    readings.draw_rows(ctx, dl, sel, x, y, w, h)
    return nil
  end
  local extra = state.reading_extra
  local x0, x1 = readings.draw_four(ctx, dl, sel, x, y, w, h, extra)
  -- A little wider than the text, so the cell reads as clickable.
  local bleed = M.FRAME_PAD_Y
  reaper.ImGui_SetCursorScreenPos(ctx, x0 - bleed, y)
  local action
  if reaper.ImGui_InvisibleButton(ctx, id, x1 - x0 + 2 * bleed, h) then
    action = { type = "set_reading_extra", extra = readings.next_extra(extra) }
  end
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  if hovered then
    reaper.ImGui_DrawList_AddRectFilled(dl, x0 - bleed, y, x1 + bleed, y + h, T.FILL_TERTIARY,
      (reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding())))
  end
  tips.show(ctx, hovered, readings.EXTRA_TIP)
  return action
end

return readings
