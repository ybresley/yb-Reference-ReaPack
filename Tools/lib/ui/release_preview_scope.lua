-- Fit production drawings and controls together without changing the live UI Size.
local theme = require('ui.theme')
local scope = {}
local frames, depth = {}, 0

function scope.paint(ctx, ratio, draw, metric_factors)
  depth = depth+1
  local frame = frames[depth] or {metrics={}}
  frames[depth] = frame
  frame.scale = theme.scale
  for key,value in pairs(theme.metrics) do
    frame.metrics[key] = value
    theme.metrics[key] = value*ratio*(metric_factors and metric_factors[key] or 1)
  end
  theme.scale = theme.scale*ratio
  local M = theme.metrics
  reaper.ImGui_PushStyleVar(ctx,reaper.ImGui_StyleVar_FramePadding(),M.FRAME_PAD_X,M.FRAME_PAD_Y)
  reaper.ImGui_PushStyleVar(ctx,reaper.ImGui_StyleVar_ItemSpacing(),M.ITEM_SPACING_X,M.ITEM_SPACING_Y)
  reaper.ImGui_PushStyleVar(ctx,reaper.ImGui_StyleVar_WindowPadding(),M.WINDOW_PAD,M.WINDOW_PAD)
  local font = theme.push_release_font(ctx,M.BASE_FS)
  local result = table.pack(xpcall(draw,debug.traceback))
  if font then reaper.ImGui_PopFont(ctx) end
  reaper.ImGui_PopStyleVar(ctx,3)
  theme.scale = frame.scale
  for key,value in pairs(frame.metrics) do theme.metrics[key] = value end
  depth = depth-1
  if not result[1] then error(result[2],0) end
  return table.unpack(result,2,result.n)
end

return scope
