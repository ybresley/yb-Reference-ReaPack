-- Level ticks start at the filled plot edge, like the frequency ruler below it.
local theme = require('ui.theme')
local mathx = require('core.spectrum_math')
local axis_geometry = require('core.spectrum_axis')

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

  local edge=gx+input.gw
  local label_width=reaper.ImGui_CalcTextSize(ctx,'−'..tostring(math.ceil(math.abs(bottom))))
  local function level_label(text, yy)
    local width=reaper.ImGui_CalcTextSize(ctx,text)
    local label_y = yy - level_h * 0.5
    reaper.ImGui_DrawList_AddLine(dl,edge,yy,edge+M.RULER_TICK_MAJOR,yy,T.SPECTRUM_GRID)
    reaper.ImGui_DrawList_AddText(dl, edge+M.RULER_TICK_MAJOR+M.RULER_LABEL_GAP+label_width-width, label_y,
      T.TEXT_TERTIARY, text)
    return label_y + level_h
  end

  local ticks = axis_geometry.level_ticks(gh, bottom, level_h, label_gap)
  for _, db in ipairs(ticks) do
    local yy = gy + mathx.db_fraction(db, 6, bottom) * gh
    local label = db == 0 and '0' or tostring(db):gsub('^-','−')
    level_label(label, yy)
  end

  reaper.ImGui_DrawList_PopClipRect(dl)
  if small then reaper.ImGui_PopFont(ctx) end
end

return level_axis
