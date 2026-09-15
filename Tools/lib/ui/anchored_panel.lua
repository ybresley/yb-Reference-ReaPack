-- Shared placement and outside-click dismissal for anchored UI panels.

local picker_layout = require("core.picker_layout")

local anchored_panel = {}

-- Call inside Begin, before drawing controls. Popup descendants count as part
-- of the panel. Waiting for release lets opener buttons finish their toggle
-- and lets fields commit on blur before their panel disappears.
function anchored_panel.dismissed(ctx, state)
  if reaper.ImGui_IsWindowAppearing(ctx) then
    state.outside_press = 0
    return false
  end
  local flags = reaper.ImGui_HoveredFlags_RootAndChildWindows()
    | reaper.ImGui_HoveredFlags_AllowWhenBlockedByActiveItem()
    | reaper.ImGui_HoveredFlags_AllowWhenBlockedByPopup()
  local inside = reaper.ImGui_IsWindowHovered(ctx, flags)
  local presses = state.outside_press or 0
  local dismiss = false
  for button = 0, 2 do
    local bit = 1 << button
    if reaper.ImGui_IsMouseClicked(ctx, button) then
      presses = inside and (presses & ~bit) or (presses | bit)
    end
    if reaper.ImGui_IsMouseReleased(ctx, button) then
      dismiss = dismiss or (not inside and (presses & bit) ~= 0)
      presses = presses & ~bit
    end
  end
  state.outside_press = presses
  return dismiss
end

-- Native monitor lookup is injected through res. ReaImGui converts the anchor
-- and the returned work rectangle so mixed-DPI monitors share one coordinate space.
function anchored_panel.work_area(ctx, res, anchor)
  local cx = (anchor.left + anchor.right) * 0.5
  local cy = (anchor.top + anchor.bottom) * 0.5
  local nx, ny = reaper.ImGui_PointConvertNative(ctx, cx, cy, true)
  local left, top, right, bottom = res.monitor_work_area(nx, ny)
  -- Use points just inside the monitor. An exact shared edge can select the
  -- neighbouring monitor's DPI during conversion.
  left, top = reaper.ImGui_PointConvertNative(ctx, left + 1, top + 1)
  right, bottom = reaper.ImGui_PointConvertNative(ctx, right - 1, bottom - 1)
  return { left = left, top = top, right = right, bottom = bottom }
end

function anchored_panel.place(ctx, res, anchor, spec)
  local work = spec.work or anchored_panel.work_area(ctx, res, anchor)
  local geometry = picker_layout.place(anchor, work,
    spec.width, spec.height, spec.min_height,
    spec.gap, spec.margin, spec.prefer_above)
  return geometry, work
end

function anchored_panel.resize(ctx, res, rect, width, height, margin)
  local work = anchored_panel.work_area(ctx, res, rect)
  return picker_layout.resize(rect, work, width, height, margin), work
end

-- Natural width follows live UI scaling within the containing monitor.
function anchored_panel.available_width(work, margin)
  local width = math.max(0, work.right - work.left)
  margin = math.max(0, margin or 0)
  return width >= margin * 2 and width - margin * 2 or width
end

-- Auto-sized content can grow after the opening measurement. Keep that growth
-- reachable while limiting the window to the remaining monitor area below its
-- opening top edge, or the contained top edge after a UI size change.
function anchored_panel.available_height(work, y, margin)
  local height = math.max(0, work.bottom - work.top)
  margin = math.max(0, margin or 0)
  local bottom = work.bottom
  if height >= margin * 2 then bottom = bottom - margin end
  return math.max(0, bottom - y)
end

return anchored_panel
