-- Static dB labels share the spectrum ruler's font and fixed right gutter.
local theme = require('ui.theme')
local mathx = require('core.spectrum_math')

local T, M = theme.tokens, theme.metrics
local level_axis = {}

function level_axis.draw(ctx, dl, input)
  if (tonumber(input.axis) or 0) <= 0 or input.gw <= 0 or input.gh <= 0 then return end

  local gx, gy, gh = input.gx, input.gy, input.gh
  local graph_bottom = gy + gh
  local bottom = input.bottom
  local small = theme.push_small_font(ctx)
  local _, level_h = reaper.ImGui_CalcTextSize(ctx, '-90')
  local label_gap = M.SPECTRUM_BAND_GAP

  reaper.ImGui_DrawList_PushClipRect(dl, gx, gy,
    input.level_right + label_gap, graph_bottom, true)

  local function level_label(text, yy)
    local width = reaper.ImGui_CalcTextSize(ctx, text)
    local label_y = yy - level_h * 0.5
    reaper.ImGui_DrawList_AddText(dl, input.level_right - width, label_y,
      T.TEXT_TERTIARY, text)
    return label_y + level_h
  end

  local zero_y = gy + mathx.db_fraction(0, 6, bottom) * gh
  local label_step = 10
  while label_step * gh / (6 - bottom) < level_h + label_gap do
    label_step = label_step + 10
  end

  local zero_top = zero_y - level_h * 0.5
  local zero_bottom = zero_top + level_h
  if zero_top >= gy and zero_bottom <= graph_bottom then
    level_label('0', zero_y)
    if gy + level_h + label_gap <= zero_top then
      local plus_width = reaper.ImGui_CalcTextSize(ctx, '+6')
      reaper.ImGui_DrawList_AddText(dl, input.level_right - plus_width, gy,
        T.TEXT_TERTIARY, '+6')
    end
    local last_bottom = zero_bottom
    for db = -label_step, bottom, -label_step do
      local yy = gy + mathx.db_fraction(db, 6, bottom) * gh
      local top = yy - level_h * 0.5
      if top >= last_bottom + label_gap and top + level_h <= graph_bottom then
        last_bottom = level_label(tostring(db), yy)
      end
    end
  end

  reaper.ImGui_DrawList_PopClipRect(dl)
  if small then reaper.ImGui_PopFont(ctx) end
end

return level_axis
