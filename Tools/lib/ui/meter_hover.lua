-- Meter tooltips and the history crosshair follow the pointer by rectangle, which
-- ImGui does not stop at the edge of a window lying on top. The Settings window
-- publishes its bounds here so the meters underneath stay quiet while the pointer
-- is over it.
local hover = {}
local covered

function hover.cover(bounds) covered = bounds end

function hover.rect(ctx, x1, y1, x2, y2)
  if not reaper.ImGui_IsMouseHoveringRect(ctx, x1, y1, x2, y2) then return false end
  if covered then
    local mx, my = reaper.ImGui_GetMousePos(ctx)
    if mx >= covered.left and mx <= covered.right
        and my >= covered.top and my <= covered.bottom then
      return false
    end
  end
  return true
end

return hover
